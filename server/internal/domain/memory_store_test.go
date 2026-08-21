package domain

import (
	"context"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestTokenCodecRoundTripAndTamper(t *testing.T) {
	codec, err := NewTokenCodec(bytesOf(7, 32))
	if err != nil {
		t.Fatal(err)
	}
	payload := CursorPayload{Version: 2, Kind: DeltaCursor, ServerInstanceID: uuid.New(), SpaceID: uuid.New(), DatasetGeneration: uuid.New(), FeedEpoch: uuid.New(), Sequence: 42}
	token, err := codec.Encode(payload)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(token, "v2.") {
		t.Fatalf("wrong prefix: %s", token)
	}
	var decoded CursorPayload
	if err := codec.Decode(token, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded != payload {
		t.Fatalf("roundtrip mismatch: %#v", decoded)
	}
	replacement := "A"
	if strings.HasSuffix(token, replacement) {
		replacement = "B"
	}
	tampered := token[:len(token)-1] + replacement
	if err := codec.Decode(tampered, &decoded); AsServiceError(err).Code != CursorInvalid {
		t.Fatalf("tamper accepted: %v", err)
	}
}

func TestTokenCodecRejectsWrongSecretAndNonCanonicalEncoding(t *testing.T) {
	first, _ := NewTokenCodec(bytesOf(1, 32))
	second, _ := NewTokenCodec(bytesOf(2, 32))
	token, _ := first.Encode(RecordVersionPayload{Version: 2, ServerInstanceID: uuid.New(), SpaceID: uuid.New(), DatasetGeneration: uuid.New(), RecordID: uuid.New(), Generation: 1})
	var value RecordVersionPayload
	if err := second.Decode(token, &value); AsServiceError(err).Code != CursorInvalid {
		t.Fatalf("wrong secret accepted")
	}
	parts := strings.Split(token, ".")
	parts[1] += "="
	if err := first.Decode(strings.Join(parts, "."), &value); AsServiceError(err).Code != CursorInvalid {
		t.Fatalf("padded token accepted")
	}
}

func TestSpaceCreationIsIdempotentAndTenantIsolated(t *testing.T) {
	store := newTestStore(t, ProductionQuota)
	first, second := principal(1), principal(2)
	key := uuid.New()
	a, err := store.CreateSpace(context.Background(), first, &key)
	if err != nil {
		t.Fatal(err)
	}
	replay, err := store.CreateSpace(context.Background(), first, &key)
	if err != nil {
		t.Fatal(err)
	}
	if replay.Scope.SpaceID != a.Scope.SpaceID {
		t.Fatal("idempotency replay created a new space")
	}
	if _, err := store.GetSpace(context.Background(), second, a.Scope.SpaceID); AsServiceError(err).Code != NotFound {
		t.Fatalf("cross-tenant lookup leaked: %v", err)
	}
	spaces, err := store.ListSpaces(context.Background(), first)
	if err != nil || len(spaces) != 1 {
		t.Fatalf("list mismatch: %v %#v", err, spaces)
	}
}

func TestBatchCASPositionalOutcomesAndHistory(t *testing.T) {
	store := newTestStore(t, ProductionQuota)
	owner := principal(1)
	space, _ := store.CreateSpace(context.Background(), owner, nil)
	initial, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, nil, 50)
	if err != nil {
		t.Fatal(err)
	}
	id := uuid.New()
	first := WireRecord{ID: id, Rev: "1-a", Blob: []byte("one")}
	submission, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, []BatchItem{{Record: first}})
	if err != nil {
		t.Fatal(err)
	}
	if submission.Partial || submission.Outcomes[0].Kind != "accepted" {
		t.Fatalf("unexpected first outcome: %#v", submission)
	}
	version := *submission.Outcomes[0].RecordVersion
	wrong := "v2.this.is-not-a-valid-token-but-is-long-enough"
	second := WireRecord{ID: id, Rev: "2-a", Blob: []byte("two")}
	additional := WireRecord{ID: uuid.New(), Rev: "1-b", Blob: []byte("other")}
	submission, err = store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, []BatchItem{{Record: second, ExpectedRecordVersion: &wrong}, {Record: additional}})
	if err != nil {
		t.Fatal(err)
	}
	if submission.Outcomes[0].Kind != "conflict" || submission.Outcomes[1].Kind != "accepted" || !submission.Partial {
		t.Fatalf("positional outcomes lost: %#v", submission.Outcomes)
	}
	if _, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, []BatchItem{{Record: second, ExpectedRecordVersion: &version}}); err != nil {
		t.Fatal(err)
	}
	page, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, &initial.Cursor, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Records) != 3 || page.Records[0].Record.Rev != "1-a" || page.Records[2].Record.Rev != "2-a" {
		t.Fatalf("change history collapsed: %#v", page.Records)
	}
}

