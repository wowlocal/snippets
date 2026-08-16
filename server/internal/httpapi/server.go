package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/wowlocal/snippets/server/internal/api"
	"github.com/wowlocal/snippets/server/internal/auth"
	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/domain"
)

type Server struct {
	configuration config.Server
	store         domain.Store
	validator     auth.Validator
	logger        *slog.Logger
	concurrent    chan struct{}
	bodyBytes     atomic.Int64
	global        *tokenBucket
	principalMu   sync.Mutex
	principals    map[[32]byte]*tokenBucket
	handler       http.Handler
}

func NewServer(configuration config.Server, store domain.Store, validator auth.Validator, logger *slog.Logger) *Server {
	if logger == nil {
		logger = slog.New(slog.NewJSONHandler(io.Discard, nil))
	}
	server := &Server{configuration: configuration, store: store, validator: validator, logger: logger, concurrent: make(chan struct{}, configuration.HTTP.MaximumConcurrent), global: newTokenBucket(float64(configuration.HTTP.GlobalRate), configuration.HTTP.GlobalBurst), principals: make(map[[32]byte]*tokenBucket)}
	implementation := NewHandler(configuration, store)
	strict := api.NewStrictHandlerWithOptions(implementation, nil, api.StrictHTTPServerOptions{
		RequestErrorHandlerFunc: func(w http.ResponseWriter, _ *http.Request, _ error) {
			writeProblem(w, domain.NewError(domain.InvalidRequest))
		},
		ResponseErrorHandlerFunc: func(w http.ResponseWriter, _ *http.Request, _ error) {
			writeProblem(w, domain.NewError(domain.InternalError))
		},
	})
	generated := api.HandlerFromMux(strict, http.NewServeMux())
	server.handler = server.limitMiddleware(server.authMiddleware(server.bodyMiddleware(server.secondRevocationMiddleware(generated))))
	return server
}

func (s *Server) Handler() http.Handler { return s.handler }

func (s *Server) limitMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		requestID := newRequestID()
		operation := operationName(r.Method, r.URL.Path)
		statusWriter := &statusRecorder{ResponseWriter: w}
		defer func() {
			status := statusWriter.status
			if status == 0 {
				status = 200
			}
			s.logger.Info("request", "operation", operation, "status", status, "duration_ms", time.Since(started).Milliseconds(), "request_id", requestID.String())
		}()
		if operation == "unknown" {
			writeProblem(statusWriter, domain.NewError(domain.NotFound))
			return
		}
		if encoding := r.Header.Get("Content-Encoding"); encoding != "" && !strings.EqualFold(strings.TrimSpace(encoding), "identity") {
			writeProblem(statusWriter, domain.NewError(domain.InvalidRequest))
			return
		}
		if !s.global.allow(time.Now()) {
			writeProblem(statusWriter, domain.ErrorWithRetry(domain.RateLimited, 1))
			return
		}
		select {
		case s.concurrent <- struct{}{}:
			defer func() { <-s.concurrent }()
		default:
			writeProblem(statusWriter, domain.ErrorWithRetry(domain.RateLimited, 1))
			return
		}
		next.ServeHTTP(statusWriter, r)
	})
}

func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if publicOperation(r.Method, r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		values := r.Header.Values("Authorization")
		if len(values) != 1 || strings.Contains(values[0], ",") {
			writeProblem(w, domain.NewError(domain.AuthenticationRequired))
			return
		}
		parts := strings.Split(values[0], " ")
		if len(parts) != 2 || parts[0] != "Bearer" || parts[1] == "" {
			writeProblem(w, domain.NewError(domain.AuthenticationRequired))
			return
		}
		requirement := auth.Standard
		if (r.Method == http.MethodPut && strings.HasSuffix(r.URL.Path, "/recovery-envelope")) || (r.Method == http.MethodPut && strings.HasSuffix(r.URL.Path, "/approval")) {
			requirement = auth.RecentPhishingResistant
		}
		principal, err := s.validator.Validate(r.Context(), parts[1], requirement)
		if err != nil {
			writeProblem(w, err)
			return
		}
		if !s.allowPrincipal(principal.CredentialDigest) {
			writeProblem(w, domain.ErrorWithRetry(domain.RateLimited, 1))
			return
		}
		revoked, err := s.store.IsAccessTokenRevoked(r.Context(), principal)
		if err != nil {
			writeProblem(w, domain.NewError(domain.DependencyUnavailable))
			return
		}
		if revoked {
			writeProblem(w, domain.NewError(domain.AuthenticationRequired))
			return
		}
		next.ServeHTTP(w, r.WithContext(withPrincipal(r.Context(), principal)))
	})
}

