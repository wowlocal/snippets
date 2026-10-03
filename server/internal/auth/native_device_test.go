package auth

import (
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/wowlocal/snippets/server/internal/domain"
	"github.com/wowlocal/snippets/server/internal/postgres"
)

// Exercises ADR 0007 end to end against the real RLS data plane: a signed-out device
// receives a session for the approving account only after a library-key-authorized
// pairing for its own recipient key, then claims the library key with that session.
func TestNativePostgresDeviceApprovedSignIn(t *testing.T) {
	n, owner := nativeFixture(t)
	ctx := context.Background()
	approver := createNative(t, n, uuid.NewString())
	principal, err := n.Validate(ctx, approver.Session.AccessToken, Standard)
	if err != nil {
		t.Fatal(err)
	}
	store, err := postgres.NewStore(n.pool, uuid.New(), make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	space, err := store.CreateSpace(ctx, principal, nil)
	if err != nil {
		t.Fatal(err)
	}
	libraryPublic, libraryPrivate, _ := ed25519.GenerateKey(rand.Reader)
	if _, _, err := store.BootstrapLibraryKey(ctx, principal, space.Scope.SpaceID, domain.KeyBootstrap{ExpectedScope: space.Scope, PublicKey: libraryPublic, Recovery: domain.PutRecoveryEnvelope{KeyEpoch: 1, Algorithm: domain.RecoveryAlgorithm, Ciphertext: []byte("sealed recovery")}}); err != nil {
		t.Fatal(err)
	}
	recipientKey, _ := ecdh.P256().GenerateKey(rand.Reader)
	recipient, nonce := recipientKey.PublicKey().Bytes(), make([]byte, 32)
	_, _ = rand.Read(nonce)
	if _, err := n.CreateDeviceRequest(ctx, append([]byte{4}, make([]byte, 64)...), nonce, uuid.NewString()); domain.AsServiceError(err).Code != domain.InvalidRequest {
		t.Fatal("off-curve recipient key accepted")
	}
	request, err := n.CreateDeviceRequest(ctx, recipient, nonce, uuid.NewString())
	if err != nil || !validOpaque(request.PollToken, "sn_d_") {
		t.Fatal("device request not created", err)
	}
	if claim, err := n.ClaimDeviceRequest(ctx, request.ID, request.PollToken, uuid.NewString()); err != nil || claim.Approved || !claim.ExpiresAt.Equal(request.ExpiresAt) {
		t.Fatal("unapproved request did not report pending", err)
	}
	other, _ := randomOpaque("sn_d_")
	for _, poll := range []string{other, "malformed", ""} {
		if _, err := n.ClaimDeviceRequest(ctx, request.ID, poll, uuid.NewString()); domain.AsServiceError(err).Code != domain.NotFound {
			t.Fatal("wrong poll token was not refused")
		}
	}
	if _, err := n.ClaimDeviceRequest(ctx, uuid.New(), request.PollToken, uuid.NewString()); domain.AsServiceError(err).Code != domain.NotFound {
		t.Fatal("unknown request was not refused")
	}

	// The handler approves only an approved pairing; create one with a library-action proof.
	_, pairing, err := store.CreatePairing(ctx, principal, space.Scope.SpaceID, domain.CreatePairing{RecipientPublicKey: recipient, Nonce: nonce, ExpiresInSeconds: 600})
	if err != nil {
		t.Fatal(err)
	}
	keyHash := sha256.Sum256(recipient)
	approval := domain.ApprovePairing{RecipientKeyHash: keyHash[:], Algorithm: domain.PairingAlgorithm, Ciphertext: []byte("sealed library key")}
	_, challenge, err := store.CreateLibraryChallenge(ctx, principal, space.Scope.SpaceID, domain.CreateLibraryChallenge{ExpectedScope: space.Scope, Action: domain.ApproveDevice, KeyEpoch: 1, RequestHash: approval.ActionHash(pairing.ID)})
	if err != nil {
		t.Fatal(err)
	}
	approval.Proof = &domain.LibraryActionProof{ChallengeID: challenge.ID, Signature: ed25519.Sign(libraryPrivate, append([]byte("snippets-library-action-proof-v1\n"), challenge.Nonce...))}
	if _, _, err := store.ApprovePairing(ctx, principal, space.Scope.SpaceID, pairing.ID, approval); err != nil {
		t.Fatal(err)
	}
	otherKey, _ := ecdh.P256().GenerateKey(rand.Reader)
	if err := n.ApproveDeviceRequest(ctx, principal.CredentialDigest, request.ID, space.Scope.SpaceID, pairing.ID, otherKey.PublicKey().Bytes(), nonce); domain.AsServiceError(err).Code != domain.Conflict {
		t.Fatal("mismatched recipient key approved a request")
	}
	if err := n.ApproveDeviceRequest(ctx, [32]byte{1}, request.ID, space.Scope.SpaceID, pairing.ID, recipient, nonce); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatal("unknown credential approved a request")
	}
	for i := 0; i < 2; i++ {
		if err := n.ApproveDeviceRequest(ctx, principal.CredentialDigest, request.ID, space.Scope.SpaceID, pairing.ID, recipient, nonce); err != nil {
			t.Fatal("approval is not idempotent for its account", err)
		}
	}
	stranger := createNative(t, n, uuid.NewString())
	strangerPrincipal, _ := n.Validate(ctx, stranger.Session.AccessToken, Standard)
	if err := n.ApproveDeviceRequest(ctx, strangerPrincipal.CredentialDigest, request.ID, space.Scope.SpaceID, pairing.ID, recipient, nonce); domain.AsServiceError(err).Code != domain.Conflict {
		t.Fatal("another account rebound an approved request")
	}

	first, err := n.ClaimDeviceRequest(ctx, request.ID, request.PollToken, uuid.NewString())
	if err != nil || !first.Approved || first.SpaceID != space.Scope.SpaceID || first.PairingID != pairing.ID || first.Session.Account.ID != approver.Session.Account.ID {
		t.Fatal("approved request did not sign in the approving account", err)
	}
	device, err := n.Validate(ctx, first.Session.AccessToken, Standard)
	if err != nil || device.IdentityDigest != principal.IdentityDigest {
		t.Fatal("device session has a different sync identity", err)
	}
	if _, claimed, err := store.ClaimPairing(ctx, device, space.Scope.SpaceID, pairing.ID); err != nil || string(claimed.Ciphertext) != "sealed library key" {
		t.Fatal("signed-in device could not claim the library key", err)
	}
	// A repeated claim follows a lost response and retires the undelivered session.
	second, err := n.ClaimDeviceRequest(ctx, request.ID, request.PollToken, uuid.NewString())
	if err != nil || !second.Approved {
		t.Fatal(err)
	}
	if _, err := n.Validate(ctx, first.Session.AccessToken, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatal("repeated claim left the earlier device session active")
	}
	if _, err := n.Refresh(ctx, first.Session.RefreshToken, uuid.NewString()); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatal("repeated claim left the earlier refresh token active")
	}
	if _, err := n.Validate(ctx, second.Session.AccessToken, Standard); err != nil {
		t.Fatal("latest device session unusable")
	}
	if _, err := n.Validate(ctx, approver.Session.AccessToken, Standard); err != nil {
		t.Fatal("device claim affected the approving session")
	}
	for i := 0; i < 3; i++ {
		if _, err := n.ClaimDeviceRequest(ctx, request.ID, request.PollToken, uuid.NewString()); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := n.ClaimDeviceRequest(ctx, request.ID, request.PollToken, uuid.NewString()); domain.AsServiceError(err).Code != domain.Conflict {
		t.Fatal("device request claims are unbounded")
	}

	expired, err := n.CreateDeviceRequest(ctx, recipient, nonce, uuid.NewString())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := owner.Exec(ctx, "UPDATE snippets_private.native_device_requests SET expires_at=clock_timestamp()-interval '1 second' WHERE id=$1", expired.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := n.ClaimDeviceRequest(ctx, expired.ID, expired.PollToken, uuid.NewString()); domain.AsServiceError(err).Code != domain.PairingExpired {
		t.Fatal("expired request claimable")
	}
	if err := n.ApproveDeviceRequest(ctx, principal.CredentialDigest, expired.ID, space.Scope.SpaceID, pairing.ID, recipient, nonce); domain.AsServiceError(err).Code != domain.PairingExpired {
		t.Fatal("expired request approvable")
	}
	if _, err := n.pool.Exec(ctx, "SELECT * FROM snippets_private.native_device_requests"); err == nil {
		t.Fatal("runtime can enumerate device requests")
	}
	var stored int
	if err := owner.QueryRow(ctx, "SELECT count(*) FROM snippets_private.native_device_requests WHERE poll_digest=$1", []byte(request.PollToken)).Scan(&stored); err != nil || stored != 0 {
		t.Fatal("poll token stored in plaintext")
	}
	for _, scenario := range []struct {
		kind, key string
		budget    int
		attempt   func(*Native, string) error
	}{
		{"device_request_ip", uuid.NewString(), 30, func(n *Native, ip string) error {
			_, err := n.CreateDeviceRequest(ctx, recipient, nonce, ip)
			return err
		}},
		{"device_claim_ip", uuid.NewString(), 1800, func(n *Native, ip string) error {
			_, err := n.ClaimDeviceRequest(ctx, request.ID, request.PollToken, ip)
			return err
		}},
	} {
		configuration := n.configuration
		configuration.Secret = []byte(strings.Repeat("s", 16) + uuid.NewString())
		isolated, err := NewNative(n.pool, configuration)
		if err != nil {
			t.Fatal(err)
		}
		key := isolated.digest("rate-"+scenario.kind, scenario.key)
		if _, err := owner.Exec(ctx, "INSERT INTO snippets_private.native_rates VALUES($1,$2,clock_timestamp(),clock_timestamp()+interval '1 hour',$3)", key[:], scenario.kind, scenario.budget); err != nil {
			t.Fatal(err)
		}
		if domain.AsServiceError(scenario.attempt(isolated, scenario.key)).Code != domain.RateLimited {
			t.Fatal("device sign-in rate boundary bypassed", scenario.kind)
		}
	}
}
