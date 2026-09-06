package config

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestNativeTrustedProxyConfigurationIsExplicitAndBounded(t *testing.T) {
	values := productionEnvironment()
	values["AUTH_MODE"] = "native"
	values["NATIVE_AUTH_SECRET"] = base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	values["SMTP_HOST"] = "smtp.example.test"
	values["SMTP_FROM"] = "snippets@example.test"
	for _, raw := range []string{"", " ", "127.0.0.1/32, ::1/128", strings.TrimSuffix(strings.Repeat("10.0.0.0/24,", 32), ",")} {
		values["AUTH_TRUSTED_PROXY_CIDRS"] = raw
		configuration, err := LoadFrom(mapLookup(values))
		if err != nil {
			t.Fatal("valid trusted proxy configuration rejected")
		}
		if strings.TrimSpace(raw) == "" && len(configuration.NativeAuth.TrustedProxyCIDRs) != 0 {
			t.Fatal("empty configuration trusts a proxy")
		}
		if strings.Contains(raw, "::1") && len(configuration.NativeAuth.TrustedProxyCIDRs) != 2 {
			t.Fatal("explicit IPv4 and IPv6 trust was not loaded")
		}
	}
	for _, raw := range []string{
		"private-invalid-value", "127.0.0.1", "0.0.0.0/0", "::/0", "::1/129",
		"::ffff:127.0.0.1/128", "fe80::1%eth0/128", "127.0.0.1/24",
		"127.0.0.1/32,", strings.TrimSuffix(strings.Repeat("10.0.0.0/24,", 33), ","), strings.Repeat(" ", 2049),
	} {
		values["AUTH_TRUSTED_PROXY_CIDRS"] = raw
		_, err := LoadFrom(mapLookup(values))
		if err == nil || err.Error() != "invalid AUTH_TRUSTED_PROXY_CIDRS" {
			t.Fatal("invalid proxy configuration was accepted or exposed its contents")
		}
	}
}
