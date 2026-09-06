package domain

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"strconv"
	"time"

	"github.com/google/uuid"
)

const LibraryActionCapability = "library-action-proof-v1"
const MaxLibraryChallenges = 16

type LibraryAction string

const (
	ReplaceRecovery LibraryAction = "replace_recovery"
	ApproveDevice   LibraryAction = "approve_pairing"
)

type LibraryActionProof struct {
	ChallengeID uuid.UUID `json:"challengeId"`
	Signature   []byte    `json:"signature"`
}

type KeyBootstrap struct {
	ExpectedScope Scope
	PublicKey     []byte
	Recovery      PutRecoveryEnvelope
}

type CreateLibraryChallenge struct {
	ExpectedScope Scope
	Action        LibraryAction
	KeyEpoch      int
	RequestHash   []byte
}

type LibraryChallenge struct {
	ID          uuid.UUID     `json:"challengeId"`
	Action      LibraryAction `json:"action"`
	KeyEpoch    int           `json:"keyEpoch"`
	RequestHash []byte        `json:"requestHash"`
	Nonce       []byte        `json:"nonce"`
	ExpiresAt   time.Time     `json:"expiresAt"`
}

// The receipt is written with the mutation. A lost response can be replayed only
// under the original identity, scope, signature and exact request, until expiry.
type LibraryActionReceipt struct {
	Recovery *RecoveryEnvelope `json:"recovery,omitempty"`
	Pairing  *Pairing          `json:"pairing,omitempty"`
}

func (r CreateLibraryChallenge) Validate() error {
	if (r.Action != ReplaceRecovery && r.Action != ApproveDevice) || r.KeyEpoch < 1 || len(r.RequestHash) != sha256.Size {
		return NewError(InvalidRequest)
	}
	return nil
}

func NewLibraryChallenge(r CreateLibraryChallenge, now time.Time) (LibraryChallenge, error) {
	if err := r.Validate(); err != nil {
		return LibraryChallenge{}, err
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return LibraryChallenge{}, err
	}
	return LibraryChallenge{ID: uuid.New(), Action: r.Action, KeyEpoch: r.KeyEpoch, RequestHash: append([]byte(nil), r.RequestHash...), Nonce: nonce, ExpiresAt: now.Add(5 * time.Minute).UTC()}, nil
}

func (c LibraryChallenge) Verify(publicKey []byte, proof *LibraryActionProof, action LibraryAction, epoch int, hash []byte, now time.Time) error {
	if proof == nil {
		return NewError(IncompatibleVersion)
	}
	if c.ID != proof.ChallengeID || c.Action != action || c.KeyEpoch != epoch || !ConstantTimeEqual(c.RequestHash, hash) || !c.ExpiresAt.After(now) || len(publicKey) != ed25519.PublicKeySize || len(c.Nonce) != 32 || len(proof.Signature) != ed25519.SignatureSize {
		return NewError(Forbidden)
	}
	message := append([]byte("snippets-library-action-proof-v1\n"), c.Nonce...)
	if !ed25519.Verify(ed25519.PublicKey(publicKey), message, proof.Signature) {
		return NewError(Forbidden)
	}
	return nil
}

func (r PutRecoveryEnvelope) ActionHash() []byte {
	version := "null"
	if r.ExpectedVersion != nil {
		version = strconv.Itoa(*r.ExpectedVersion)
	}
	digest := sha256.Sum256([]byte("snippets-recovery-action-v1\n" + strconv.Itoa(r.KeyEpoch) + "\n" + version + "\n" + r.Algorithm + "\n" + CanonicalBase64(r.Ciphertext)))
	return digest[:]
}

func (r ApprovePairing) ActionHash(pairingID uuid.UUID) []byte {
	digest := sha256.Sum256([]byte("snippets-pairing-action-v1\n" + pairingID.String() + "\n" + CanonicalBase64(r.RecipientKeyHash) + "\n" + r.Algorithm + "\n" + CanonicalBase64(r.Ciphertext)))
	return digest[:]
}
