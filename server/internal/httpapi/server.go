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

	"github.com/google/uuid"
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
	readiness     chan struct{}
	bodyBytes     atomic.Int64
	responseBytes atomic.Int64
	global        *tokenBucket
	principalMu   sync.Mutex
	principals    map[[32]byte]*principalBucket
	handler       http.Handler
}

const maximumRecordResponseReservation = int64(domain.MaxResponseBytes + domain.MaxPageRecords*domain.MaxBlobBytes)

func NewServer(configuration config.Server, store domain.Store, validator auth.Validator, logger *slog.Logger) *Server {
	if logger == nil {
		logger = slog.New(slog.NewJSONHandler(io.Discard, nil))
	}
	server := &Server{configuration: configuration, store: store, validator: validator, logger: logger, concurrent: make(chan struct{}, configuration.HTTP.MaximumConcurrent), readiness: make(chan struct{}, 2), global: newTokenBucket(float64(configuration.HTTP.GlobalRate), configuration.HTTP.GlobalBurst), principals: make(map[[32]byte]*principalBucket)}
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
	server.handler = server.limitMiddleware(server.authMiddleware(server.bodyMiddleware(generated)))
	return server
}

func (s *Server) Handler() http.Handler { return s.handler }

func (s *Server) limitMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		requestID := newRequestID()
		r = r.WithContext(withRequestID(r.Context(), requestID))
		w.Header().Set("X-Request-ID", requestID.String())
		policy := policyForRequest(r.Method, r.URL.Path)
		r = r.WithContext(withOperationPolicy(r.Context(), policy))
		operation := policy.name
		statusWriter := &statusRecorder{ResponseWriter: w, requestID: requestID}
		defer func() {
			abortCommittedResponse := false
			if recovered := recover(); recovered != nil {
				s.logger.Error("request_panic", "operation", operation, "request_id", requestID.String())
				if statusWriter.status == 0 {
					writeProblem(statusWriter, domain.NewError(domain.InternalError))
				} else {
					// A partial response cannot be replaced safely. Mark the access outcome
					// failed, then ask net/http to abort the stream without another stack log.
					statusWriter.status = http.StatusInternalServerError
					abortCommittedResponse = true
				}
			}
			status := statusWriter.status
			if status == 0 {
				status = 200
			}
			s.logger.Info("request", "operation", operation, "status", status, "duration_ms", time.Since(started).Milliseconds(), "request_id", requestID.String())
			if abortCommittedResponse {
				panic(http.ErrAbortHandler)
			}
		}()
		if operation == "unknown" {
			writeProblem(statusWriter, domain.NewError(domain.NotFound))
			return
		}
		if encoding := r.Header.Get("Content-Encoding"); encoding != "" && !strings.EqualFold(strings.TrimSpace(encoding), "identity") {
			writeProblem(statusWriter, domain.NewError(domain.InvalidRequest))
			return
		}
		if operation == "liveness" {
			next.ServeHTTP(statusWriter, r)
			return
		}
		if operation == "readiness" {
			select {
			case s.readiness <- struct{}{}:
				defer func() { <-s.readiness }()
				next.ServeHTTP(statusWriter, r)
			default:
				writeProblem(statusWriter, domain.NewError(domain.DependencyUnavailable))
			}
			return
		}
		if s.configuration.HTTP.RequestTimeout > 0 {
			requestCtx, cancel := context.WithTimeout(r.Context(), s.configuration.HTTP.RequestTimeout)
			defer cancel()
			r = r.WithContext(requestCtx)
		}
		if !s.global.allow(time.Now()) {
			writeProblem(statusWriter, domain.ErrorWithRetry(domain.RateLimited, 1))
			return
		}
		if reservation := responseMemoryReservation(operation); reservation > 0 && s.configuration.HTTP.ResponseMemoryBudget > 0 {
			if s.responseBytes.Add(reservation) > s.configuration.HTTP.ResponseMemoryBudget {
				s.responseBytes.Add(-reservation)
				writeProblem(statusWriter, domain.ErrorWithRetry(domain.RateLimited, 1))
				return
			}
			defer s.responseBytes.Add(-reservation)
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

func responseMemoryReservation(operation string) int64 {
	switch operation {
	case "get_changes", "submit_records":
		// Both operations can materialize a full page of ciphertext and then a
		// Base64-expanded JSON response. Submit needs this reservation for the
		// authoritative records returned by a worst-case all-conflict batch.
		return maximumRecordResponseReservation
	default:
		return 0
	}
}

func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		policy := operationPolicyFrom(r.Context())
		if policy.public {
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
		principal, err := s.validator.Validate(r.Context(), parts[1], policy.requirement)
		if err != nil {
			writeProblem(w, err)
			return
		}
		if !s.allowPrincipal(principal.IdentityDigest) {
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
		policy := operationPolicyFrom(r.Context())
		if !policy.hasBody {
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
		reservation := int64(domain.MaxRequestMemoryReservation)
		if r.ContentLength >= 0 {
			reservation = r.ContentLength * int64(domain.MaxRequestMemoryReservation/domain.MaxRequestBytes)
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
		controller := http.NewResponseController(w)
		if err := controller.SetReadDeadline(time.Now().Add(s.configuration.HTTP.BodyTimeout)); err != nil && !errors.Is(err, http.ErrNotSupported) {
			r.Close = true
			writeProblem(w, domain.NewError(domain.InvalidRequest))
			return
		}
		defer func() { _ = controller.SetReadDeadline(time.Time{}) }()
		body, readErr := io.ReadAll(io.LimitReader(r.Body, domain.MaxRequestBytes+1))
		if readErr != nil {
			r.Close = true
			_ = r.Body.Close()
			writeProblem(w, domain.NewError(domain.InvalidRequest))
			return
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
		if err := validateStrictBody(policy.name, body); err != nil {
			writeProblem(w, err)
			return
		}
		r.Body, r.ContentLength = io.NopCloser(bytes.NewReader(body)), int64(len(body))
		next.ServeHTTP(w, r)
	})
}

func (s *Server) allowPrincipal(digest [32]byte) bool {
	s.principalMu.Lock()
	defer s.principalMu.Unlock()
	now := time.Now()
	entry := s.principals[digest]
	if entry == nil {
		if len(s.principals) >= 4096 {
			var oldestKey [32]byte
			var oldest time.Time
			for key, candidate := range s.principals {
				if oldest.IsZero() || candidate.lastSeen.Before(oldest) {
					oldestKey, oldest = key, candidate.lastSeen
				}
			}
			delete(s.principals, oldestKey)
		}
		entry = &principalBucket{bucket: newTokenBucket(float64(s.configuration.HTTP.PrincipalRate), s.configuration.HTTP.PrincipalBurst)}
		s.principals[digest] = entry
	}
	entry.lastSeen = now
	return entry.bucket.allow(now)
}

type principalBucket struct {
	bucket   *tokenBucket
	lastSeen time.Time
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
	status    int
	requestID uuid.UUID
}

func (w *statusRecorder) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}
func (w *statusRecorder) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(data)
}

func (w *statusRecorder) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func writeProblem(w http.ResponseWriter, err error) {
	ctx := context.Background()
	if recorder, ok := w.(*statusRecorder); ok && recorder.requestID != uuid.Nil {
		ctx = withRequestID(ctx, recorder.requestID)
	}
	problem := problemFrom(ctx, err)
	w.Header().Set("Content-Type", "application/problem+json")
	if problem.RetryAfterSeconds != nil {
		w.Header().Set("Retry-After", intString(*problem.RetryAfterSeconds))
	}
	w.WriteHeader(problem.Status)
	_ = json.NewEncoder(w).Encode(problem)
}

func validateStrictBody(operation string, body []byte) error {
	if err := rejectDuplicateJSONKeys(body); err != nil {
		return domain.NewError(domain.InvalidRequest)
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var raw any
	if err := decoder.Decode(&raw); err != nil {
		return domain.NewError(domain.InvalidRequest)
	}
	if err := validateRequiredShape(operation, raw); err != nil {
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

func validateRequiredShape(operation string, raw any) error {
	object, ok := raw.(map[string]any)
	if !ok {
		return domain.NewError(domain.InvalidRequest)
	}
	switch operation {
	case "submit_records":
		if !hasExactObjectShape(object, []string{"expectedScope", "items"}, nil) {
			return domain.NewError(domain.InvalidRequest)
		}
		scope, ok := object["expectedScope"].(map[string]any)
		if !ok || !hasExactObjectShape(scope, []string{"serverInstanceId", "spaceId", "scopeBinding", "datasetGeneration", "feedEpoch"}, nil) {
			return domain.NewError(domain.InvalidRequest)
		}
		items, ok := object["items"].([]any)
		if !ok {
			return domain.NewError(domain.InvalidRequest)
		}
		for _, item := range items {
			current, ok := item.(map[string]any)
			if !ok || !hasExactObjectShape(current, []string{"record", "expectedRecordVersion"}, nil) {
				return domain.NewError(domain.InvalidRequest)
			}
			record, ok := current["record"].(map[string]any)
			if !ok || !hasExactObjectShape(record, []string{"id", "rev", "deleted", "blob"}, nil) {
				return domain.NewError(domain.InvalidRequest)
			}
		}
	case "put_recovery_envelope":
		if !hasExactObjectShape(object, []string{"expectedVersion", "keyEpoch", "algorithm", "ciphertext"}, nil) {
			return domain.NewError(domain.InvalidRequest)
		}
	case "create_pairing":
		if !hasExactObjectShape(object, []string{"recipientPublicKey", "nonce", "expiresInSeconds"}, nil) {
			return domain.NewError(domain.InvalidRequest)
		}
	case "approve_pairing":
		if !hasExactObjectShape(object, []string{"recipientKeyHash", "algorithm", "ciphertext"}, nil) {
			return domain.NewError(domain.InvalidRequest)
		}
	default:
		return domain.NewError(domain.InvalidRequest)
	}
	return nil
}

func hasExactObjectShape(value map[string]any, required, optional []string) bool {
	allowed := make(map[string]struct{}, len(required)+len(optional))
	for _, key := range required {
		allowed[key] = struct{}{}
		if _, exists := value[key]; !exists {
			return false
		}
	}
	for _, key := range optional {
		allowed[key] = struct{}{}
	}
	for key := range value {
		if _, exists := allowed[key]; !exists {
			return false
		}
	}
	return true
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

type operationPolicy struct {
	name        string
	public      bool
	hasBody     bool
	requirement auth.Requirement
}

type operationPolicyContextKey struct{}

func withOperationPolicy(ctx context.Context, policy operationPolicy) context.Context {
	return context.WithValue(ctx, operationPolicyContextKey{}, policy)
}

func operationPolicyFrom(ctx context.Context) operationPolicy {
	if policy, ok := ctx.Value(operationPolicyContextKey{}).(operationPolicy); ok {
		return policy
	}
	return operationPolicy{name: "unknown", requirement: auth.Standard}
}

func policyForRequest(method, path string) operationPolicy {
	standard := func(name string) operationPolicy { return operationPolicy{name: name, requirement: auth.Standard} }
	if method == http.MethodGet && (path == "/.well-known/snippets-sync" || path == "/health/live" || path == "/health/ready") {
		if path == "/.well-known/snippets-sync" {
			return operationPolicy{name: "discovery", public: true, requirement: auth.Standard}
		}
		if path == "/health/live" {
			return operationPolicy{name: "liveness", public: true, requirement: auth.Standard}
		}
		return operationPolicy{name: "readiness", public: true, requirement: auth.Standard}
	}
	if path == "/v2/session" && method == http.MethodDelete {
		return standard("revoke_session")
	}
	if path == "/v2/spaces" && method == http.MethodGet {
		return standard("list_spaces")
	}
	if path == "/v2/spaces" && method == http.MethodPost {
		return standard("create_space")
	}
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) < 3 || parts[0] != "v2" || parts[1] != "spaces" || !validUUID(parts[2]) {
		return standard("unknown")
	}
	if len(parts) == 3 && method == http.MethodGet {
		return standard("get_space")
	}
	if len(parts) == 4 && parts[3] == "changes" && method == http.MethodGet {
		return standard("get_changes")
	}
	if len(parts) == 5 && parts[3] == "records" && parts[4] == "batch" && method == http.MethodPost {
		return operationPolicy{name: "submit_records", hasBody: true, requirement: auth.Standard}
	}
	if len(parts) == 4 && parts[3] == "recovery-envelope" && (method == http.MethodGet || method == http.MethodPut) {
		if method == http.MethodGet {
			return standard("get_recovery_envelope")
		}
		return operationPolicy{name: "put_recovery_envelope", hasBody: true, requirement: auth.RecentPhishingResistant}
	}
	if len(parts) == 4 && parts[3] == "pairings" && method == http.MethodPost {
		return operationPolicy{name: "create_pairing", hasBody: true, requirement: auth.Standard}
	}
	if len(parts) >= 5 && parts[3] == "pairings" && validUUID(parts[4]) {
		if len(parts) == 5 && method == http.MethodGet {
			return standard("get_pairing")
		}
		if len(parts) == 5 && method == http.MethodDelete {
			return standard("cancel_pairing")
		}
		if len(parts) == 6 && parts[5] == "approval" && method == http.MethodPut {
			return operationPolicy{name: "approve_pairing", hasBody: true, requirement: auth.RecentPhishingResistant}
		}
		if len(parts) == 6 && parts[5] == "claim" && method == http.MethodPost {
			return standard("claim_pairing")
		}
	}
	return standard("unknown")
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
