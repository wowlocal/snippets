package auth

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/domain"
)

type Requirement int

const (
	Standard Requirement = iota
	RecentPhishingResistant
)

type Validator interface {
	Validate(context.Context, string, Requirement) (domain.Principal, error)
}

type accessClaims struct {
	jwt.RegisteredClaims
	AuthorizedParty    string           `json:"azp,omitempty"`
	ClientID           string           `json:"client_id,omitempty"`
	AuthenticationTime *jwt.NumericDate `json:"auth_time,omitempty"`
	AMR                []string         `json:"amr,omitempty"`
	ACR                string           `json:"acr,omitempty"`
}

type jwksDocument struct {
	Keys []jwk `json:"keys"`
}
type jwk struct {
	KTY    string   `json:"kty"`
	KID    string   `json:"kid"`
	ALG    string   `json:"alg,omitempty"`
	Use    string   `json:"use,omitempty"`
	KeyOps []string `json:"key_ops,omitempty"`
	N      string   `json:"n,omitempty"`
	E      string   `json:"e,omitempty"`
	CRV    string   `json:"crv,omitempty"`
	X      string   `json:"x,omitempty"`
	Y      string   `json:"y,omitempty"`
	X5C    []string `json:"x5c,omitempty"`
}

type OIDCValidator struct {
	configuration config.OIDC
	client        *http.Client
	now           func() time.Time
	mu            sync.Mutex
	keys          map[string]any
	lastRefresh   time.Time
	lastAttempt   time.Time
	negative      map[string]time.Time
	refreshing    chan struct{}
	refreshErr    error
}

func NewOIDCValidator(ctx context.Context, configuration config.OIDC, client *http.Client) (*OIDCValidator, error) {
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	clone := *client
	clone.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	validator := &OIDCValidator{configuration: configuration, client: &clone, now: time.Now, negative: make(map[string]time.Time)}
	keys, err := validator.fetch(ctx)
	if err != nil {
		return nil, domain.NewError(domain.DependencyUnavailable)
	}
	validator.keys, validator.lastRefresh, validator.lastAttempt = keys, validator.now(), validator.now()
	return validator, nil
}

