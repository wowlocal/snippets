package httpapi

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"

	"github.com/wowlocal/snippets/server/internal/domain"
)

func TestNativeHTTPProxyTrustBindsRateIdentityAndRejectsAmbiguity(t *testing.T) {
	for _, operation := range []struct{ path, body string }{
		{"/v2/auth/email/start", `{"email":"private@example.test"}`},
		{"/v2/auth/email/verify", `{"challengeId":"private-challenge","code":"123456"}`},
		{"/v2/auth/refresh", `{"refreshToken":"private-refresh"}`},
	} {
		for _, scenario := range []struct {
			name, peer, expected string
			trusted              bool
			headers              []string
		}{
			{"default ignores forged header", "127.0.0.9:1234", "127.0.0.9", false, []string{"198.51.100.37"}},
			{"untrusted peer ignores forged header", "192.0.2.9:1234", "192.0.2.9", true, []string{"198.51.100.37"}},
			{"untrusted peer ignores malformed duplicates", "192.0.2.9:1234", "192.0.2.9", true, []string{"private-invalid", "198.51.100.37"}},
			{"trusted client one", "127.0.0.9:1234", "198.51.100.37", true, []string{"198.51.100.37"}},
			{"trusted client two", "127.0.0.9:1234", "198.51.100.38", true, []string{"198.51.100.38"}},
			{"mapped peer and client normalize", "[::ffff:127.0.0.9]:1234", "198.51.100.37", true, []string{"::ffff:198.51.100.37"}},
			{"IPv6 client", "[::1]:1234", "2001:db8::1", true, []string{"2001:db8::1"}},
			{"scoped peer", "[fe80::1%private-interface]:1234", "", true, []string{"198.51.100.37"}},
			{"missing cannot use XFF", "127.0.0.9:1234", "", true, nil},
			{"duplicate", "127.0.0.9:1234", "", true, []string{"198.51.100.37", "198.51.100.38"}},
			{"comma list", "127.0.0.9:1234", "", true, []string{"198.51.100.37,198.51.100.38"}},
			{"empty", "127.0.0.9:1234", "", true, []string{""}},
			{"malformed", "127.0.0.9:1234", "", true, []string{"private-invalid"}},
			{"port", "127.0.0.9:1234", "", true, []string{"198.51.100.37:1234"}},
			{"zone", "127.0.0.9:1234", "", true, []string{"fe80::1%private-interface"}},
			{"whitespace", "127.0.0.9:1234", "", true, []string{" 198.51.100.37 "}},
			{"oversized", "127.0.0.9:1234", "", true, []string{strings.Repeat("a", 46)}},
			{"unspecified", "127.0.0.9:1234", "", true, []string{"0.0.0.0"}},
			{"multicast", "127.0.0.9:1234", "", true, []string{"ff02::1"}},
		} {
			t.Run(operation.path+"/"+scenario.name, func(t *testing.T) {
				existing, store, _, _ := testServer(t)
				configuration := existing.configuration
				configuration.AuthMode = "native"
				if scenario.trusted {
					configuration.NativeAuth.TrustedProxyCIDRs = []netip.Prefix{
						netip.MustParsePrefix("127.0.0.0/8"), netip.MustParsePrefix("::1/128"),
					}
				}
				probe := &nativeHTTPProbe{}
				var logs bytes.Buffer
				service := NewServer(configuration, store, probe, slog.New(slog.NewJSONHandler(&logs, nil)))
				request := httptest.NewRequest(http.MethodPost, "https://local"+operation.path, strings.NewReader(operation.body))
				request.RemoteAddr = scenario.peer
				request.Header.Set("Content-Type", "application/json")
				request.Header.Set("X-Forwarded-For", "203.0.113.99")
				for _, header := range scenario.headers {
					request.Header.Add(nativeClientIPHeader, header)
				}
				response := httptest.NewRecorder()
				service.Handler().ServeHTTP(response, request)
				if scenario.expected == "" {
					assertProblem(t, response, http.StatusBadRequest, domain.InvalidRequest)
					if probe.calls != 0 {
						t.Fatal("ambiguous proxy input reached authentication")
					}
				} else if response.Code != http.StatusOK || probe.calls != 1 || probe.ip != scenario.expected {
					t.Fatal("authentication rate identity was not derived from its authorized source")
				}
				if response.Header().Get("Cache-Control") != "no-store" {
					t.Fatal("native proxy response can be cached")
				}
				for _, private := range []string{"private", "127.0.0.9", "198.51.100.", "203.0.113.99", "2001:db8"} {
					if strings.Contains(logs.String(), private) {
						t.Fatal("proxy identity or input leaked into request logs")
					}
				}
			})
		}
	}
}

func TestNativeProxyHeaderIsNotRequiredForDiscoveryOrRevocation(t *testing.T) {
	existing, store, _, _ := testServer(t)
	configuration := existing.configuration
	configuration.AuthMode = "native"
	configuration.NativeAuth.TrustedProxyCIDRs = []netip.Prefix{netip.MustParsePrefix("192.0.2.0/24")}
	probe := &nativeHTTPProbe{}
	service := NewServer(configuration, store, probe, nil)
	if response := perform(t, service.Handler(), http.MethodGet, "/.well-known/snippets-sync", "", ""); response.Code != http.StatusOK {
		t.Fatal("proxy identity unexpectedly required for discovery")
	}
	if response := perform(t, service.Handler(), http.MethodPost, "/v2/auth/revoke", `{"token":"private-refresh","tokenTypeHint":"refresh_token"}`, ""); response.Code != http.StatusNoContent {
		t.Fatal("proxy identity unexpectedly required for revocation")
	}
}
