package domain

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"github.com/google/uuid"
	"testing"
	"time"
)

func TestLibraryAuthorityBootstrapAndBoundProof(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t, ProductionQuota)
	p := principal(71)
	space, err := store.CreateSpace(ctx, p, nil)
	if err != nil {
		t.Fatal(err)
	}
	id := space.Scope.SpaceID
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	initial := PutRecoveryEnvelope{KeyEpoch: 1, Algorithm: RecoveryAlgorithm, Ciphertext: []byte("encrypted-first")}
	_, _, err = store.BootstrapLibraryKey(ctx, p, id, KeyBootstrap{ExpectedScope: space.Scope, PublicKey: pub, Recovery: initial})
	if err != nil {
		t.Fatalf("ordinary login bootstrap: %v", err)
	}
	_, _, err = store.BootstrapLibraryKey(ctx, p, id, KeyBootstrap{ExpectedScope: space.Scope, PublicKey: pub, Recovery: initial})
	if AsServiceError(err).Code != Conflict {
		t.Fatalf("second bootstrap: %v", err)
	}
	version := 1
	replacement := PutRecoveryEnvelope{ExpectedVersion: &version, KeyEpoch: 1, Algorithm: RecoveryAlgorithm, Ciphertext: []byte("encrypted-second")}
	_, _, err = store.PutRecoveryEnvelope(ctx, p, id, replacement)
	if AsServiceError(err).Code != IncompatibleVersion {
		t.Fatalf("downgrade accepted: %v", err)
	}
	_, challenge, err := store.CreateLibraryChallenge(ctx, p, id, CreateLibraryChallenge{ExpectedScope: space.Scope, Action: ReplaceRecovery, KeyEpoch: 1, RequestHash: replacement.ActionHash()})
	if err != nil {
		t.Fatal(err)
	}
	replacement.Proof = &LibraryActionProof{ChallengeID: challenge.ID, Signature: ed25519.Sign(priv, append([]byte("snippets-library-action-proof-v1\n"), challenge.Nonce...))}
	tampered := replacement
	tampered.Ciphertext = []byte("other")
	_, _, err = store.PutRecoveryEnvelope(ctx, p, id, tampered)
	if AsServiceError(err).Code != Forbidden {
		t.Fatalf("changed payload accepted: %v", err)
	}
	_, saved, err := store.PutRecoveryEnvelope(ctx, p, id, replacement)
	if err != nil || saved.Version != 2 {
		t.Fatalf("signed write: %v", err)
	}
	_, replayed, err := store.PutRecoveryEnvelope(ctx, p, id, replacement)
	if err != nil || replayed.Version != saved.Version {
		t.Fatalf("lost-response replay: %v", err)
	}
	// A valid proof doesn't survive a scope change, identity change or expiration.
	original := challenge
	for _, mutate := range []func(*LibraryChallenge){
		func(c *LibraryChallenge) { c.Action = ApproveDevice }, func(c *LibraryChallenge) { c.KeyEpoch++ },
		func(c *LibraryChallenge) { c.ExpiresAt = time.Now().Add(-time.Second) },
		func(c *LibraryChallenge) { c.Nonce[0] ^= 1 },
	} {
		c := original
		c.Nonce = append([]byte(nil), original.Nonce...)
		mutate(&c)
		if c.Verify(pub, replacement.Proof, ReplaceRecovery, 1, replacement.ActionHash(), time.Now()) == nil {
			t.Fatal("altered challenge accepted")
		}
	}
	other := p
	other.IdentityDigest[0] ^= 1
	_, _, err = store.PutRecoveryEnvelope(ctx, other, id, replacement)
	if err == nil {
		t.Fatal("other identity accepted")
	}
}

func TestLibraryChallengesAreBoundedAndBootstrapRejectsExistingRecords(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t, ProductionQuota)
	p := principal(73)
	space, _ := store.CreateSpace(ctx, p, nil)
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	recovery := PutRecoveryEnvelope{KeyEpoch: 1, Algorithm: RecoveryAlgorithm, Ciphertext: []byte{1}}
	_, _, err := store.BootstrapLibraryKey(ctx, p, space.Scope.SpaceID, KeyBootstrap{ExpectedScope: space.Scope, PublicKey: pub, Recovery: recovery})
	if err != nil {
		t.Fatal(err)
	}
	request := CreateLibraryChallenge{ExpectedScope: space.Scope, Action: ReplaceRecovery, KeyEpoch: 1, RequestHash: make([]byte, 32)}
	for i := 0; i < MaxLibraryChallenges; i++ {
		if _, _, err = store.CreateLibraryChallenge(ctx, p, space.Scope.SpaceID, request); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err = store.CreateLibraryChallenge(ctx, p, space.Scope.SpaceID, request); err == nil {
		t.Fatal("challenge cap bypassed")
	}
	request.ExpectedScope.ScopeBinding = "different"
	if _, _, err = store.CreateLibraryChallenge(ctx, p, space.Scope.SpaceID, request); err == nil {
		t.Fatal("scope binding bypassed")
	}
}

func TestAppleAndroidProofVector(t *testing.T) {
	pub, _ := base64.StdEncoding.DecodeString("BpJCgx4cUQSQFyZtp9NGBSH/vu8g+LUff0Gzc60K4kc=")
	signature, _ := base64.StdEncoding.DecodeString("SpmC5BUDjmvaeUhXOjcTs6NtUfD+ncwuUbzstz3x7AqqSNwKasvgalPp0F0Ly8JKPW+qqzodsPyV8VuMniznCw==")
	id := uuid.MustParse("30000000-0000-0000-0000-000000000001")
	c := LibraryChallenge{ID: id, Action: ReplaceRecovery, KeyEpoch: 1, RequestHash: bytesOf(1, 32), Nonce: bytesOf(7, 32), ExpiresAt: time.Now().Add(time.Minute)}
	if err := c.Verify(pub, &LibraryActionProof{ChallengeID: id, Signature: signature}, ReplaceRecovery, 1, bytesOf(1, 32), time.Now()); err != nil {
		t.Fatal(err)
	}
	appleSignature, _ := base64.StdEncoding.DecodeString("9/kms0Wk/deM5dJkCEoev+bCUo9iyavmhD10vwCC9duRjDmdwIiPqW0pne2ZBR3ryzgzg3x7MIf+EDYgQYLjBQ==")
	if err := c.Verify(pub, &LibraryActionProof{ChallengeID: id, Signature: appleSignature}, ReplaceRecovery, 1, bytesOf(1, 32), time.Now()); err != nil {
		t.Fatal(err)
	}
}

func TestLibraryBootstrapDoesNotOverwriteRecords(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t, ProductionQuota)
	p := principal(74)
	space, _ := store.CreateSpace(ctx, p, nil)
	if result, err := store.Submit(ctx, p, space.Scope.SpaceID, space.Scope, []BatchItem{{Record: WireRecord{ID: uuid.New(), Rev: "1", Blob: []byte("opaque record")}}}); err != nil || len(result.Outcomes) != 1 || result.Outcomes[0].ErrorCode != nil {
		t.Fatalf("could not seed the existing record: %v", err)
	}
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	_, _, err := store.BootstrapLibraryKey(ctx, p, space.Scope.SpaceID, KeyBootstrap{ExpectedScope: space.Scope, PublicKey: pub, Recovery: PutRecoveryEnvelope{KeyEpoch: 1, Algorithm: RecoveryAlgorithm, Ciphertext: []byte("opaque")}})
	if AsServiceError(err).Code != Conflict {
		t.Fatalf("bootstrap overwrote existing library: %v", err)
	}
}
