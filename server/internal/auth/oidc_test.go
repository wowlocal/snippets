package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/domain"
)

func TestOIDCValidatorAcceptsBoundFreshTokenAndStepUp(t *testing.T) {
	fixture := newOIDCFixture(t, false)
	defer fixture.server.Close()
	validator, err := NewOIDCValidator(context.Background(), fixture.configuration, fixture.server.Client())
	if err != nil {
		t.Fatal(err)
	}
	token := fixture.token(t, "resource", "client", true)
	principal, err := validator.Validate(context.Background(), token, RecentPhishingResistant)
	if err != nil {
		t.Fatal(err)
	}
	if principal.IdentityDigest == [32]byte{} || principal.CredentialDigest == [32]byte{} {
		t.Fatal("empty principal digests")
	}
	again, err := validator.Validate(context.Background(), token, Standard)
	if err != nil || again.CredentialDigest != principal.CredentialDigest {
		t.Fatalf("credential digest unstable: %v", err)
	}
}

func TestOIDCValidatorRejectsWrongAudiencePartyAndWeakStepUp(t *testing.T) {
	fixture := newOIDCFixture(t, false)
	defer fixture.server.Close()
	validator, err := NewOIDCValidator(context.Background(), fixture.configuration, fixture.server.Client())
	if err != nil {
		t.Fatal(err)
	}
	cases := []string{fixture.token(t, "other", "client", true), fixture.token(t, "resource", "other", true)}
	for _, token := range cases {
		if _, err := validator.Validate(context.Background(), token, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
			t.Fatalf("invalid binding accepted: %v", err)
		}
	}
	weak := fixture.token(t, "resource", "client", false)
	if _, err := validator.Validate(context.Background(), weak, RecentPhishingResistant); domain.AsServiceError(err).Code != domain.ReauthenticationNeeded {
		t.Fatalf("weak step-up accepted: %v", err)
	}
}

func TestOIDCValidatorRejectsRemoteKeyHeadersAndDuplicateJSON(t *testing.T) {
	fixture := newOIDCFixture(t, false)
	defer fixture.server.Close()
	validator, err := NewOIDCValidator(context.Background(), fixture.configuration, fixture.server.Client())
	if err != nil {
		t.Fatal(err)
	}
	token := fixture.token(t, "resource", "client", true)
	parsed, _ := jwt.Parse(token, func(*jwt.Token) (any, error) { return &fixture.key.PublicKey, nil })
	parsed.Header["jku"] = "https://attacker.invalid/jwks"
	remote, err := parsed.SignedString(fixture.key)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := validator.Validate(context.Background(), remote, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatalf("jku accepted: %v", err)
	}
	parts := splitToken(token)
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","alg":"RS256","kid":"test-key"}`))
	duplicate := header + "." + parts[1] + "." + parts[2]
	if _, err := validator.Validate(context.Background(), duplicate, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatalf("duplicate header accepted: %v", err)
	}
}

func TestOIDCValidatorRejectsDuplicateJWKSKeyIDs(t *testing.T) {
	fixture := newOIDCFixture(t, true)
	defer fixture.server.Close()
	if _, err := NewOIDCValidator(context.Background(), fixture.configuration, fixture.server.Client()); domain.AsServiceError(err).Code != domain.DependencyUnavailable {
		t.Fatalf("duplicate kids accepted: %v", err)
	}
}

func TestJWKKeyOperationsMustAllowVerification(t *testing.T) {
	if allowsVerification([]string{"sign"}) {
		t.Fatal("sign-only JWK accepted for verification")
	}
	if !allowsVerification(nil) || !allowsVerification([]string{"verify"}) {
		t.Fatal("verification-capable JWK rejected")
	}
}

func TestOIDCValidatorIgnoresUnknownJWKSFieldsAndUnusableKeys(t *testing.T) {
	fixture := newOIDCFixtureWithJWKS(t, func(entry map[string]any) map[string]any {
		entry["x5t#S256"] = "metadata-is-ignored"
		return map[string]any{
			"keys": []any{
				map[string]any{"kid": "damaged", "kty": "RSA", "alg": 42},
				map[string]any{"kid": "future-key", "kty": "OKP", "alg": "EdDSA", "crv": "Ed25519", "x": "AA"},
				entry,
			},
			"issuer_metadata": map[string]any{"version": 2},
		}
	})
	defer fixture.server.Close()
	validator, err := NewOIDCValidator(context.Background(), fixture.configuration, fixture.server.Client())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := validator.Validate(context.Background(), fixture.token(t, "resource", "client", true), Standard); err != nil {
		t.Fatalf("valid verification key was discarded with unrelated JWKS entries: %v", err)
	}
}

