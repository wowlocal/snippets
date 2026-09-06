package httpapi

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/wowlocal/snippets/server/internal/domain"
	"net/http"
	"testing"
)

func TestHTTPBootstrapChallengeAndExactRetry(t *testing.T) {
	server, store, principal, _ := testHTTPServer(t)
	space, err := store.CreateSpace(context.Background(), principal, nil)
	if err != nil {
		t.Fatal(err)
	}
	scope := mapScope(space.Scope, uuid.MustParse("00000000-0000-4000-8000-000000000001"))
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	base := "/v2/spaces/" + space.Scope.SpaceID.String()
	initial, _ := json.Marshal(map[string]any{"expectedScope": scope, "publicKey": pub, "recovery": map[string]any{
		"expectedVersion": nil, "keyEpoch": 1, "algorithm": domain.RecoveryAlgorithm, "ciphertext": []byte{1, 2, 3}}})
	response := perform(t, server, http.MethodPost, base+"/key-bootstrap", string(initial), "valid-token")
	if response.Code != 200 {
		t.Fatalf("bootstrap %d: %s", response.Code, response.Body.String())
	}
	if response = perform(t, server, http.MethodGet, base+"/key-authority", "", "valid-token"); response.Code != 200 {
		t.Fatalf("authority: %d", response.Code)
	}
	version := 1
	request := domain.PutRecoveryEnvelope{ExpectedVersion: &version, KeyEpoch: 1, Algorithm: domain.RecoveryAlgorithm, Ciphertext: []byte{4, 5, 6}}
	create, _ := json.Marshal(map[string]any{"expectedScope": scope, "action": domain.ReplaceRecovery, "keyEpoch": 1, "requestHash": request.ActionHash()})
	response = perform(t, server, http.MethodPost, base+"/key-challenges", string(create), "valid-token")
	if response.Code != 200 {
		t.Fatalf("challenge %d: %s", response.Code, response.Body.String())
	}
	var challenge struct {
		Challenge domain.LibraryChallenge `json:"challenge"`
	}
	if err = json.Unmarshal(response.Body.Bytes(), &challenge); err != nil {
		t.Fatal(err)
	}
	proof := domain.LibraryActionProof{ChallengeID: challenge.Challenge.ID, Signature: ed25519.Sign(priv, append([]byte("snippets-library-action-proof-v1\n"), challenge.Challenge.Nonce...))}
	body, _ := json.Marshal(map[string]any{"expectedVersion": 1, "keyEpoch": 1, "algorithm": domain.RecoveryAlgorithm, "ciphertext": request.Ciphertext, "proof": proof})
	for i := 0; i < 2; i++ {
		response = perform(t, server, http.MethodPut, base+"/recovery-envelope", string(body), "valid-token")
		if response.Code != 200 {
			t.Fatalf("signed update/retry %d: %s", response.Code, response.Body.String())
		}
		var result struct {
			Recovery struct {
				Version int `json:"version"`
			} `json:"recovery"`
		}
		if err = json.Unmarshal(response.Body.Bytes(), &result); err != nil || result.Recovery.Version != 2 {
			t.Fatal("retry reapplied the mutation")
		}
	}
	response = perform(t, server, http.MethodPut, base+"/key-authority", string(initial), "valid-token")
	if response.Code != 404 && response.Code != 405 {
		t.Fatalf("authority replacement route exists: %d", response.Code)
	}
}
