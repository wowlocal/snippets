package httpapi

import (
	"net/http"
	"net/netip"

	"github.com/wowlocal/snippets/server/internal/domain"
)

const nativeClientIPHeader = "X-Snippets-Client-IP"

func nativeUsesClientIP(operation string) bool {
	return operation == "native_email_start" || operation == "native_email_verify" || operation == "native_refresh"
}

// The immediate peer is the trust boundary. The configured edge must overwrite
// this one header using its authenticated transport peer, never copy client XFF.
func nativeClientIP(r *http.Request, trusted []netip.Prefix) (string, error) {
	address, err := netip.ParseAddrPort(r.RemoteAddr)
	if err != nil {
		return "unknown", nil
	}
	if address.Addr().Zone() != "" {
		return "", domain.NewError(domain.InvalidRequest)
	}
	peer := address.Addr().Unmap()
	trustedPeer := false
	for _, prefix := range trusted {
		if prefix.Contains(peer) {
			trustedPeer = true
			break
		}
	}
	if !trustedPeer {
		return peer.String(), nil
	}
	values := r.Header.Values(nativeClientIPHeader)
	if len(values) != 1 || len(values[0]) > 45 {
		return "", domain.NewError(domain.InvalidRequest)
	}
	client, err := netip.ParseAddr(values[0])
	if err != nil || client.Zone() != "" {
		return "", domain.NewError(domain.InvalidRequest)
	}
	client = client.Unmap()
	if client.IsUnspecified() || client.IsMulticast() {
		return "", domain.NewError(domain.InvalidRequest)
	}
	return client.String(), nil
}
