package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"github.com/wowlocal/snippets/server/internal/auth"
	"github.com/wowlocal/snippets/server/internal/domain"
)

type nativeHTTPProbe struct {
	calls    int
	ip       string
	startErr error
}

func (p *nativeHTTPProbe) Validate(context.Context, string, auth.Requirement) (domain.Principal, error) {
	return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
}
func (p *nativeHTTPProbe) Start(_ context.Context, _ string, ip string) (auth.NativeChallenge, error) {
	p.calls++
	p.ip = ip
	return auth.NativeChallenge{ChallengeID: "challenge", ExpiresIn: 600, ResendAfter: 60, CodeLength: 6}, p.startErr
}
func (p *nativeHTTPProbe) Verify(_ context.Context, _, _, ip string) (auth.NativeTokens, error) {
	p.calls++
	p.ip = ip
	return auth.NativeTokens{AccessToken: "private-access", RefreshToken: "private-refresh", ExpiresIn: 300, TokenType: "Bearer", Account: auth.NativeAccount{ID: "account", Email: "private@example.test"}}, nil
}
func (p *nativeHTTPProbe) Refresh(ctx context.Context, _, ip string) (auth.NativeTokens, error) {
	return p.Verify(ctx, "", "", ip)
}
func (p *nativeHTTPProbe) Revoke(context.Context, string, string) error { p.calls++; return nil }
func TestNativeHTTPDiscoveryLimitsErrorsAndPrivacy(t *testing.T) {
	existing, store, _, _ := testServer(t)
	configuration := existing.configuration
	configuration.AuthMode = "native"
	configuration.OIDC.Issuer = nil
	probe := &nativeHTTPProbe{}
	var logs bytes.Buffer
	service := NewServer(configuration, store, probe, slog.New(slog.NewJSONHandler(&logs, nil)))
	response := perform(t, service.Handler(), http.MethodGet, "/.well-known/snippets-sync", "", "")
	var discovery map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &discovery); err != nil {
		t.Fatal(err)
	}
	if _, exists := discovery["oidc"]; exists {
		t.Fatal("native discovery included browser provider")
	}
	native := discovery["nativeAuth"].(map[string]any)
	if native["flow"] != "email_code" || native["startEndpoint"] != "https://sync.example.test/v2/auth/email/start" || !containsJSONValue(discovery["capabilities"].([]any), "native-email-code-v1") {
		t.Fatal("native discovery contract differs")
	}
	response = perform(t, service.Handler(), http.MethodPost, "/v2/auth/email/start", `{"email":"private@example.test"}`, "")
	if response.Code != 200 || response.Header().Get("Cache-Control") != "no-store" || probe.ip != "192.0.2.1" {
		t.Fatal("native start metadata differs")
	}
	probe.startErr = domain.ErrorWithRetry(domain.RateLimited, 60)
	response = perform(t, service.Handler(), http.MethodPost, "/v2/auth/email/start", `{"email":"private@example.test"}`, "")
	assertProblem(t, response, 429, domain.RateLimited)
	if response.Header().Get("Retry-After") != "60" {
		t.Fatal("rate response omits retry header")
	}
	before := probe.calls
	for _, body := range []string{`{"email":"a@example.test","email":"b@example.test"}`, `{"email":"a@example.test","extra":true}`, `{"email":"` + strings.Repeat("a", 5000) + `"}`} {
		response = perform(t, service.Handler(), http.MethodPost, "/v2/auth/email/start", body, "")
		if response.Code != 400 && response.Code != 413 {
			t.Fatal("malformed body accepted")
		}
	}
	if probe.calls != before {
		t.Fatal("malformed requests reached authentication service")
	}
	response = perform(t, service.Handler(), http.MethodPost, "/v2/auth/email/verify", `{"challengeId":"private-challenge","code":"123456"}`, "")
	if response.Code != 200 || !strings.Contains(response.Body.String(), "private-access") {
		t.Fatal("native verify failed")
	}
	if strings.Contains(logs.String(), "private") || strings.Contains(logs.String(), "123456") {
		t.Fatal("authentication secret leaked into access logs")
	}
	response = perform(t, existing.Handler(), http.MethodPost, "/v2/auth/email/start", `{"email":"private@example.test"}`, "")
	if response.Code != 404 {
		t.Fatal("native auth available in oidc mode")
	}
}