func TestBatchRejectsDuplicatesAndInvalidRecords(t *testing.T) {
	store := newTestStore(t, ProductionQuota)
	owner := principal(1)
	space, _ := store.CreateSpace(context.Background(), owner, nil)
	id := uuid.New()
	item := BatchItem{Record: WireRecord{ID: id, Rev: "ok"}}
	if _, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, []BatchItem{item, item}); AsServiceError(err).Code != InvalidRequest {
		t.Fatalf("duplicate accepted: %v", err)
	}
	invalid := BatchItem{Record: WireRecord{ID: uuid.New(), Rev: strings.Repeat("x", 257)}}
	result, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, []BatchItem{invalid})
	if err != nil || result.Outcomes[0].Kind != "rejected" || *result.Outcomes[0].ErrorCode != InvalidRequest {
		t.Fatalf("invalid outcome: %v %#v", err, result)
	}
}

func TestReaderCannotSubmitOrCancelPairing(t *testing.T) {
	store := newTestStore(t, ProductionQuota)
	owner, reader := principal(1), principal(2)
	space, err := store.CreateSpace(context.Background(), owner, nil)
	if err != nil {
		t.Fatal(err)
	}
	store.mu.Lock()
	store.spaces[space.Scope.SpaceID].memberships[digestKey(reader.IdentityDigest)] = memoryMembership{role: Reader, scopeBinding: randomScopeBinding()}
	store.mu.Unlock()
	readerSpace, err := store.GetSpace(context.Background(), reader, space.Scope.SpaceID)
	if err != nil {
		t.Fatal(err)
	}
	_, err = store.Submit(context.Background(), reader, space.Scope.SpaceID, readerSpace.Scope, []BatchItem{{Record: WireRecord{ID: uuid.New(), Rev: "1"}}})
	if AsServiceError(err).Code != Forbidden {
		t.Fatalf("reader submit returned %v", err)
	}
	if err := store.CancelPairing(context.Background(), reader, space.Scope.SpaceID, uuid.New()); AsServiceError(err).Code != Forbidden {
		t.Fatalf("reader pairing cancellation returned %v", err)
	}
}

func TestSnapshotPaginationThenDelta(t *testing.T) {
	store := newTestStore(t, ProductionQuota)
	owner := principal(1)
	space, _ := store.CreateSpace(context.Background(), owner, nil)
	ids := []uuid.UUID{uuid.MustParse("00000000-0000-0000-0000-000000000001"), uuid.MustParse("00000000-0000-0000-0000-000000000002"), uuid.MustParse("00000000-0000-0000-0000-000000000003")}
	items := make([]BatchItem, 3)
	for i, id := range ids {
		items[i] = BatchItem{Record: WireRecord{ID: id, Rev: "1", Blob: []byte{byte(i)}}}
	}
	if _, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, items); err != nil {
		t.Fatal(err)
	}
	first, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, nil, 2)
	if err != nil {
		t.Fatal(err)
	}
	if !first.FullSnapshot || !first.HasMore || len(first.Records) != 2 {
		t.Fatalf("first snapshot page: %#v", first)
	}
	second, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, &first.Cursor, 2)
	if err != nil {
		t.Fatal(err)
	}
	if !second.FullSnapshot || second.HasMore || len(second.Records) != 1 {
		t.Fatalf("second snapshot page: %#v", second)
	}
	newRecord := WireRecord{ID: uuid.New(), Rev: "1", Blob: []byte("new")}
	if _, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, []BatchItem{{Record: newRecord}}); err != nil {
		t.Fatal(err)
	}
	delta, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, &second.Cursor, 50)
	if err != nil || delta.FullSnapshot || len(delta.Records) != 1 || delta.Records[0].Record.ID != newRecord.ID {
		t.Fatalf("delta mismatch: %v %#v", err, delta)
	}
}