func TestOIDCValidatorFailsClosedAfterAbsoluteJWKSStaleness(t *testing.T) {
	fixture := newOIDCFixture(t, false)
	validator, err := NewOIDCValidator(context.Background(), fixture.configuration, fixture.server.Client())
	if err != nil {
		t.Fatal(err)
	}
	token := fixture.token(t, "resource", "client", true)
	refreshedAt := validator.lastRefresh
	fixture.server.Close()

	validator.now = func() time.Time { return refreshedAt.Add(fixture.configuration.JWKSRefreshInterval + time.Second) }
	if _, err := validator.Validate(context.Background(), token, Standard); err != nil {
		t.Fatalf("cached key was not allowed inside stale-while-revalidate window: %v", err)
	}
	validator.now = func() time.Time { return refreshedAt.Add(fixture.configuration.JWKSMaximumStaleness + time.Second) }
	if _, err := validator.Validate(context.Background(), token, Standard); domain.AsServiceError(err).Code != domain.DependencyUnavailable {
		t.Fatalf("absolutely stale verification key remained usable: %v", err)
	}
}

type oidcFixture struct {
	key           *rsa.PrivateKey
	server        *httptest.Server
	configuration config.OIDC
}

func newOIDCFixture(t *testing.T, duplicate bool) oidcFixture {
	return newOIDCFixtureWithJWKS(t, func(entry map[string]any) map[string]any {
		keys := []any{entry}
		if duplicate {
			keys = append(keys, entry)
		}
		return map[string]any{"keys": keys}
	})
}

func newOIDCFixtureWithJWKS(t *testing.T, documentBuilder func(map[string]any) map[string]any) oidcFixture {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	encodedN := base64.RawURLEncoding.EncodeToString(key.PublicKey.N.Bytes())
	encodedE := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.PublicKey.E)).Bytes())
	entry := map[string]any{"kty": "RSA", "kid": "test-key", "alg": "RS256", "use": "sig", "n": encodedN, "e": encodedE}
	document, _ := json.Marshal(documentBuilder(entry))
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(document)
	}))
	jwks, _ := url.Parse(server.URL)
	issuer, _ := url.Parse("https://issuer.example/")
	configuration := config.OIDC{Issuer: issuer, Audience: "resource", ClientID: "client", JWKSURL: jwks, AllowedAlgorithms: []string{"RS256"}, MaximumTokenAge: 5 * time.Minute, ClockSkew: time.Minute, IdentityPepper: make([]byte, 32), JWKSRefreshInterval: time.Minute, JWKSMaximumStaleness: 3 * time.Minute, UnknownKeyRefreshInterval: time.Minute, UnknownKeyCacheTTL: 5 * time.Minute, StepUpAMR: map[string]struct{}{"webauthn": {}}, StepUpACR: map[string]struct{}{}, StepUpMaximumAge: 5 * time.Minute}
	return oidcFixture{key: key, server: server, configuration: configuration}
}
func (f oidcFixture) token(t *testing.T, audience, client string, strong bool) string {
	t.Helper()
	now := time.Now()
	claims := accessClaims{RegisteredClaims: jwt.RegisteredClaims{Issuer: f.configuration.Issuer.String(), Subject: "subject", Audience: jwt.ClaimStrings{audience}, ExpiresAt: jwt.NewNumericDate(now.Add(4 * time.Minute)), IssuedAt: jwt.NewNumericDate(now), NotBefore: jwt.NewNumericDate(now.Add(-time.Second))}, ClientID: client}
	if strong {
		claims.AuthenticationTime = jwt.NewNumericDate(now)
		claims.AMR = []string{"webauthn"}
	}
	token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	token.Header["kid"] = "test-key"
	value, err := token.SignedString(f.key)
	if err != nil {
		t.Fatal(err)
	}
	return value
}
func splitToken(value string) []string {
	result := make([]string, 0, 3)
	start := 0
	for i, char := range value {
		if char == '.' {
			result = append(result, value[start:i])
			start = i + 1
		}
	}
	return append(result, value[start:])
}
