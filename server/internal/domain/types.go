package domain

import (
	"context"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"sort"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
)

const (
	MaxBlobBytes     = 900_000
	MaxRevisionBytes = 256
	MaxBatchRecords  = 50
	MaxPageRecords   = 50
	MaxRequestBytes  = 16 * 1024 * 1024
	// Strict request handling retains the raw JSON while token validation and
	// Base64 decoding allocate additional representations. Admission reserves a
	// conservative multiple until parsing can be fully streamed.
	MaxRequestMemoryReservation = 3 * MaxRequestBytes
	MaxResponseBytes            = 64 * 1024 * 1024
	MaxSpacesPerUser            = 100
	MaxKeyEnvelopeBytes         = 4_096
	MaxPairingSeconds           = 600
	MaxPairingsPerSpace         = 16
	MaxStorageBytesPerSpace     = int64(512 * 1024 * 1024)
	MaxStorageBytesPerUser      = int64(2 * 1024 * 1024 * 1024)
	MaxRecordsPerSpace          = int64(100_000)
	MaxChangesPerSpace          = int64(250_000)
	RecoveryAlgorithm           = "snippets-recovery-hkdf-sha256-aes256gcm-v1"
	PairingAlgorithm            = "snippets-pairing-p256-hkdf-sha256-aes256gcm-v1"
)

type StorageQuota struct {
	MaxBytesPerSpace   int64
	MaxBytesPerUser    int64
	MaxRecordsPerSpace int64
	MaxChangesPerSpace int64
}

var ProductionQuota = StorageQuota{
	MaxBytesPerSpace: MaxStorageBytesPerSpace, MaxBytesPerUser: MaxStorageBytesPerUser,
	MaxRecordsPerSpace: MaxRecordsPerSpace, MaxChangesPerSpace: MaxChangesPerSpace,
}

type Principal struct {
	IdentityDigest   [32]byte
	CredentialDigest [32]byte
	ExpiresAt        time.Time
	AuthenticatedAt  time.Time
	AMR              []string
	ACR              string
}

type SpaceRole string

const (
	Owner  SpaceRole = "owner"
	Writer SpaceRole = "writer"
	Reader SpaceRole = "reader"
)

func (r SpaceRole) CanWrite() bool { return r == Owner || r == Writer }

type Scope struct {
	SpaceID           uuid.UUID `json:"spaceId"`
	ScopeBinding      string    `json:"scopeBinding"`
	DatasetGeneration uuid.UUID `json:"datasetGeneration"`
	FeedEpoch         uuid.UUID `json:"feedEpoch"`
}

// RequireCurrentMutationScope validates the scope observed by a client inside the
// same transaction that will perform its first record mutation. Per-record CAS cannot
// protect create-only writes after an operator rotates the dataset or feed.
func (expected Scope) RequireCurrentMutationScope(current Scope) error {
	if expected.SpaceID == uuid.Nil || expected.ScopeBinding == "" ||
		expected.DatasetGeneration == uuid.Nil || expected.FeedEpoch == uuid.Nil {
		return NewError(InvalidRequest)
	}
	if expected.SpaceID != current.SpaceID || expected.ScopeBinding != current.ScopeBinding {
		return NewError(Forbidden)
	}
	if expected.DatasetGeneration != current.DatasetGeneration {
		return NewError(DatasetReset)
	}
	if expected.FeedEpoch != current.FeedEpoch {
		return NewError(CursorInvalid)
	}
	return nil
}

type Space struct {
	Scope    Scope
	Role     SpaceRole
	KeyEpoch int
}

type WireRecord struct {
	ID      uuid.UUID
	Rev     string
	Deleted bool
	Blob    []byte
}

func (r WireRecord) Validate() error {
	if r.ID == uuid.Nil || !utf8.ValidString(r.Rev) || len([]byte(r.Rev)) == 0 || len([]byte(r.Rev)) > MaxRevisionBytes {
		return NewError(InvalidRequest)
	}
	if len(r.Blob) > MaxBlobBytes {
		return ErrorWithLimit(PayloadTooLarge, MaxBlobBytes)
	}
	return nil
}

type ServerRecord struct {
	Record        WireRecord
	RecordVersion string
}

type BatchItem struct {
	Record                WireRecord
	ExpectedRecordVersion *string
}

type BatchOutcome struct {
	Kind                string
	RecordVersion       *string
	Revision            *string
	AuthoritativeRecord *ServerRecord
	ErrorCode           *ErrorCode
	RetryAfterSeconds   *int
}

type BatchSubmission struct {
	Scope    Scope
	Outcomes []BatchOutcome
	Partial  bool
}

type ChangesPage struct {
	Scope        Scope
	Records      []ServerRecord
	Cursor       string
	HasMore      bool
	FullSnapshot bool
}

