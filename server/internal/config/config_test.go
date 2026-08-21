package config

import (
	"encoding/base64"
	"testing"
	"time"

	"github.com/wowlocal/snippets/server/internal/domain"
)

func TestProductionDatabaseRequiresVerifiedTLSAndSCRAM(t *testing.T) {
	values := productionEnvironment()
	configuration, err := LoadFrom(mapLookup(values))
	if err != nil {
		t.Fatal(err)
	}
	if configuration.Database.TLSMode != "verify-full" || configuration.Database.TLSRootCert != "system" ||
		configuration.Database.ChannelBinding != "require" || configuration.Database.RequireAuth != "scram-sha-256" {
		t.Fatalf("weak production database transport: %#v", configuration.Database)
	}

	cases := map[string]func(map[string]string){
		"encryption without verification": func(values map[string]string) { values["DATABASE_TLS_MODE"] = "require" },
		"missing root CA":                 func(values map[string]string) { delete(values, "DATABASE_TLS_ROOT_CERT") },
		"optional channel binding":        func(values map[string]string) { values["DATABASE_CHANNEL_BINDING"] = "prefer" },
		"password authentication":         func(values map[string]string) { values["DATABASE_REQUIRE_AUTH"] = "password" },
		"JWKS staleness below refresh":    func(values map[string]string) { values["OIDC_JWKS_MAX_STALENESS_SECONDS"] = "899" },
		"unbounded JWKS staleness":        func(values map[string]string) { values["OIDC_JWKS_MAX_STALENESS_SECONDS"] = "86401" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			candidate := productionEnvironment()
			mutate(candidate)
			if _, err := LoadFrom(mapLookup(candidate)); err == nil {
				t.Fatal("weak production database configuration was accepted")
			}
		})
	}
}

func TestHTTPBudgetsCoverRequestAmplificationAndGracefulDrain(t *testing.T) {
	values := productionEnvironment()
	configuration, err := LoadFrom(mapLookup(values))
	if err != nil {
		t.Fatal(err)
	}
	if configuration.HTTP.BodyMemoryBudget < domain.MaxRequestMemoryReservation ||
		configuration.HTTP.ShutdownTimeout < configuration.HTTP.RequestTimeout+5*time.Second {
		t.Fatalf("unsafe HTTP defaults: %#v", configuration.HTTP)
	}

	for name, mutate := range map[string]func(map[string]string){
		"raw-body-only budget": func(values map[string]string) { values["HTTP_BODY_MEMORY_BUDGET_BYTES"] = "16777216" },
		"short shutdown":       func(values map[string]string) { values["HTTP_SHUTDOWN_TIMEOUT_SECONDS"] = "25" },
	} {
		t.Run(name, func(t *testing.T) {
			candidate := productionEnvironment()
			mutate(candidate)
			if _, err := LoadFrom(mapLookup(candidate)); err == nil {
				t.Fatal("unsafe HTTP configuration was accepted")
			}
		})
	}
}

func productionEnvironment() map[string]string {
	secret := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	return map[string]string{
		"SNIPPETS_ENV": "production", "PUBLIC_BASE_URL": "https://sync.example.test",
		"SERVER_INSTANCE_ID": "00000000-0000-4000-8000-000000000001",
		"OIDC_ISSUER":        "https://identity.example.test/", "OIDC_JWKS_URL": "https://identity.example.test/jwks",
		"OIDC_AUDIENCE": "https://sync.example.test", "OIDC_CLIENT_ID": "native-client",
		"OIDC_SCOPES": "openid offline_access", "OIDC_ALLOWED_ALGORITHMS": "RS256", "OIDC_STEP_UP_AMR_VALUES": "webauthn",
		"TOKEN_HMAC_SECRET": secret, "IDENTITY_PEPPER": secret,
		"DATABASE_HOST": "database.example.test", "DATABASE_NAME": "snippets", "DATABASE_RUNTIME_USER": "runtime",
		"DATABASE_RUNTIME_PASSWORD": "secret", "DATABASE_TLS_ROOT_CERT": "system",
	}
}

func mapLookup(values map[string]string) func(string) (string, bool) {
	return func(key string) (string, bool) {
		value, exists := values[key]
		return value, exists
	}
}
