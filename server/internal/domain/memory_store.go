package domain

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"sort"
	"sync"
	"time"

	"github.com/google/uuid"
)

type memoryMembership struct {
	role         SpaceRole
	scopeBinding string
}

type memoryRecord struct {
	record     WireRecord
	generation int64
}

type memoryChange struct {
	sequence   int64
	record     WireRecord
	generation int64
}

type memoryPairing struct {
	value            Pairing
	recipientKeyHash [32]byte
}

type memorySpace struct {
	ownerIdentity     string
	datasetGeneration uuid.UUID
	feedEpoch         uuid.UUID
	keyEpoch          int
	nextSequence      int64
	memberships       map[string]memoryMembership
	records           map[uuid.UUID]memoryRecord
	changes           []memoryChange
	recovery          *RecoveryEnvelope
	pairings          map[uuid.UUID]memoryPairing
}

type MemoryStore struct {
	mu                 sync.Mutex
	serverInstanceID   uuid.UUID
	codec              *TokenCodec
	quota              StorageQuota
	spaces             map[uuid.UUID]*memorySpace
	idempotentSpaces   map[string]map[uuid.UUID]uuid.UUID
	revokedCredentials map[string]struct{}
	now                func() time.Time
}

func NewMemoryStore(serverInstanceID uuid.UUID, tokenSecret []byte, quota StorageQuota) (*MemoryStore, error) {
	codec, err := NewTokenCodec(tokenSecret)
	if err != nil {
		return nil, err
	}
	return &MemoryStore{
		serverInstanceID: serverInstanceID, codec: codec, quota: quota,
		spaces: make(map[uuid.UUID]*memorySpace), idempotentSpaces: make(map[string]map[uuid.UUID]uuid.UUID),
		revokedCredentials: make(map[string]struct{}), now: time.Now,
	}, nil
}

func (s *MemoryStore) Readiness(context.Context) error { return nil }

func (s *MemoryStore) IsAccessTokenRevoked(_ context.Context, principal Principal) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, revoked := s.revokedCredentials[digestKey(principal.CredentialDigest)]
	return revoked, nil
}

func (s *MemoryStore) RevokeAccessToken(_ context.Context, principal Principal) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.revokedCredentials[digestKey(principal.CredentialDigest)] = struct{}{}
	return nil
}

func (s *MemoryStore) ListSpaces(_ context.Context, principal Principal) ([]Space, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.requireCredentialActive(principal); err != nil {
		return nil, err
	}
	identity := digestKey(principal.IdentityDigest)
	result := make([]Space, 0)
	for id, state := range s.spaces {
		if membership, ok := state.memberships[identity]; ok {
			result = append(result, descriptor(id, state, membership))
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Scope.SpaceID.String() < result[j].Scope.SpaceID.String() })
	return result, nil
}

func (s *MemoryStore) CreateSpace(_ context.Context, principal Principal, idempotencyKey *uuid.UUID) (Space, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.requireCredentialActive(principal); err != nil {
		return Space{}, err
	}
	identity := digestKey(principal.IdentityDigest)
	if idempotencyKey != nil {
		if spaceID, ok := s.idempotentSpaces[identity][*idempotencyKey]; ok {
			state := s.spaces[spaceID]
			return descriptor(spaceID, state, state.memberships[identity]), nil
		}
	}
	owned := 0
	for _, state := range s.spaces {
		if membership, ok := state.memberships[identity]; ok && membership.role == Owner {
			owned++
		}
	}
	if owned >= MaxSpacesPerUser {
		return Space{}, ErrorWithLimit(QuotaExceeded, MaxSpacesPerUser)
	}
	spaceID := uuid.New()
	membership := memoryMembership{role: Owner, scopeBinding: randomScopeBinding()}
	state := &memorySpace{
		ownerIdentity: identity, datasetGeneration: uuid.New(), feedEpoch: uuid.New(), keyEpoch: 1,
		memberships: map[string]memoryMembership{identity: membership}, records: make(map[uuid.UUID]memoryRecord), pairings: make(map[uuid.UUID]memoryPairing),
	}
	s.spaces[spaceID] = state
	if idempotencyKey != nil {
		if s.idempotentSpaces[identity] == nil {
			s.idempotentSpaces[identity] = make(map[uuid.UUID]uuid.UUID)
		}
		s.idempotentSpaces[identity][*idempotencyKey] = spaceID
	}
	return descriptor(spaceID, state, membership), nil
}