func (s *Server) bodyMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !bodyOperation(r.Method, r.URL.Path) {
			if r.ContentLength != 0 || len(r.TransferEncoding) != 0 {
				r.Close = true
				writeProblem(w, domain.NewError(domain.InvalidRequest))
				return
			}
			next.ServeHTTP(w, r)
			return
		}
		if contentType := strings.TrimSpace(strings.Split(r.Header.Get("Content-Type"), ";")[0]); contentType != "application/json" {
			writeProblem(w, domain.NewError(domain.InvalidRequest))
			return
		}
		if r.ContentLength > domain.MaxRequestBytes {
			r.Close = true
			writeProblem(w, domain.ErrorWithLimit(domain.PayloadTooLarge, domain.MaxRequestBytes))
			return
		}
		reservation := int64(domain.MaxRequestBytes)
		if r.ContentLength >= 0 {
			reservation = r.ContentLength
		}
		if reservation < 1 {
			reservation = 1
		}
		if s.bodyBytes.Add(reservation) > s.configuration.HTTP.BodyMemoryBudget {
			s.bodyBytes.Add(-reservation)
			writeProblem(w, domain.ErrorWithRetry(domain.RateLimited, 1))
			return
		}
		defer s.bodyBytes.Add(-reservation)
		bodyCtx, cancel := context.WithTimeout(r.Context(), s.configuration.HTTP.BodyTimeout)
		defer cancel()
		type readResult struct {
			value []byte
			err   error
		}
		result := make(chan readResult, 1)
		go func() {
			value, err := io.ReadAll(io.LimitReader(r.Body, domain.MaxRequestBytes+1))
			result <- readResult{value, err}
		}()
		var body []byte
		select {
		case <-bodyCtx.Done():
			r.Close = true
			writeProblem(w, domain.NewError(domain.InvalidRequest))
			return
		case value := <-result:
			if value.err != nil {
				writeProblem(w, domain.NewError(domain.InvalidRequest))
				return
			}
			body = value.value
		}
		if len(body) == 0 {
			writeProblem(w, domain.NewError(domain.InvalidRequest))
			return
		}
		if len(body) > domain.MaxRequestBytes {
			r.Close = true
			writeProblem(w, domain.ErrorWithLimit(domain.PayloadTooLarge, domain.MaxRequestBytes))
			return
		}
		if err := validateStrictBody(r.Method, r.URL.Path, body); err != nil {
			writeProblem(w, err)
			return
		}
		r.Body, r.ContentLength = io.NopCloser(bytes.NewReader(body)), int64(len(body))
		next.ServeHTTP(w, r)
	})
}

func (s *Server) secondRevocationMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if publicOperation(r.Method, r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		principal, err := principalFrom(r.Context())
		if err != nil {
			writeProblem(w, err)
			return
		}
		revoked, err := s.store.IsAccessTokenRevoked(r.Context(), principal)
		if err != nil {
			writeProblem(w, domain.NewError(domain.DependencyUnavailable))
			return
		}
		if revoked {
			writeProblem(w, domain.NewError(domain.AuthenticationRequired))
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) allowPrincipal(digest [32]byte) bool {
	s.principalMu.Lock()
	defer s.principalMu.Unlock()
	bucket := s.principals[digest]
	if bucket == nil {
		if len(s.principals) >= 4096 {
			for key := range s.principals {
				delete(s.principals, key)
				break
			}
		}
		bucket = newTokenBucket(float64(s.configuration.HTTP.PrincipalRate), s.configuration.HTTP.PrincipalBurst)
		s.principals[digest] = bucket
	}
	return bucket.allow(time.Now())
}

type tokenBucket struct {
	mu                  sync.Mutex
	rate, tokens, burst float64
	updated             time.Time
}

func newTokenBucket(rate float64, burst int) *tokenBucket {
	return &tokenBucket{rate: rate, tokens: float64(burst), burst: float64(burst), updated: time.Now()}
}
func (b *tokenBucket) allow(now time.Time) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.tokens += now.Sub(b.updated).Seconds() * b.rate
	if b.tokens > b.burst {
		b.tokens = b.burst
	}
	b.updated = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (w *statusRecorder) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
	w.ResponseWriter.WriteHeader(status)
}
func (w *statusRecorder) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(data)
}

