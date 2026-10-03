package httpapi

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/wowlocal/snippets/server/internal/auth"
	"github.com/wowlocal/snippets/server/internal/domain"
)

const nativeTestAccount = "4f7d3c3e-41d9-4a0b-9b6e-7f0d1e2c3b4a"

type nativeHTTPProbe struct {
	calls     int
	ip        string
	key       string
	createErr error
	principal *domain.Principal
	approval  []any
	claim     auth.NativeDeviceClaim
}

func (p *nativeHTTPProbe) Validate(_ context.Context, token string, _ auth.Requirement) (domain.Principal, error) {
	if p.principal != nil && token == "approver" {
		return *p.principal, nil
	}
	return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
}
func (p *nativeHTTPProbe) CreateDeviceRequest(_ context.Context, publicKey, nonce []byte, ip string) (auth.NativeDeviceRequest, error) {
	p.calls++
	p.ip = ip
	return auth.NativeDeviceRequest{ID: uuid.MustParse(nativeTestAccount), PollToken: "sn_d_" + strings.Repeat("A", 43), ExpiresAt: time.Unix(1_900_000_000, 0)}, nil
}
func (p *nativeHTTPProbe) ApproveDeviceRequest(_ context.Context, credential [32]byte, request, space, pairing uuid.UUID, publicKey, nonce []byte) error {
	p.calls++
	p.approval = []any{credential, request, space, pairing, string(publicKey), string(nonce)}
	return nil
}
func (p *nativeHTTPProbe) ClaimDeviceRequest(_ context.Context, _ uuid.UUID, _ string, ip string) (auth.NativeDeviceClaim, error) {
	p.calls++
	p.ip = ip
	return p.claim, nil
}
func (p *nativeHTTPProbe) tokens() auth.NativeTokens {
	return auth.NativeTokens{AccessToken: "private-access", RefreshToken: "private-refresh", ExpiresIn: 300, TokenType: "Bearer", Account: auth.NativeAccount{ID: nativeTestAccount}}
}
func (p *nativeHTTPProbe) CreateAccount(_ context.Context, ip string) (auth.NativeAccountCreation, error) {
	p.calls++
	p.ip = ip
	return auth.NativeAccountCreation{AccountKey: "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7", Session: p.tokens()}, p.createErr
}
func (p *nativeHTTPProbe) SignIn(_ context.Context, key, ip string) (auth.NativeTokens, error) {
	p.calls++
	p.ip = ip
	p.key = key
	return p.tokens(), nil
}
func (p *nativeHTTPProbe) Refresh(_ context.Context, _, ip string) (auth.NativeTokens, error) {
	p.calls++
	p.ip = ip
	return p.tokens(), nil
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
	if native["flow"] != "account_key" || native["createAccountEndpoint"] != "https://sync.example.test/v2/auth/accounts" || native["signInEndpoint"] != "https://sync.example.test/v2/auth/sign-in" || len(native) != 5 || !containsJSONValue(discovery["capabilities"].([]any), "native-account-key-v1") || containsJSONValue(discovery["capabilities"].([]any), "native-email-code-v1") {
		t.Fatal("native discovery contract differs")
	}
	response = perform(t, service.Handler(), http.MethodPost, "/v2/auth/accounts", "", "")
	var created map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	session, _ := created["session"].(map[string]any)
	account, _ := session["account"].(map[string]any)
	if response.Code != 200 || response.Header().Get("Cache-Control") != "no-store" || probe.ip != "192.0.2.1" || created["accountKey"] != "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7" || len(created) != 2 || session["access_token"] != "private-access" || len(account) != 1 || account["id"] != nativeTestAccount {
		t.Fatal("native account creation metadata differs")
	}
	probe.createErr = domain.ErrorWithRetry(domain.RateLimited, 60)
	response = perform(t, service.Handler(), http.MethodPost, "/v2/auth/accounts", "", "")
	assertProblem(t, response, 429, domain.RateLimited)
	if response.Header().Get("Retry-After") != "60" {
		t.Fatal("rate response omits retry header")
	}
	before := probe.calls
	for _, request := range []struct{ path, body string }{
		{"/v2/auth/accounts", `{}`},
		{"/v2/auth/sign-in", `{"accountKey":"7KQF9M2XR4TDH8WBZN3CP6YE1AQ7","accountKey":"00000000000000000000000000HF"}`},
		{"/v2/auth/sign-in", `{"accountKey":"7KQF9M2XR4TDH8WBZN3CP6YE1AQ7","email":"private@example.test"}`},
		{"/v2/auth/sign-in", `{"accountKey":"` + strings.Repeat("A", 5000) + `"}`},
		{"/v2/auth/sign-in", `{}`},
	} {
		response = perform(t, service.Handler(), http.MethodPost, request.path, request.body, "")
		if response.Code != 400 && response.Code != 413 {
			t.Fatal("malformed body accepted", request.body)
		}
	}
	if probe.calls != before {
		t.Fatal("malformed requests reached authentication service")
	}
	response = perform(t, service.Handler(), http.MethodPost, "/v2/auth/sign-in", `{"accountKey":"7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"}`, "")
	if response.Code != 200 || !strings.Contains(response.Body.String(), "private-access") || probe.key != "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7" || strings.Contains(response.Body.String(), "accountKey") {
		t.Fatal("native sign-in failed or echoed the account key")
	}
	if strings.Contains(logs.String(), "private") || strings.Contains(logs.String(), "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7") {
		t.Fatal("authentication secret leaked into access logs")
	}
	for _, path := range []string{"/v2/auth/email/start", "/v2/auth/email/verify"} {
		response = perform(t, service.Handler(), http.MethodPost, path, `{"email":"private@example.test"}`, "")
		if response.Code != 404 {
			t.Fatal("email authentication route still exists")
		}
	}
	response = perform(t, existing.Handler(), http.MethodPost, "/v2/auth/accounts", "", "")
	if response.Code != 404 {
		t.Fatal("native auth available in oidc mode")
	}
}