func (s *MemoryStore) GetSpace(_ context.Context, principal Principal, spaceID uuid.UUID) (Space, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, membership, err := s.authorized(principal, spaceID)
	if err != nil {
		return Space{}, err
	}
	return descriptor(spaceID, state, membership), nil
}

func (s *MemoryStore) FetchChanges(_ context.Context, principal Principal, spaceID uuid.UUID, cursor *string, limit int) (ChangesPage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if limit < 1 || limit > MaxPageRecords {
		return ChangesPage{}, NewError(InvalidRequest)
	}
	state, membership, err := s.authorized(principal, spaceID)
	if err != nil {
		return ChangesPage{}, err
	}
	scope := descriptor(spaceID, state, membership).Scope
	if cursor == nil {
		return s.snapshotPage(state, scope, nil, state.nextSequence, limit)
	}
	var payload CursorPayload
	if err := s.codec.Decode(*cursor, &payload); err != nil {
		return ChangesPage{}, err
	}
	if payload.Version != 2 || payload.ServerInstanceID != s.serverInstanceID || payload.SpaceID != spaceID {
		return ChangesPage{}, NewError(CursorInvalid)
	}
	if payload.DatasetGeneration != state.datasetGeneration {
		return ChangesPage{}, NewError(DatasetReset)
	}
	if payload.FeedEpoch != state.feedEpoch {
		return ChangesPage{}, NewError(CursorInvalid)
	}
	if payload.Kind == SnapshotCursor {
		return s.snapshotPage(state, scope, payload.SnapshotAfterID, payload.SnapshotHighWater, limit)
	}
	if payload.Kind != DeltaCursor || payload.Sequence < 0 {
		return ChangesPage{}, NewError(CursorInvalid)
	}
	available := make([]memoryChange, 0)
	for _, change := range state.changes {
		if change.sequence > payload.Sequence {
			available = append(available, change)
		}
	}
	selected := available
	if len(selected) > limit {
		selected = selected[:limit]
	}
	sequence := payload.Sequence
	records := make([]ServerRecord, 0, len(selected))
	for _, change := range selected {
		sequence = change.sequence
		record, err := s.serverRecord(spaceID, state, memoryRecord{record: change.record, generation: change.generation})
		if err != nil {
			return ChangesPage{}, err
		}
		records = append(records, record)
	}
	next, err := s.codec.Encode(CursorPayload{Version: 2, Kind: DeltaCursor, ServerInstanceID: s.serverInstanceID, SpaceID: spaceID, DatasetGeneration: state.datasetGeneration, FeedEpoch: state.feedEpoch, Sequence: sequence})
	if err != nil {
		return ChangesPage{}, err
	}
	return ChangesPage{Scope: scope, Records: records, Cursor: next, HasMore: len(available) > len(selected), FullSnapshot: false}, nil
}