type RecoveryEnvelope struct {
	Version    int
	KeyEpoch   int
	Algorithm  string
	Ciphertext []byte
	CreatedAt  time.Time
}

type PutRecoveryEnvelope struct {
	ExpectedVersion *int
	KeyEpoch        int
	Algorithm       string
	Ciphertext      []byte
}

func (r PutRecoveryEnvelope) Validate() error {
	if r.KeyEpoch < 1 || r.Algorithm != RecoveryAlgorithm || (r.ExpectedVersion != nil && *r.ExpectedVersion < 1) {
		return NewError(InvalidRequest)
	}
	if len(r.Ciphertext) > MaxKeyEnvelopeBytes {
		return ErrorWithLimit(PayloadTooLarge, MaxKeyEnvelopeBytes)
	}
	return nil
}

type PairingState string

const (
	PairingPending  PairingState = "pending"
	PairingApproved PairingState = "approved"
)

type Pairing struct {
	ID                 uuid.UUID
	SpaceID            uuid.UUID
	RecipientPublicKey []byte
	Nonce              []byte
	AuthenticationTag  string
	State              PairingState
	Algorithm          *string
	Ciphertext         []byte
	ExpiresAt          time.Time
}

type CreatePairing struct {
	RecipientPublicKey []byte
	Nonce              []byte
	ExpiresInSeconds   int
}

func (r CreatePairing) Validate() error {
	if len(r.RecipientPublicKey) != 65 || r.RecipientPublicKey[0] != 4 || len(r.Nonce) != 32 || r.ExpiresInSeconds < 60 || r.ExpiresInSeconds > MaxPairingSeconds {
		return NewError(InvalidRequest)
	}
	if x, y := elliptic.Unmarshal(elliptic.P256(), r.RecipientPublicKey); x == nil || y == nil {
		return NewError(InvalidRequest)
	}
	return nil
}

type ApprovePairing struct {
	RecipientKeyHash []byte
	Algorithm        string
	Ciphertext       []byte
}

func (r ApprovePairing) Validate() error {
	if len(r.RecipientKeyHash) != sha256.Size || r.Algorithm != PairingAlgorithm {
		return NewError(InvalidRequest)
	}
	if len(r.Ciphertext) > MaxKeyEnvelopeBytes {
		return ErrorWithLimit(PayloadTooLarge, MaxKeyEnvelopeBytes)
	}
	return nil
}

func ConstantTimeEqual(a, b []byte) bool {
	return len(a) == len(b) && subtle.ConstantTimeCompare(a, b) == 1
}

func CanonicalBase64(data []byte) string { return base64.StdEncoding.EncodeToString(data) }

func DecodeCanonicalBase64(value string, max int) ([]byte, error) {
	if len(value) > base64.StdEncoding.EncodedLen(max) {
		return nil, ErrorWithLimit(PayloadTooLarge, max)
	}
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	if err != nil || len(decoded) > max || CanonicalBase64(decoded) != value {
		return nil, NewError(InvalidRequest)
	}
	return decoded, nil
}

func SortRecords(records []ServerRecord) {
	sort.Slice(records, func(i, j int) bool { return records[i].Record.ID.String() < records[j].Record.ID.String() })
}

type Store interface {
	Readiness(context.Context) error
	IsAccessTokenRevoked(context.Context, Principal) (bool, error)
	RevokeAccessToken(context.Context, Principal) error
	ListSpaces(context.Context, Principal) ([]Space, error)
	CreateSpace(context.Context, Principal, *uuid.UUID) (Space, error)
	GetSpace(context.Context, Principal, uuid.UUID) (Space, error)
	FetchChanges(context.Context, Principal, uuid.UUID, *string, int) (ChangesPage, error)
	Submit(context.Context, Principal, uuid.UUID, Scope, []BatchItem) (BatchSubmission, error)
	GetRecoveryEnvelope(context.Context, Principal, uuid.UUID) (Space, *RecoveryEnvelope, error)
	PutRecoveryEnvelope(context.Context, Principal, uuid.UUID, PutRecoveryEnvelope) (Space, RecoveryEnvelope, error)
	CreatePairing(context.Context, Principal, uuid.UUID, CreatePairing) (Space, Pairing, error)
	ApprovePairing(context.Context, Principal, uuid.UUID, uuid.UUID, ApprovePairing) (Space, Pairing, error)
	GetPairing(context.Context, Principal, uuid.UUID, uuid.UUID) (Space, Pairing, error)
	ClaimPairing(context.Context, Principal, uuid.UUID, uuid.UUID) (Space, Pairing, error)
	CancelPairing(context.Context, Principal, uuid.UUID, uuid.UUID) error
}