func TestNativeHTTPDeviceSignInRequiresApprovedPairing(t *testing.T) {
	existing, store, principal, _ := testServer(t)
	configuration := existing.configuration
	configuration.AuthMode = "native"
	probe := &nativeHTTPProbe{principal: &principal}
	var logs bytes.Buffer
	service := NewServer(configuration, store, probe, slog.New(slog.NewJSONHandler(&logs, nil)))
	recipientKey, _ := ecdh.P256().GenerateKey(rand.Reader)
	recipient := recipientKey.PublicKey().Bytes()
	nonce := bytes.Repeat([]byte{9}, 32)
	body := `{"recipientPublicKey":"` + base64Std(recipient) + `","nonce":"` + base64Std(nonce) + `"}`
	response := perform(t, service.Handler(), http.MethodPost, "/v2/auth/device-requests", body, "")
	if response.Code != 200 || response.Header().Get("Cache-Control") != "no-store" || !strings.Contains(response.Body.String(), `"pollToken":"sn_d_`) || probe.ip != "192.0.2.1" {
		t.Fatal("device request creation differs", response.Code, response.Body.String())
	}
	for _, malformed := range []string{`{"recipientPublicKey":"` + base64Std(recipient) + `"}`, `{"recipientPublicKey":"` + base64Std(recipient) + `","nonce":"` + base64Std(nonce) + `","email":"x"}`} {
		if response := perform(t, service.Handler(), http.MethodPost, "/v2/auth/device-requests", malformed, ""); response.Code != 400 {
			t.Fatal("malformed device request accepted")
		}
	}
	ctx := context.Background()
	space, err := store.CreateSpace(ctx, principal, nil)
	if err != nil {
		t.Fatal(err)
	}
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	if _, _, err := store.BootstrapLibraryKey(ctx, principal, space.Scope.SpaceID, domain.KeyBootstrap{ExpectedScope: space.Scope, PublicKey: public, Recovery: domain.PutRecoveryEnvelope{KeyEpoch: 1, Algorithm: domain.RecoveryAlgorithm, Ciphertext: []byte("sealed")}}); err != nil {
		t.Fatal(err)
	}
	space, pairing, err := store.CreatePairing(ctx, principal, space.Scope.SpaceID, domain.CreatePairing{RecipientPublicKey: recipient, Nonce: nonce, ExpiresInSeconds: 600})
	if err != nil {
		t.Fatal(err)
	}
	request := "/v2/auth/device-requests/" + nativeTestAccount + "/approval"
	approval := `{"spaceId":"` + space.Scope.SpaceID.String() + `","pairingId":"` + pairing.ID.String() + `"}`
	if response := perform(t, service.Handler(), http.MethodPost, request, approval, ""); response.Code != 401 {
		t.Fatal("device approval accepted without a bearer token")
	}
	assertProblem(t, perform(t, service.Handler(), http.MethodPost, request, approval, "approver"), 409, domain.Conflict)
	if probe.approval != nil {
		t.Fatal("pending pairing reached device approval")
	}
	keyHash := sha256.Sum256(recipient)
	approve := domain.ApprovePairing{RecipientKeyHash: keyHash[:], Algorithm: domain.PairingAlgorithm, Ciphertext: []byte("sealed library key")}
	_, challenge, err := store.CreateLibraryChallenge(ctx, principal, space.Scope.SpaceID, domain.CreateLibraryChallenge{ExpectedScope: space.Scope, Action: domain.ApproveDevice, KeyEpoch: 1, RequestHash: approve.ActionHash(pairing.ID)})
	if err != nil {
		t.Fatal(err)
	}
	approve.Proof = &domain.LibraryActionProof{ChallengeID: challenge.ID, Signature: ed25519.Sign(private, append([]byte("snippets-library-action-proof-v1\n"), challenge.Nonce...))}
	if _, _, err := store.ApprovePairing(ctx, principal, space.Scope.SpaceID, pairing.ID, approve); err != nil {
		t.Fatal(err)
	}
	if response := perform(t, service.Handler(), http.MethodPost, request, approval, "approver"); response.Code != 204 || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("approved pairing did not approve the device request", response.Code)
	}
	if probe.approval[0] != principal.CredentialDigest || probe.approval[1] != uuid.MustParse(nativeTestAccount) || probe.approval[2] != space.Scope.SpaceID || probe.approval[3] != pairing.ID || probe.approval[4] != string(recipient) || probe.approval[5] != string(nonce) {
		t.Fatal("device approval was not bound to the pairing and approving credential")
	}
	claim := "/v2/auth/device-requests/" + nativeTestAccount + "/claim"
	probe.claim = auth.NativeDeviceClaim{ExpiresAt: time.Unix(1_900_000_000, 0)}
	response = perform(t, service.Handler(), http.MethodPost, claim, `{"pollToken":"private-poll"}`, "")
	if response.Code != 200 || strings.TrimSpace(response.Body.String()) != `{"expiresAt":"2030-03-17T17:46:40Z","state":"pending"}` {
		t.Fatal("pending claim differs", response.Body.String())
	}
	probe.claim = auth.NativeDeviceClaim{Approved: true, ExpiresAt: time.Unix(1_900_000_000, 0), SpaceID: space.Scope.SpaceID, PairingID: pairing.ID, Session: probe.tokens()}
	response = perform(t, service.Handler(), http.MethodPost, claim, `{"pollToken":"private-poll"}`, "")
	var claimed map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &claimed); err != nil || response.Code != 200 || claimed["state"] != "approved" || claimed["pairingId"] != pairing.ID.String() || claimed["spaceId"] != space.Scope.SpaceID.String() || claimed["session"] == nil {
		t.Fatal("approved claim differs", response.Body.String())
	}
	if strings.Contains(logs.String(), "private") || strings.Contains(logs.String(), "sn_d_") {
		t.Fatal("device sign-in secrets leaked into access logs")
	}
}

func base64Std(value []byte) string { return base64.StdEncoding.EncodeToString(value) }

func TestNativeHTTPInvalidAccountKeyIsUnauthorized(t *testing.T) {
	if domain.Status(domain.InvalidAccountKey) != http.StatusUnauthorized {
		t.Fatal("invalid account key must be an authentication failure")
	}
}
