package postgres

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"github.com/wowlocal/snippets/server/internal/domain"
	"sync"
	"testing"
)

// Uses the same real RLS runtime connection as the existing database lane.
func testLibraryActionTransactions(t *testing.T, store *Store) {
	t.Helper()
	ctx := context.Background()
	p := integrationPrincipal(97)
	space, err := store.CreateSpace(ctx, p, nil)
	if err != nil {
		t.Fatal(err)
	}
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	request := domain.KeyBootstrap{ExpectedScope: space.Scope, PublicKey: pub, Recovery: domain.PutRecoveryEnvelope{
		KeyEpoch: 1, Algorithm: domain.RecoveryAlgorithm, Ciphertext: []byte("encrypted bootstrap")}}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _, err := store.BootstrapLibraryKey(ctx, p, space.Scope.SpaceID, request)
			results <- err
		}()
	}
	wg.Wait()
	close(results)
	wins := 0
	for err := range results {
		if err == nil {
			wins++
		} else if domain.AsServiceError(err).Code != domain.Conflict {
			t.Fatal(err)
		}
	}
	if wins != 1 {
		t.Fatalf("bootstrap winners: %d", wins)
	}
	version := 1
	update := domain.PutRecoveryEnvelope{ExpectedVersion: &version, KeyEpoch: 1, Algorithm: domain.RecoveryAlgorithm, Ciphertext: []byte("encrypted replacement")}
	_, _, err = store.PutRecoveryEnvelope(ctx, p, space.Scope.SpaceID, update)
	if domain.AsServiceError(err).Code != domain.IncompatibleVersion {
		t.Fatalf("legacy downgrade: %v", err)
	}
	_, challenge, err := store.CreateLibraryChallenge(ctx, p, space.Scope.SpaceID, domain.CreateLibraryChallenge{
		ExpectedScope: space.Scope, Action: domain.ReplaceRecovery, KeyEpoch: 1, RequestHash: update.ActionHash()})
	if err != nil {
		t.Fatal(err)
	}
	update.Proof = &domain.LibraryActionProof{ChallengeID: challenge.ID, Signature: ed25519.Sign(priv, append([]byte("snippets-library-action-proof-v1\n"), challenge.Nonce...))}
	for i := 0; i < 2; i++ {
		_, result, err := store.PutRecoveryEnvelope(ctx, p, space.Scope.SpaceID, update)
		if err != nil || result.Version != 2 {
			t.Fatalf("atomic mutation/receipt %d: %v", i, err)
		}
	}
	update.Ciphertext = []byte("tampered")
	_, _, err = store.PutRecoveryEnvelope(ctx, p, space.Scope.SpaceID, update)
	if domain.AsServiceError(err).Code != domain.Forbidden {
		t.Fatalf("receipt replay changed body: %v", err)
	}
}