func (s *MemoryStore) Submit(_ context.Context, principal Principal, spaceID uuid.UUID, items []BatchItem) (BatchSubmission, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(items) == 0 || len(items) > MaxBatchRecords {
		return BatchSubmission{}, NewError(InvalidRequest)
	}
	seen := make(map[uuid.UUID]struct{}, len(items))
	for _, item := range items {
		if _, ok := seen[item.Record.ID]; ok {
			return BatchSubmission{}, NewError(InvalidRequest)
		}
		seen[item.Record.ID] = struct{}{}
	}
	state, membership, err := s.authorized(principal, spaceID)
	if err != nil {
		return BatchSubmission{}, err
	}
	if !membership.role.CanWrite() {
		return BatchSubmission{}, NewError(Forbidden)
	}
	type indexed struct {
		index int
		item  BatchItem
	}
	ordered := make([]indexed, len(items))
	for i, item := range items {
		ordered[i] = indexed{i, item}
	}
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].item.Record.ID.String() < ordered[j].item.Record.ID.String() })
	outcomes := make([]BatchOutcome, len(items))
	for _, value := range ordered {
		item := value.item
		if err := item.Record.Validate(); err != nil {
			code := AsServiceError(err).Code
			outcomes[value.index] = BatchOutcome{Kind: "rejected", ErrorCode: &code}
			continue
		}
		if item.ExpectedRecordVersion != nil && (len(*item.ExpectedRecordVersion) < 32 || len(*item.ExpectedRecordVersion) > 2048) {
			code := InvalidRequest
			outcomes[value.index] = BatchOutcome{Kind: "rejected", ErrorCode: &code}
			continue
		}
		current, exists := state.records[item.Record.ID]
		matches := !exists && item.ExpectedRecordVersion == nil
		if exists && item.ExpectedRecordVersion != nil {
			currentServer, encodeErr := s.serverRecord(spaceID, state, current)
			if encodeErr != nil {
				return BatchSubmission{}, encodeErr
			}
			matches = currentServer.RecordVersion == *item.ExpectedRecordVersion
		}
		if !matches {
			var authoritative *ServerRecord
			if exists {
				value, encodeErr := s.serverRecord(spaceID, state, current)
				if encodeErr != nil {
					return BatchSubmission{}, encodeErr
				}
				authoritative = &value
			}
			outcomes[value.index] = BatchOutcome{Kind: "conflict", AuthoritativeRecord: authoritative}
			continue
		}
		generation := current.generation + 1
		newStored := memoryRecord{record: cloneWireRecord(item.Record), generation: generation}
		if !s.withinQuota(spaceID, state, item.Record.ID, newStored) {
			code := QuotaExceeded
			outcomes[value.index] = BatchOutcome{Kind: "rejected", ErrorCode: &code}
			continue
		}
		state.nextSequence++
		state.records[item.Record.ID] = newStored
		state.changes = append(state.changes, memoryChange{sequence: state.nextSequence, record: cloneWireRecord(item.Record), generation: generation})
		serverRecord, encodeErr := s.serverRecord(spaceID, state, newStored)
		if encodeErr != nil {
			return BatchSubmission{}, encodeErr
		}
		version, revision := serverRecord.RecordVersion, item.Record.Rev
		outcomes[value.index] = BatchOutcome{Kind: "accepted", RecordVersion: &version, Revision: &revision}
	}
	partial := false
	for _, outcome := range outcomes {
		if outcome.Kind != "accepted" {
			partial = true
			break
		}
	}
	return BatchSubmission{Scope: descriptor(spaceID, state, membership).Scope, Outcomes: outcomes, Partial: partial}, nil
}

func (s *MemoryStore) GetRecoveryEnvelope(_ context.Context, principal Principal, spaceID uuid.UUID) (Space, *RecoveryEnvelope, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, membership, err := s.authorized(principal, spaceID)
	if err != nil {
		return Space{}, nil, err
	}
	var envelope *RecoveryEnvelope
	if state.recovery != nil {
		copy := *state.recovery
		copy.Ciphertext = append([]byte(nil), copy.Ciphertext...)
		envelope = &copy
	}
	return descriptor(spaceID, state, membership), envelope, nil
}

