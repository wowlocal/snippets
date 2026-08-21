package config

import (
	"encoding/base64"
	"testing"
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