func writeProblem(w http.ResponseWriter, err error) {
	problem := problemFrom(err)
	w.Header().Set("Content-Type", "application/problem+json")
	if problem.RetryAfterSeconds != nil {
		w.Header().Set("Retry-After", intString(*problem.RetryAfterSeconds))
	}
	w.WriteHeader(problem.Status)
	_ = json.NewEncoder(w).Encode(problem)
}

func validateStrictBody(method, path string, body []byte) error {
	if err := rejectDuplicateJSONKeys(body); err != nil {
		return domain.NewError(domain.InvalidRequest)
	}
	var target any
	switch {
	case method == http.MethodPost && strings.HasSuffix(path, "/records/batch"):
		target = &api.BatchRequest{}
	case method == http.MethodPut && strings.HasSuffix(path, "/recovery-envelope"):
		target = &api.PutRecoveryEnvelopeRequest{}
	case method == http.MethodPost && strings.HasSuffix(path, "/pairings"):
		target = &api.CreatePairingRequest{}
	case method == http.MethodPut && strings.HasSuffix(path, "/approval"):
		target = &api.ApprovePairingRequest{}
	default:
		return domain.NewError(domain.InvalidRequest)
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return domain.NewError(domain.InvalidRequest)
	}
	if err := ensureEOF(decoder); err != nil {
		return domain.NewError(domain.InvalidRequest)
	}
	var raw any
	decoder = json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	if err := decoder.Decode(&raw); err != nil {
		return domain.NewError(domain.InvalidRequest)
	}
	if err := validateRequiredShape(method, path, raw); err != nil {
		return err
	}
	if err := validateCanonicalBase64(raw); err != nil {
		return err
	}
	return nil
}

func validateCanonicalBase64(value any) error {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if key == "blob" || key == "ciphertext" || key == "nonce" || key == "recipientPublicKey" || key == "recipientKeyHash" {
				encoded, ok := child.(string)
				if !ok {
					return domain.NewError(domain.InvalidRequest)
				}
				decoded, err := base64.StdEncoding.Strict().DecodeString(encoded)
				if err != nil || base64.StdEncoding.EncodeToString(decoded) != encoded {
					return domain.NewError(domain.InvalidRequest)
				}
			}
			if err := validateCanonicalBase64(child); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range typed {
			if err := validateCanonicalBase64(child); err != nil {
				return err
			}
		}
	}
	return nil
}

func validateRequiredShape(method, path string, raw any) error {
	object, ok := raw.(map[string]any)
	if !ok {
		return domain.NewError(domain.InvalidRequest)
	}
	require := func(value map[string]any, keys ...string) bool {
		for _, key := range keys {
			if _, exists := value[key]; !exists {
				return false
			}
		}
		return true
	}
	switch {
	case method == http.MethodPost && strings.HasSuffix(path, "/records/batch"):
		if !require(object, "items") {
			return domain.NewError(domain.InvalidRequest)
		}
		items, ok := object["items"].([]any)
		if !ok {
			return domain.NewError(domain.InvalidRequest)
		}
		for _, item := range items {
			current, ok := item.(map[string]any)
			if !ok || !require(current, "record", "expectedRecordVersion") {
				return domain.NewError(domain.InvalidRequest)
			}
			record, ok := current["record"].(map[string]any)
			if !ok || !require(record, "id", "rev", "deleted", "blob") {
				return domain.NewError(domain.InvalidRequest)
			}
		}
	case method == http.MethodPut && strings.HasSuffix(path, "/recovery-envelope"):
		if !require(object, "expectedVersion", "keyEpoch", "algorithm", "ciphertext") {
			return domain.NewError(domain.InvalidRequest)
		}
	case method == http.MethodPost && strings.HasSuffix(path, "/pairings"):
		if !require(object, "recipientPublicKey", "nonce", "expiresInSeconds") {
			return domain.NewError(domain.InvalidRequest)
		}
	case method == http.MethodPut && strings.HasSuffix(path, "/approval"):
		if !require(object, "recipientKeyHash", "algorithm", "ciphertext") {
			return domain.NewError(domain.InvalidRequest)
		}
	}
	return nil
}