func (s *MemoryStore) PutRecoveryEnvelope(_ context.Context, principal Principal, spaceID uuid.UUID, request PutRecoveryEnvelope) (Space, RecoveryEnvelope, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := request.Validate(); err != nil {
		return Space{}, RecoveryEnvelope{}, err
	}
	state, membership, err := s.authorized(principal, spaceID)
	if err != nil {
		return Space{}, RecoveryEnvelope{}, err
	}
	if membership.role != Owner {
		return Space{}, RecoveryEnvelope{}, NewError(Forbidden)
	}
	if request.KeyEpoch != state.keyEpoch {
		return Space{}, RecoveryEnvelope{}, NewError(Conflict)
	}
	current := 0
	if state.recovery != nil {
		current = state.recovery.Version
	}
	if (request.ExpectedVersion == nil && current != 0) || (request.ExpectedVersion != nil && *request.ExpectedVersion != current) {
		return Space{}, RecoveryEnvelope{}, NewError(Conflict)
	}
	envelope := RecoveryEnvelope{Version: current + 1, KeyEpoch: request.KeyEpoch, Algorithm: request.Algorithm, Ciphertext: append([]byte(nil), request.Ciphertext...), CreatedAt: s.now().UTC()}
	state.recovery = &envelope
	return descriptor(spaceID, state, membership), envelope, nil
}

func (s *MemoryStore) CreatePairing(_ context.Context, principal Principal, spaceID uuid.UUID, request CreatePairing) (Space, Pairing, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := request.Validate(); err != nil {
		return Space{}, Pairing{}, err
	}
	state, membership, err := s.authorized(principal, spaceID)
	if err != nil {
		return Space{}, Pairing{}, err
	}
	if !membership.role.CanWrite() {
		return Space{}, Pairing{}, NewError(Forbidden)
	}
	now := s.now()
	for id, pairing := range state.pairings {
		if !pairing.value.ExpiresAt.After(now) {
			delete(state.pairings, id)
		}
	}
	if len(state.pairings) >= MaxPairingsPerSpace {
		return Space{}, Pairing{}, ErrorWithRetry(RateLimited, 60)
	}
	hash := sha256.Sum256(request.RecipientPublicKey)
	pairing := Pairing{ID: uuid.New(), SpaceID: spaceID, RecipientPublicKey: append([]byte(nil), request.RecipientPublicKey...), Nonce: append([]byte(nil), request.Nonce...), AuthenticationTag: pairingAuthenticationTag(request.Nonce, request.RecipientPublicKey), State: PairingPending, ExpiresAt: now.Add(time.Duration(request.ExpiresInSeconds) * time.Second).UTC()}
	state.pairings[pairing.ID] = memoryPairing{value: pairing, recipientKeyHash: hash}
	return descriptor(spaceID, state, membership), pairing, nil
}

func (s *MemoryStore) ApprovePairing(_ context.Context, principal Principal, spaceID, pairingID uuid.UUID, request ApprovePairing) (Space, Pairing, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := request.Validate(); err != nil {
		return Space{}, Pairing{}, err
	}
	state, membership, err := s.authorized(principal, spaceID)
	if err != nil {
		return Space{}, Pairing{}, err
	}
	if !membership.role.CanWrite() {
		return Space{}, Pairing{}, NewError(Forbidden)
	}
	stored, ok := state.pairings[pairingID]
	if !ok {
		return Space{}, Pairing{}, NewError(NotFound)
	}
	if !stored.value.ExpiresAt.After(s.now()) {
		return Space{}, Pairing{}, NewError(PairingExpired)
	}
	if stored.value.State != PairingPending || !ConstantTimeEqual(request.RecipientKeyHash, stored.recipientKeyHash[:]) {
		return Space{}, Pairing{}, NewError(Conflict)
	}
	algorithm := request.Algorithm
	stored.value.State, stored.value.Algorithm, stored.value.Ciphertext = PairingApproved, &algorithm, append([]byte(nil), request.Ciphertext...)
	state.pairings[pairingID] = stored
	return descriptor(spaceID, state, membership), stored.value, nil
}