func (v *OIDCValidator) Validate(ctx context.Context, token string, requirement Requirement) (domain.Principal, error) {
	if len(token) == 0 || len(token) > 16384 || strings.TrimSpace(token) != token {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	headerData, err := decodeCanonicalRawURL(parts[0], 4096)
	if err != nil || rejectDuplicateKeys(headerData) != nil {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	var header struct {
		Algorithm string          `json:"alg"`
		KeyID     string          `json:"kid"`
		JKU       *string         `json:"jku,omitempty"`
		X5U       *string         `json:"x5u,omitempty"`
		Critical  json.RawMessage `json:"crit,omitempty"`
	}
	if err := json.Unmarshal(headerData, &header); err != nil || !contains(v.configuration.AllowedAlgorithms, header.Algorithm) || header.KeyID == "" || len(header.KeyID) > 256 || header.JKU != nil || header.X5U != nil || len(header.Critical) != 0 {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	payloadData, err := decodeCanonicalRawURL(parts[1], 16384)
	if err != nil || rejectDuplicateKeys(payloadData) != nil {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	if err := v.ensureKey(ctx, header.KeyID); err != nil {
		return domain.Principal{}, err
	}
	v.mu.Lock()
	key := v.keys[header.KeyID]
	v.mu.Unlock()
	if key == nil {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	claims := &accessClaims{}
	parser := jwt.NewParser(
		jwt.WithValidMethods(v.configuration.AllowedAlgorithms),
		jwt.WithIssuer(v.configuration.Issuer.String()),
		jwt.WithAudience(v.configuration.Audience),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
		jwt.WithLeeway(v.configuration.ClockSkew),
	)
	parsed, err := parser.ParseWithClaims(token, claims, func(parsed *jwt.Token) (any, error) {
		if parsed.Method.Alg() != header.Algorithm || parsed.Header["kid"] != header.KeyID {
			return nil, errors.New("header changed")
		}
		return key, nil
	})
	if err != nil || !parsed.Valid {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	now := v.now()
	if claims.Subject == "" || len(claims.Subject) > 256 || claims.Issuer != v.configuration.Issuer.String() || len(claims.Audience) != 1 || claims.Audience[0] != v.configuration.Audience || claims.IssuedAt == nil || claims.ExpiresAt == nil || !claims.ExpiresAt.After(claims.IssuedAt.Time) || claims.ExpiresAt.Sub(claims.IssuedAt.Time) > v.configuration.MaximumTokenAge || claims.ExpiresAt.Sub(now) > v.configuration.MaximumTokenAge+v.configuration.ClockSkew || now.Sub(claims.IssuedAt.Time) > v.configuration.MaximumTokenAge+v.configuration.ClockSkew || claims.IssuedAt.Sub(now) > v.configuration.ClockSkew {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	if claims.NotBefore != nil && (claims.NotBefore.Sub(now) > v.configuration.ClockSkew || claims.NotBefore.After(claims.ExpiresAt.Time)) {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	parties := make([]string, 0, 2)
	if claims.AuthorizedParty != "" {
		parties = append(parties, claims.AuthorizedParty)
	}
	if claims.ClientID != "" {
		parties = append(parties, claims.ClientID)
	}
	if len(parties) == 0 {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	for _, party := range parties {
		if party != v.configuration.ClientID || len(party) > 256 {
			return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
		}
	}
	if len(claims.AMR) > 16 || len(claims.ACR) > 256 {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	for _, method := range claims.AMR {
		if method == "" || len(method) > 64 {
			return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
		}
	}
	if requirement == RecentPhishingResistant {
		if claims.AuthenticationTime == nil || claims.AuthenticationTime.Sub(now) > v.configuration.ClockSkew || now.Sub(claims.AuthenticationTime.Time) > v.configuration.StepUpMaximumAge+v.configuration.ClockSkew {
			return domain.Principal{}, domain.NewError(domain.ReauthenticationNeeded)
		}
		strong := false
		for _, method := range claims.AMR {
			if _, ok := v.configuration.StepUpAMR[strings.ToLower(method)]; ok {
				strong = true
			}
		}
		if _, ok := v.configuration.StepUpACR[claims.ACR]; ok {
			strong = true
		}
		if !strong {
			return domain.Principal{}, domain.NewError(domain.ReauthenticationNeeded)
		}
	}
	canonicalToken, err := canonicalCredentialToken(parts, header.Algorithm)
	if err != nil {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	identityDigest := keyedDigest(v.configuration.IdentityPepper, "snippets-oidc-identity-v1", []byte(claims.Issuer), []byte(claims.Subject))
	credentialDigest := keyedDigest(v.configuration.IdentityPepper, "snippets-oidc-credential-v1", canonicalToken)
	return domain.Principal{IdentityDigest: identityDigest, CredentialDigest: credentialDigest, ExpiresAt: claims.ExpiresAt.Time, AuthenticatedAt: valueOrZero(claims.AuthenticationTime), AMR: append([]string(nil), claims.AMR...), ACR: claims.ACR}, nil
}

func (v *OIDCValidator) ensureKey(ctx context.Context, keyID string) error {
	now := v.now()
	v.mu.Lock()
	if _, ok := v.keys[keyID]; ok {
		stale := now.Sub(v.lastRefresh) >= v.configuration.JWKSRefreshInterval && now.Sub(v.lastAttempt) >= v.configuration.UnknownKeyRefreshInterval
		v.mu.Unlock()
		if stale {
			_ = v.refresh(ctx, false)
		}
		return nil
	}
	if until := v.negative[keyID]; until.After(now) {
		v.mu.Unlock()
		return domain.NewError(domain.AuthenticationRequired)
	}
	canRefresh := now.Sub(v.lastAttempt) >= v.configuration.UnknownKeyRefreshInterval
	v.mu.Unlock()
	if canRefresh {
		if err := v.refresh(ctx, true); err != nil {
			return err
		}
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if _, ok := v.keys[keyID]; ok {
		delete(v.negative, keyID)
		return nil
	}
	ttl := v.configuration.UnknownKeyCacheTTL
	if !canRefresh {
		ttl = v.configuration.UnknownKeyRefreshInterval - now.Sub(v.lastAttempt)
		if ttl < time.Second {
			ttl = time.Second
		}
	}
	if len(v.negative) >= 256 {
		for id := range v.negative {
			delete(v.negative, id)
			break
		}
	}
	v.negative[keyID] = now.Add(ttl)
	return domain.NewError(domain.AuthenticationRequired)
}

func (v *OIDCValidator) refresh(ctx context.Context, failClosed bool) error {
	v.mu.Lock()
	if running := v.refreshing; running != nil {
		v.mu.Unlock()
		select {
		case <-running:
			v.mu.Lock()
			err := v.refreshErr
			v.mu.Unlock()
			if err != nil && failClosed {
				return domain.NewError(domain.DependencyUnavailable)
			}
			return nil
		case <-ctx.Done():
			return domain.NewError(domain.DependencyUnavailable)
		}
	}
	running := make(chan struct{})
	v.refreshing = running
	v.refreshErr = nil
	v.lastAttempt = v.now()
	v.mu.Unlock()
	keys, err := v.fetch(ctx)
	v.mu.Lock()
	if err == nil {
		v.keys, v.lastRefresh = keys, v.now()
		for id := range keys {
			delete(v.negative, id)
		}
	}
	v.refreshErr = err
	close(running)
	v.refreshing = nil
	v.mu.Unlock()
	if err != nil && failClosed {
		return domain.NewError(domain.DependencyUnavailable)
	}
	return nil
}

func (v *OIDCValidator) fetch(ctx context.Context) (map[string]any, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, v.configuration.JWKSURL.String(), nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/json")
	response, err := v.client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || response.Request.URL.String() != v.configuration.JWKSURL.String() {
		return nil, errors.New("JWKS unavailable")
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 524289))
	if err != nil || len(data) == 0 || len(data) > 524288 || rejectDuplicateKeys(data) != nil {
		return nil, errors.New("invalid JWKS")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var document jwksDocument
	if err := decoder.Decode(&document); err != nil || len(document.Keys) == 0 || len(document.Keys) > 64 {
		return nil, errors.New("invalid JWKS")
	}
	keys := make(map[string]any, len(document.Keys))
	for _, value := range document.Keys {
		if value.KID == "" || len(value.KID) > 256 || keys[value.KID] != nil || (value.Use != "" && value.Use != "sig") || !allowsVerification(value.KeyOps) {
			return nil, errors.New("invalid JWK")
		}
		key, err := parseJWK(value)
		if err != nil {
			return nil, err
		}
		keys[value.KID] = key
	}
	return keys, nil
}

func parseJWK(value jwk) (any, error) {
	if value.KTY == "RSA" && (value.ALG == "" || value.ALG == "RS256") {
		n, err := decodeCanonicalRawURL(value.N, 1024)
		if err != nil || len(n) < 256 || n[0] == 0 {
			return nil, errors.New("invalid RSA JWK")
		}
		e, err := decodeCanonicalRawURL(value.E, 4)
		if err != nil || len(e) == 0 || len(e) > 4 || e[0] == 0 {
			return nil, errors.New("invalid RSA JWK")
		}
		var exponent uint64
		for _, b := range e {
			exponent = exponent<<8 | uint64(b)
		}
		if exponent < 3 || exponent > 1<<31-1 || exponent%2 == 0 {
			return nil, errors.New("invalid RSA exponent")
		}
		modulus := new(big.Int).SetBytes(n)
		if modulus.BitLen() < 2048 || modulus.BitLen() > 8192 {
			return nil, errors.New("invalid RSA modulus")
		}
		return &rsa.PublicKey{N: modulus, E: int(exponent)}, nil
	}
	if value.KTY == "EC" && value.CRV == "P-256" && (value.ALG == "" || value.ALG == "ES256") {
		x, err := decodeCanonicalRawURL(value.X, 32)
		if err != nil || len(x) != 32 {
			return nil, errors.New("invalid EC JWK")
		}
		y, err := decodeCanonicalRawURL(value.Y, 32)
		if err != nil || len(y) != 32 {
			return nil, errors.New("invalid EC JWK")
		}
		pointX, pointY := new(big.Int).SetBytes(x), new(big.Int).SetBytes(y)
		if !elliptic.P256().IsOnCurve(pointX, pointY) {
			return nil, errors.New("invalid EC point")
		}
		return &ecdsa.PublicKey{Curve: elliptic.P256(), X: pointX, Y: pointY}, nil
	}
	return nil, errors.New("unsupported JWK")
}

func allowsVerification(operations []string) bool {
	if len(operations) == 0 {
		return true
	}
	for _, operation := range operations {
		if operation == "verify" {
			return true
		}
	}
	return false
}

func canonicalCredentialToken(parts []string, algorithm string) ([]byte, error) {
	signature, err := decodeCanonicalRawURL(parts[2], 1024)
	if err != nil || len(signature) == 0 {
		return nil, errors.New("invalid signature")
	}
	if algorithm == "ES256" {
		if len(signature) != 64 {
			return nil, errors.New("invalid ES256 signature")
		}
		order := elliptic.P256().Params().N
		s := new(big.Int).SetBytes(signature[32:])
		if s.Sign() <= 0 || s.Cmp(order) >= 0 {
			return nil, errors.New("invalid ES256 scalar")
		}
		reflected := new(big.Int).Sub(order, s)
		if reflected.Cmp(s) < 0 {
			s = reflected
		}
		lowS := s.FillBytes(make([]byte, 32))
		signature = append(append([]byte(nil), signature[:32]...), lowS...)
	}
	return []byte(parts[0] + "." + parts[1] + "." + base64.RawURLEncoding.EncodeToString(signature)), nil
}

func keyedDigest(secret []byte, label string, values ...[]byte) [32]byte {
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte(label))
	for _, value := range values {
		var size [4]byte
		binary.BigEndian.PutUint32(size[:], uint32(len(value)))
		_, _ = mac.Write(size[:])
		_, _ = mac.Write(value)
	}
	var result [32]byte
	copy(result[:], mac.Sum(nil))
	return result
}

func rejectDuplicateKeys(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := walkJSON(decoder); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("trailing JSON")
	}
	return nil
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
			key, err := decoder.Token()
			if err != nil {
				return err
			}
			name, ok := key.(string)
			if !ok {
				return errors.New("invalid object key")
			}
			if _, exists := seen[name]; exists {
				return errors.New("duplicate key")
			}
			seen[name] = struct{}{}
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
		return errors.New("invalid JSON delimiter")
	}
	_, err = decoder.Token()
	return err
}

func decodeCanonicalRawURL(value string, max int) ([]byte, error) {
	if value == "" || len(value) > base64.RawURLEncoding.EncodedLen(max) {
		return nil, errors.New("invalid base64url")
	}
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(value)
	if err != nil || len(decoded) > max || base64.RawURLEncoding.EncodeToString(decoded) != value {
		return nil, errors.New("invalid base64url")
	}
	return decoded, nil
}
func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
func valueOrZero(value *jwt.NumericDate) time.Time {
	if value == nil {
		return time.Time{}
	}
	return value.Time
}