func rejectDuplicateJSONKeys(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := walkJSON(decoder); err != nil {
		return err
	}
	return ensureEOF(decoder)
}
func walkJSON(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delimiter, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delimiter {
	case '{':
		seen := map[string]struct{}{}
		for decoder.More() {
			token, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := token.(string)
			if !ok {
				return errors.New("invalid key")
			}
			if _, exists := seen[key]; exists {
				return errors.New("duplicate key")
			}
			seen[key] = struct{}{}
			if err := walkJSON(decoder); err != nil {
				return err
			}
		}
	case '[':
		for decoder.More() {
			if err := walkJSON(decoder); err != nil {
				return err
			}
		}
	default:
		return errors.New("invalid delimiter")
	}
	_, err = decoder.Token()
	return err
}
func ensureEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return errors.New("trailing value")
		}
		return err
	}
	return nil
}

func publicOperation(method, path string) bool {
	return (method == http.MethodGet && path == "/.well-known/snippets-sync") || (method == http.MethodGet && (path == "/health/live" || path == "/health/ready"))
}
func bodyOperation(method, path string) bool {
	return (method == http.MethodPost && strings.HasSuffix(path, "/records/batch")) || (method == http.MethodPut && strings.HasSuffix(path, "/recovery-envelope")) || (method == http.MethodPost && strings.HasSuffix(path, "/pairings")) || (method == http.MethodPut && strings.HasSuffix(path, "/approval"))
}

func operationName(method, path string) string {
	if publicOperation(method, path) {
		if path == "/.well-known/snippets-sync" {
			return "discovery"
		}
		if path == "/health/live" {
			return "liveness"
		}
		return "readiness"
	}
	if path == "/v2/session" && method == http.MethodDelete {
		return "revoke_session"
	}
	if path == "/v2/spaces" && method == http.MethodGet {
		return "list_spaces"
	}
	if path == "/v2/spaces" && method == http.MethodPost {
		return "create_space"
	}
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) < 3 || parts[0] != "v2" || parts[1] != "spaces" || !validUUID(parts[2]) {
		return "unknown"
	}
	if len(parts) == 3 && method == http.MethodGet {
		return "get_space"
	}
	if len(parts) == 4 && parts[3] == "changes" && method == http.MethodGet {
		return "get_changes"
	}
	if len(parts) == 5 && parts[3] == "records" && parts[4] == "batch" && method == http.MethodPost {
		return "submit_records"
	}
	if len(parts) == 4 && parts[3] == "recovery-envelope" && (method == http.MethodGet || method == http.MethodPut) {
		if method == http.MethodGet {
			return "get_recovery_envelope"
		}
		return "put_recovery_envelope"
	}
	if len(parts) == 4 && parts[3] == "pairings" && method == http.MethodPost {
		return "create_pairing"
	}
	if len(parts) >= 5 && parts[3] == "pairings" && validUUID(parts[4]) {
		if len(parts) == 5 && method == http.MethodGet {
			return "get_pairing"
		}
		if len(parts) == 5 && method == http.MethodDelete {
			return "cancel_pairing"
		}
		if len(parts) == 6 && parts[5] == "approval" && method == http.MethodPut {
			return "approve_pairing"
		}
		if len(parts) == 6 && parts[5] == "claim" && method == http.MethodPost {
			return "claim_pairing"
		}
	}
	return "unknown"
}

func validUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for i, char := range value {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if char != '-' {
				return false
			}
			continue
		}
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')) {
			return false
		}
	}
	return true
}
func intString(value int) string {
	if value == 0 {
		return "0"
	}
	digits := [20]byte{}
	position := len(digits)
	for value > 0 {
		position--
		digits[position] = byte('0' + value%10)
		value /= 10
	}
	return string(digits[position:])
}