func (s *MemoryStore) GetPairing(_ context.Context, principal Principal, spaceID, pairingID uuid.UUID) (Space, Pairing, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, membership, err := s.authorized(principal, spaceID)
	if err != nil {
		return Space{}, Pairing{}, err
	}
	stored, ok := state.pairings[pairingID]
	if !ok {
		return Space{}, Pairing{}, NewError(NotFound)
	}
	if !stored.value.ExpiresAt.After(s.now()) {
		return Space{}, Pairing{}, NewError(PairingExpired)
	}
	redacted := stored.value
	redacted.Ciphertext = nil
	return descriptor(spaceID, state, membership), redacted, nil
}

func (s *MemoryStore) ClaimPairing(_ context.Context, principal Principal, spaceID, pairingID uuid.UUID) (Space, Pairing, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, membership, err := s.authorized(principal, spaceID)
	if err != nil {
		return Space{}, Pairing{}, err
	}
	stored, ok := state.pairings[pairingID]
	if !ok {
		return Space{}, Pairing{}, NewError(NotFound)
	}
	if !stored.value.ExpiresAt.After(s.now()) {
		return Space{}, Pairing{}, NewError(PairingExpired)
	}
	if stored.value.State != PairingApproved {
		return Space{}, Pairing{}, NewError(Conflict)
	}
	delete(state.pairings, pairingID)
	return descriptor(spaceID, state, membership), stored.value, nil
}

func (s *MemoryStore) CancelPairing(_ context.Context, principal Principal, spaceID, pairingID uuid.UUID) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, _, err := s.authorized(principal, spaceID)
	if err != nil {
		return err
	}
	delete(state.pairings, pairingID)
	return nil
}

func (s *MemoryStore) RotateDataset(spaceID uuid.UUID) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, ok := s.spaces[spaceID]
	if !ok {
		return NewError(NotFound)
	}
	state.datasetGeneration, state.feedEpoch, state.nextSequence, state.changes = uuid.New(), uuid.New(), 0, nil
	return nil
}

func (s *MemoryStore) RotateFeedEpoch(spaceID uuid.UUID) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, ok := s.spaces[spaceID]
	if !ok {
		return NewError(NotFound)
	}
	state.feedEpoch, state.nextSequence, state.changes = uuid.New(), 0, nil
	return nil
}

func (s *MemoryStore) snapshotPage(state *memorySpace, scope Scope, after *uuid.UUID, highWater int64, limit int) (ChangesPage, error) {
	stored := make([]memoryRecord, 0, len(state.records))
	for _, value := range state.records {
		if after == nil || value.record.ID.String() > after.String() {
			stored = append(stored, value)
		}
	}
	sort.Slice(stored, func(i, j int) bool { return stored[i].record.ID.String() < stored[j].record.ID.String() })
	availableCount := len(stored)
	if len(stored) > limit {
		stored = stored[:limit]
	}
	records := make([]ServerRecord, 0, len(stored))
	for _, value := range stored {
		record, err := s.serverRecord(scope.SpaceID, state, value)
		if err != nil {
			return ChangesPage{}, err
		}
		records = append(records, record)
	}
	payload := CursorPayload{Version: 2, Kind: DeltaCursor, ServerInstanceID: s.serverInstanceID, SpaceID: scope.SpaceID, DatasetGeneration: scope.DatasetGeneration, FeedEpoch: scope.FeedEpoch, Sequence: highWater}
	hasMore := availableCount > len(stored)
	if hasMore {
		last := records[len(records)-1].Record.ID
		payload.Kind, payload.Sequence, payload.SnapshotAfterID, payload.SnapshotHighWater = SnapshotCursor, 0, &last, highWater
	}
	cursor, err := s.codec.Encode(payload)
	if err != nil {
		return ChangesPage{}, err
	}
	return ChangesPage{Scope: scope, Records: records, Cursor: cursor, HasMore: hasMore, FullSnapshot: true}, nil
}