func TestSnapshotPaginationIsStableAcrossInterleavedWrites(t *testing.T) {
	store := newTestStore(t, ProductionQuota)
	owner := principal(1)
	space, err := store.CreateSpace(context.Background(), owner, nil)
	if err != nil {
		t.Fatal(err)
	}
	ids := []uuid.UUID{
		uuid.MustParse("00000000-0000-0000-0000-000000000001"),
		uuid.MustParse("00000000-0000-0000-0000-000000000002"),
		uuid.MustParse("00000000-0000-0000-0000-000000000003"),
		uuid.MustParse("00000000-0000-0000-0000-000000000004"),
		uuid.MustParse("00000000-0000-0000-0000-000000000005"),
	}
	items := make([]BatchItem, 4)
	for index := range items {
		items[index] = BatchItem{Record: WireRecord{ID: ids[index], Rev: "1", Blob: []byte{byte(index)}}}
	}
	created, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, items)
	if err != nil {
		t.Fatal(err)
	}

	first, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, nil, 2)
	if err != nil || !first.HasMore || len(first.Records) != 2 {
		t.Fatalf("first snapshot page: %v %#v", err, first)
	}
	updateVersion := *created.Outcomes[2].RecordVersion
	deleteVersion := *created.Outcomes[3].RecordVersion
	mutations := []BatchItem{
		{Record: WireRecord{ID: ids[2], Rev: "2", Blob: []byte("updated")}, ExpectedRecordVersion: &updateVersion},
		{Record: WireRecord{ID: ids[3], Rev: "2", Deleted: true}, ExpectedRecordVersion: &deleteVersion},
		{Record: WireRecord{ID: ids[4], Rev: "1", Blob: []byte("new")}},
	}
	if _, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, mutations); err != nil {
		t.Fatal(err)
	}

	second, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, &first.Cursor, 2)
	if err != nil || second.HasMore || len(second.Records) != 2 {
		t.Fatalf("second snapshot page: %v %#v", err, second)
	}
	if second.Records[0].Record.ID != ids[2] || second.Records[0].Record.Rev != "1" ||
		second.Records[1].Record.ID != ids[3] || second.Records[1].Record.Rev != "1" || second.Records[1].Record.Deleted {
		t.Fatalf("snapshot crossed its watermark: %#v", second.Records)
	}

	delta, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, &second.Cursor, 50)
	if err != nil || delta.FullSnapshot || len(delta.Records) != 3 {
		t.Fatalf("delta after snapshot: %v %#v", err, delta)
	}
	if delta.Records[0].Record.ID != ids[2] || delta.Records[0].Record.Rev != "2" ||
		delta.Records[1].Record.ID != ids[3] || !delta.Records[1].Record.Deleted ||
		delta.Records[2].Record.ID != ids[4] {
		t.Fatalf("interleaved writes were not preserved in delta order: %#v", delta.Records)
	}
}

func TestChangeHistoryCompactionRotatesFeedBeforeQuotaExhaustion(t *testing.T) {
	quota := StorageQuota{MaxBytesPerSpace: 10_000, MaxBytesPerUser: 100_000, MaxRecordsPerSpace: 100, MaxChangesPerSpace: 5}
	store := newTestStore(t, quota)
	owner := principal(1)
	space, err := store.CreateSpace(context.Background(), owner, nil)
	if err != nil {
		t.Fatal(err)
	}
	recordID := uuid.New()
	created, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, []BatchItem{{Record: WireRecord{ID: recordID, Rev: "1", Blob: []byte("value")}}})
	if err != nil {
		t.Fatal(err)
	}
	version := *created.Outcomes[0].RecordVersion
	oldFeedPage, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, nil, 50)
	if err != nil {
		t.Fatal(err)
	}
	compacted := false
	for revision := 2; revision <= 20; revision++ {
		item := BatchItem{Record: WireRecord{ID: recordID, Rev: string(rune('a' + revision)), Blob: []byte("value")}, ExpectedRecordVersion: &version}
		result, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, []BatchItem{item})
		if AsServiceError(err).Code == CursorInvalid {
			compacted = true
			space, err = store.GetSpace(context.Background(), owner, space.Scope.SpaceID)
			if err != nil {
				t.Fatal(err)
			}
			result, err = store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, []BatchItem{item})
		}
		if err != nil || result.Outcomes[0].Kind != "accepted" {
			t.Fatalf("revision %d was not accepted after maintenance: %v %#v", revision, err, result)
		}
		version = *result.Outcomes[0].RecordVersion
	}
	if !compacted {
		t.Fatal("history never compacted")
	}
	if _, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, &oldFeedPage.Cursor, 50); AsServiceError(err).Code != CursorInvalid {
		t.Fatalf("old feed cursor survived compaction: %v", err)
	}
	store.mu.Lock()
	changeCount := len(store.spaces[space.Scope.SpaceID].changes)
	store.mu.Unlock()
	if changeCount > int(quota.MaxChangesPerSpace) {
		t.Fatalf("compacted history exceeded quota: %d", changeCount)
	}
}

