package config

import (
	"errors"
	"net/netip"
	"strings"
)

func parseNativeTrustedProxyCIDRs(raw string) ([]netip.Prefix, error) {
	invalid := func() ([]netip.Prefix, error) {
		return nil, errors.New("invalid AUTH_TRUSTED_PROXY_CIDRS")
	}
	if len(raw) > 2048 {
		return invalid()
	}
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	entries := strings.Split(raw, ",")
	if len(entries) > 32 {
		return invalid()
	}
	prefixes := make([]netip.Prefix, 0, len(entries))
	for _, entry := range entries {
		prefix, err := netip.ParsePrefix(strings.TrimSpace(entry))
		// Explicit networks only. A catch-all would trust headers from every
		// client; mapped prefixes are ambiguous after normalizing peer addresses.
		if err != nil || prefix.Bits() == 0 || prefix.Addr().Is4In6() || prefix != prefix.Masked() {
			return invalid()
		}
		prefixes = append(prefixes, prefix)
	}
	return prefixes, nil
}