func (s *MemoryStore) serverRecord(spaceID uuid.UUID, state *memorySpace, stored memoryRecord) (ServerRecord, error) {
	version, err := s.codec.Encode(RecordVersionPayload{Version: 2, ServerInstanceID: s.serverInstanceID, SpaceID: spaceID, DatasetGeneration: state.datasetGeneration, RecordID: stored.record.ID, Generation: stored.generation})
	return ServerRecord{Record: cloneWireRecord(stored.record), RecordVersion: version}, err
}

func (s *MemoryStore) authorized(principal Principal, spaceID uuid.UUID) (*memorySpace, memoryMembership, error) {
	if err := s.requireCredentialActive(principal); err != nil {
		return nil, memoryMembership{}, err
	}
	state, ok := s.spaces[spaceID]
	if !ok {
		return nil, memoryMembership{}, NewError(NotFound)
	}
	membership, ok := state.memberships[digestKey(principal.IdentityDigest)]
	if !ok {
		return nil, memoryMembership{}, NewError(NotFound)
	}
	return state, membership, nil
}

func (s *MemoryStore) requireCredentialActive(principal Principal) error {
	if !principal.ExpiresAt.After(s.now()) {
		return NewError(AuthenticationRequired)
	}
	if _, revoked := s.revokedCredentials[digestKey(principal.CredentialDigest)]; revoked {
		return NewError(AuthenticationRequired)
	}
	return nil
}

func (s *MemoryStore) withinQuota(spaceID uuid.UUID, state *memorySpace, recordID uuid.UUID, replacement memoryRecord) bool {
	old, existed := state.records[recordID]
	spaceBytes := s.spaceBytes(state) - recordBytes(old) + recordBytes(replacement)*2
	if !existed {
		spaceBytes = s.spaceBytes(state) + recordBytes(replacement)*2
	}
	if spaceBytes > s.quota.MaxBytesPerSpace || int64(len(state.records))+boolInt(!existed) > s.quota.MaxRecordsPerSpace || int64(len(state.changes))+1 > s.quota.MaxChangesPerSpace {
		return false
	}
	var userBytes int64
	for id, candidate := range s.spaces {
		if candidate.ownerIdentity == state.ownerIdentity {
			if id == spaceID {
				userBytes += spaceBytes
			} else {
				userBytes += s.spaceBytes(candidate)
			}
		}
	}
	return userBytes <= s.quota.MaxBytesPerUser
}

func (s *MemoryStore) spaceBytes(state *memorySpace) int64 {
	var total int64
	for _, record := range state.records {
		total += recordBytes(record)
	}
	for _, change := range state.changes {
		total += recordBytes(memoryRecord{record: change.record, generation: change.generation})
	}
	return total
}

func recordBytes(record memoryRecord) int64 {
	return int64(len(record.record.Blob) + len([]byte(record.record.Rev)))
}
func boolInt(value bool) int64 {
	if value {
		return 1
	}
	return 0
}
func digestKey(value [32]byte) string { return hex.EncodeToString(value[:]) }
func cloneWireRecord(value WireRecord) WireRecord {
	value.Blob = append([]byte(nil), value.Blob...)
	return value
}

func descriptor(spaceID uuid.UUID, state *memorySpace, membership memoryMembership) Space {
	return Space{Scope: Scope{SpaceID: spaceID, ScopeBinding: membership.scopeBinding, DatasetGeneration: state.datasetGeneration, FeedEpoch: state.feedEpoch}, Role: membership.role, KeyEpoch: state.keyEpoch}
}

func randomScopeBinding() string {
	value := make([]byte, 32)
	if _, err := rand.Read(value); err != nil {
		panic("operating system random source unavailable")
	}
	return base64.RawURLEncoding.EncodeToString(value)
}

func pairingAuthenticationTag(nonce, publicKey []byte) string {
	material := append([]byte("snippets-pairing-confirm-v1"), nonce...)
	material = append(material, publicKey...)
	digest := sha256.Sum256(material)
	alphabet := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	result := make([]byte, 8)
	for i := range result {
		result[i] = alphabet[int(digest[i])&31]
	}
	return string(result)
}