func TestRestoreInvalidatesDatasetAndFeedCursors(t *testing.T) {
	store := newTestStore(t, ProductionQuota)
	owner := principal(1)
	space, _ := store.CreateSpace(context.Background(), owner, nil)
	page, _ := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, nil, 50)
	if err := store.RotateDataset(space.Scope.SpaceID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, &page.Cursor, 50); AsServiceError(err).Code != DatasetReset {
		t.Fatalf("restore cursor result: %v", err)
	}
	fresh, _ := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, nil, 50)
	if err := store.RotateFeedEpoch(space.Scope.SpaceID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, &fresh.Cursor, 50); AsServiceError(err).Code != CursorInvalid {
		t.Fatalf("feed cursor result: %v", err)
	}
}

func TestBatchRejectsStaleScopeBeforeCreatingRecords(t *testing.T) {
	store := newTestStore(t, ProductionQuota)
	owner := principal(1)
	space, _ := store.CreateSpace(context.Background(), owner, nil)

	if err := store.RotateDataset(space.Scope.SpaceID); err != nil {
		t.Fatal(err)
	}
	staleDatasetRecord := WireRecord{ID: uuid.New(), Rev: "dataset", Blob: []byte("opaque")}
	if _, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, []BatchItem{{Record: staleDatasetRecord}}); AsServiceError(err).Code != DatasetReset {
		t.Fatalf("stale dataset scope was accepted: %v", err)
	}

	current, err := store.GetSpace(context.Background(), owner, space.Scope.SpaceID)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.RotateFeedEpoch(space.Scope.SpaceID); err != nil {
		t.Fatal(err)
	}
	staleFeedRecord := WireRecord{ID: uuid.New(), Rev: "feed", Blob: []byte("opaque")}
	if _, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, current.Scope, []BatchItem{{Record: staleFeedRecord}}); AsServiceError(err).Code != CursorInvalid {
		t.Fatalf("stale feed scope was accepted: %v", err)
	}

	page, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, nil, 50)
	if err != nil || len(page.Records) != 0 {
		t.Fatalf("stale writes mutated records: %v %#v", err, page.Records)
	}
}

func TestRecoveryEnvelopeCAS(t *testing.T) {
	store := newTestStore(t, ProductionQuota)
	owner := principal(1)
	space, _ := store.CreateSpace(context.Background(), owner, nil)
	descriptor, current, err := store.GetRecoveryEnvelope(context.Background(), owner, space.Scope.SpaceID)
	if err != nil || current != nil || descriptor.KeyEpoch != 1 {
		t.Fatalf("initial envelope: %v %#v", err, current)
	}
	request := PutRecoveryEnvelope{KeyEpoch: 1, Algorithm: RecoveryAlgorithm, Ciphertext: []byte("opaque")}
	_, saved, err := store.PutRecoveryEnvelope(context.Background(), owner, space.Scope.SpaceID, request)
	if err != nil || saved.Version != 1 {
		t.Fatalf("save: %v %#v", err, saved)
	}
	if _, _, err := store.PutRecoveryEnvelope(context.Background(), owner, space.Scope.SpaceID, request); AsServiceError(err).Code != Conflict {
		t.Fatalf("missing CAS conflict: %v", err)
	}
	expected := 1
	request.ExpectedVersion = &expected
	_, saved, err = store.PutRecoveryEnvelope(context.Background(), owner, space.Scope.SpaceID, request)
	if err != nil || saved.Version != 2 {
		t.Fatalf("update: %v %#v", err, saved)
	}
}

func TestPairingApprovalClaimAndIdempotentCancellation(t *testing.T) {
	store := newTestStore(t, ProductionQuota)
	owner := principal(1)
	space, _ := store.CreateSpace(context.Background(), owner, nil)
	_, x, y, err := elliptic.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicKey := elliptic.Marshal(elliptic.P256(), x, y)
	nonce := bytesOf(3, 32)
	_, pairing, err := store.CreatePairing(context.Background(), owner, space.Scope.SpaceID, CreatePairing{RecipientPublicKey: publicKey, Nonce: nonce, ExpiresInSeconds: 60})
	if err != nil {
		t.Fatal(err)
	}
	if len(pairing.AuthenticationTag) != 8 || pairing.State != PairingPending {
		t.Fatalf("bad pairing: %#v", pairing)
	}
	wrong := bytesOf(4, 32)
	if _, _, err := store.ApprovePairing(context.Background(), owner, space.Scope.SpaceID, pairing.ID, ApprovePairing{RecipientKeyHash: wrong, Algorithm: PairingAlgorithm, Ciphertext: []byte("sealed")}); AsServiceError(err).Code != Conflict {
		t.Fatalf("wrong key hash accepted: %v", err)
	}
	hash := sha256.Sum256(publicKey)
	_, approved, err := store.ApprovePairing(context.Background(), owner, space.Scope.SpaceID, pairing.ID, ApprovePairing{RecipientKeyHash: hash[:], Algorithm: PairingAlgorithm, Ciphertext: []byte("sealed")})
	if err != nil || approved.State != PairingApproved {
		t.Fatalf("approval: %v %#v", err, approved)
	}
	_, visible, err := store.GetPairing(context.Background(), owner, space.Scope.SpaceID, pairing.ID)
	if err != nil || visible.Ciphertext != nil {
		t.Fatalf("ciphertext leaked: %v %#v", err, visible)
	}
	_, claimed, err := store.ClaimPairing(context.Background(), owner, space.Scope.SpaceID, pairing.ID)
	if err != nil || string(claimed.Ciphertext) != "sealed" {
		t.Fatalf("claim: %v %#v", err, claimed)
	}
	if _, _, err := store.ClaimPairing(context.Background(), owner, space.Scope.SpaceID, pairing.ID); AsServiceError(err).Code != NotFound {
		t.Fatalf("second claim: %v", err)
	}
	if err := store.CancelPairing(context.Background(), owner, space.Scope.SpaceID, pairing.ID); err != nil {
		t.Fatalf("idempotent cancellation failed: %v", err)
	}
}

func TestLogoutIsLinearizedWithDataPlane(t *testing.T) {
	store := newTestStore(t, ProductionQuota)
	owner := principal(1)
	if _, err := store.CreateSpace(context.Background(), owner, nil); err != nil {
		t.Fatal(err)
	}
	if err := store.RevokeAccessToken(context.Background(), owner); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ListSpaces(context.Background(), owner); AsServiceError(err).Code != AuthenticationRequired {
		t.Fatalf("revoked credential admitted: %v", err)
	}
}

func TestStorageQuotaRejectsWithoutPartialMutation(t *testing.T) {
	quota := ProductionQuota
	quota.MaxBytesPerSpace = 1
	store := newTestStore(t, quota)
	owner := principal(1)
	space, _ := store.CreateSpace(context.Background(), owner, nil)
	result, err := store.Submit(context.Background(), owner, space.Scope.SpaceID, space.Scope, []BatchItem{{Record: WireRecord{ID: uuid.New(), Rev: "r", Blob: []byte("x")}}})
	if err != nil || result.Outcomes[0].Kind != "rejected" || *result.Outcomes[0].ErrorCode != QuotaExceeded {
		t.Fatalf("quota outcome: %v %#v", err, result)
	}
	page, err := store.FetchChanges(context.Background(), owner, space.Scope.SpaceID, nil, 50)
	if err != nil || len(page.Records) != 0 {
		t.Fatalf("quota mutated records: %v %#v", err, page)
	}
}

func newTestStore(t *testing.T, quota StorageQuota) *MemoryStore {
	t.Helper()
	store, err := NewMemoryStore(uuid.MustParse("10000000-0000-0000-0000-000000000001"), bytesOf(9, 32), quota)
	if err != nil {
		t.Fatal(err)
	}
	return store
}
func principal(seed byte) Principal {
	var identity, credential [32]byte
	for i := range identity {
		identity[i] = seed
		credential[i] = seed + 1
	}
	return Principal{IdentityDigest: identity, CredentialDigest: credential, ExpiresAt: time.Now().Add(time.Hour)}
}
func bytesOf(value byte, count int) []byte {
	result := make([]byte, count)
	for i := range result {
		result[i] = value
	}
	return result
}
