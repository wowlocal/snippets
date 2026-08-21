package postgres

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/domain"
)

func TestPostgresTenantCASRestoreAndLogout(t *testing.T) {
	if os.Getenv("SNIPPETS_INTEGRATION_TESTS") != "1" {
		t.Skip("set SNIPPETS_INTEGRATION_TESTS=1")
	}
	port, _ := strconv.Atoi(os.Getenv("DATABASE_PORT"))
	ctx := context.Background()
	pool, err := NewPool(ctx, config.Database{Host: os.Getenv("DATABASE_HOST"), Port: port, Name: os.Getenv("DATABASE_NAME"), RuntimeUser: os.Getenv("DATABASE_RUNTIME_USER"), RuntimePassword: os.Getenv("DATABASE_RUNTIME_PASSWORD"), TLSMode: os.Getenv("DATABASE_TLS_MODE"), StatementTimeout: 2 * time.Second, LockTimeout: 250 * time.Millisecond, MaxConnections: 8})
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	ownerPool, err := NewPool(ctx, config.Database{Host: os.Getenv("DATABASE_HOST"), Port: port, Name: os.Getenv("DATABASE_NAME"), RuntimeUser: os.Getenv("DATABASE_OWNER_USER"), RuntimePassword: os.Getenv("DATABASE_OWNER_PASSWORD"), TLSMode: os.Getenv("DATABASE_TLS_MODE"), MaxConnections: 2})
	if err != nil {
		t.Fatal(err)
	}
	defer ownerPool.Close()
	store, err := NewStore(pool, uuid.MustParse("00000000-0000-0000-0000-000000000001"), make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	first, second := integrationPrincipal(1), integrationPrincipal(2)
	space, err := store.CreateSpace(ctx, first, nil)
	if err != nil {
		t.Fatal(err)
	}
	binding, err := base64.RawURLEncoding.Strict().DecodeString(space.Scope.ScopeBinding)
	if err != nil || len(binding) != 32 {
		t.Fatalf("noncanonical scope binding: %q (%v)", space.Scope.ScopeBinding, err)
	}
	readBack, err := store.GetSpace(ctx, first, space.Scope.SpaceID)
	if err != nil || readBack.Scope.ScopeBinding != space.Scope.ScopeBinding {
		t.Fatalf("scope binding changed after read: %#v %v", readBack.Scope, err)
	}
	if _, err := store.GetSpace(ctx, second, space.Scope.SpaceID); domain.AsServiceError(err).Code != domain.NotFound {
		t.Fatalf("tenant isolation failed: %v", err)
	}
	id := uuid.New()
	created, err := store.Submit(ctx, first, space.Scope.SpaceID, space.Scope, []domain.BatchItem{{Record: domain.WireRecord{ID: id, Rev: "1", Blob: []byte("opaque")}}})
	if err != nil {
		t.Fatal(err)
	}
	if created.Outcomes[0].Kind != "accepted" {
		t.Fatalf("create rejected: %#v", created)
	}
	if err := store.withPrincipal(ctx, second, func(tx pgx.Tx, _ uuid.UUID) error {
		var visibleSpaces, visibleRecords int
		if err := tx.QueryRow(ctx, "SELECT count(*) FROM spaces WHERE id=$1", space.Scope.SpaceID).Scan(&visibleSpaces); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, "SELECT count(*) FROM records WHERE space_id=$1", space.Scope.SpaceID).Scan(&visibleRecords); err != nil {
			return err
		}
		if visibleSpaces != 0 || visibleRecords != 0 {
			return fmt.Errorf("RLS exposed another tenant: spaces=%d records=%d", visibleSpaces, visibleRecords)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ListSpaces(ctx, second); err != nil {
		t.Fatal(err)
	}
	var secondUser uuid.UUID
	if err := ownerPool.QueryRow(ctx, "SELECT user_id FROM identities WHERE identity_digest=$1", second.IdentityDigest[:]).Scan(&secondUser); err != nil {
		t.Fatal(err)
	}
	if _, err := ownerPool.Exec(ctx, "INSERT INTO space_memberships(space_id,user_id,role,scope_binding) VALUES($1,$2,'reader',$3)", space.Scope.SpaceID, secondUser, make([]byte, 32)); err != nil {
		t.Fatal(err)
	}
	readerSpace, err := store.GetSpace(ctx, second, space.Scope.SpaceID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Submit(ctx, second, space.Scope.SpaceID, readerSpace.Scope, []domain.BatchItem{{Record: domain.WireRecord{ID: uuid.New(), Rev: "reader"}}}); domain.AsServiceError(err).Code != domain.Forbidden {
		t.Fatalf("reader submit returned %v", err)
	}
	if err := store.CancelPairing(ctx, second, space.Scope.SpaceID, uuid.New()); domain.AsServiceError(err).Code != domain.Forbidden {
		t.Fatalf("reader pairing cancellation returned %v", err)
	}
	wrong := "v2.invalid.invalid.invalid.invalid"
	conflict, err := store.Submit(ctx, first, space.Scope.SpaceID, space.Scope, []domain.BatchItem{{Record: domain.WireRecord{ID: id, Rev: "2", Blob: []byte("other")}, ExpectedRecordVersion: &wrong}})
	if err != nil {
		t.Fatal(err)
	}
	if conflict.Outcomes[0].Kind != "conflict" || conflict.Outcomes[0].AuthoritativeRecord == nil {
		t.Fatalf("CAS conflict missing: %#v", conflict)
	}
	page, err := store.FetchChanges(ctx, first, space.Scope.SpaceID, nil, 50)
	if err != nil || len(page.Records) != 1 {
		t.Fatalf("snapshot failed: %v %#v", err, page)
	}
	if _, err := ownerPool.Exec(ctx, "SELECT snippets_private.rotate_dataset_after_restore($1)", space.Scope.SpaceID); err != nil {
		t.Fatal(err)
	}
	restored, err := store.GetSpace(ctx, first, space.Scope.SpaceID)
	if err != nil {
		t.Fatal(err)
	}
	if restored.Scope.DatasetGeneration == space.Scope.DatasetGeneration || restored.Scope.FeedEpoch == space.Scope.FeedEpoch {
		t.Fatalf("restore did not rotate scope: before=%#v after=%#v", space.Scope, restored.Scope)
	}
	if _, err := store.FetchChanges(ctx, first, space.Scope.SpaceID, &page.Cursor, 50); domain.AsServiceError(err).Code != domain.DatasetReset {
		t.Fatalf("pre-restore cursor was accepted: %v", err)
	}
	restoredPage, err := store.FetchChanges(ctx, first, space.Scope.SpaceID, nil, 50)
	if err != nil || len(restoredPage.Records) != 1 || restoredPage.Records[0].RecordVersion == *created.Outcomes[0].RecordVersion {
		t.Fatalf("restore snapshot/version failed: %v %#v", err, restoredPage)
	}
	var currentBytes, historyBytes int64
	if err := ownerPool.QueryRow(ctx, "SELECT current_record_bytes,change_history_bytes FROM spaces WHERE id=$1", space.Scope.SpaceID).Scan(&currentBytes, &historyBytes); err != nil {
		t.Fatal(err)
	}
	if _, err := ownerPool.Exec(ctx, "UPDATE spaces SET current_record_bytes=$2 WHERE id=$1", space.Scope.SpaceID, domain.MaxStorageBytesPerSpace-historyBytes); err != nil {
		t.Fatal(err)
	}
	quota, err := store.Submit(ctx, first, space.Scope.SpaceID, restored.Scope, []domain.BatchItem{{Record: domain.WireRecord{ID: uuid.New(), Rev: "quota", Blob: []byte("opaque")}}})
	if err != nil || len(quota.Outcomes) != 1 || quota.Outcomes[0].Kind != "rejected" || quota.Outcomes[0].ErrorCode == nil || *quota.Outcomes[0].ErrorCode != domain.QuotaExceeded {
		t.Fatalf("storage quota was not enforced: %v %#v", err, quota)
	}
	if _, err := ownerPool.Exec(ctx, "UPDATE spaces SET current_record_bytes=$2 WHERE id=$1", space.Scope.SpaceID, currentBytes); err != nil {
		t.Fatal(err)
	}
	nearBaseline, err := store.CreateSpace(ctx, first, nil)
	if err != nil {
		t.Fatal(err)
	}
	const nearHalfQuota = int64(240 * 1024 * 1024)
	if _, err := ownerPool.Exec(ctx, "UPDATE spaces SET current_record_bytes=$2,change_history_bytes=$2 WHERE id=$1", nearBaseline.Scope.SpaceID, nearHalfQuota); err != nil {
		t.Fatal(err)
	}
	feedBefore := nearBaseline.Scope.FeedEpoch
	staleScope := nearBaseline.Scope
	staleScope.FeedEpoch = uuid.New()
	if _, err := store.Submit(ctx, first, nearBaseline.Scope.SpaceID, staleScope, []domain.BatchItem{{Record: domain.WireRecord{ID: uuid.New(), Rev: "stale"}}}); domain.AsServiceError(err).Code != domain.CursorInvalid {
		t.Fatalf("stale near-threshold submit returned %v", err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		result, err := store.Submit(ctx, first, nearBaseline.Scope.SpaceID, nearBaseline.Scope, []domain.BatchItem{{Record: domain.WireRecord{ID: uuid.New(), Rev: "r", Blob: []byte("x")}}})
		if err != nil || result.Outcomes[0].Kind != "accepted" || result.Scope.FeedEpoch != feedBefore {
			t.Fatalf("near-baseline write %d repeated compaction: %v %#v", attempt, err, result)
		}
	}
	lockConnection, err := ownerPool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockConnection.Exec(ctx, "SELECT pg_advisory_lock(hashtextextended(encode($1::bytea,'hex'),11))", first.CredentialDigest[:]); err != nil {
		lockConnection.Release()
		t.Fatal(err)
	}
	started := time.Now()
	_, lockErr := store.ListSpaces(ctx, first)
	if _, err := lockConnection.Exec(ctx, "SELECT pg_advisory_unlock(hashtextextended(encode($1::bytea,'hex'),11))", first.CredentialDigest[:]); err != nil {
		lockConnection.Release()
		t.Fatal(err)
	}
	lockConnection.Release()
	if domain.AsServiceError(lockErr).Code != domain.DependencyUnavailable || time.Since(started) > time.Second {
		t.Fatalf("credential lock timeout was not bounded: duration=%s error=%v", time.Since(started), lockErr)
	}
	if err := store.RevokeAccessToken(ctx, first); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ListSpaces(ctx, first); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatalf("logout was not linearized: %v", err)
	}
}

func TestPostgresSnapshotPaginationIsStableAcrossInterleavedWrites(t *testing.T) {
	if os.Getenv("SNIPPETS_INTEGRATION_TESTS") != "1" {
		t.Skip("set SNIPPETS_INTEGRATION_TESTS=1")
	}
	port, _ := strconv.Atoi(os.Getenv("DATABASE_PORT"))
	ctx := context.Background()
	pool, err := NewPool(ctx, config.Database{Host: os.Getenv("DATABASE_HOST"), Port: port, Name: os.Getenv("DATABASE_NAME"), RuntimeUser: os.Getenv("DATABASE_RUNTIME_USER"), RuntimePassword: os.Getenv("DATABASE_RUNTIME_PASSWORD"), TLSMode: os.Getenv("DATABASE_TLS_MODE"), StatementTimeout: 2 * time.Second, LockTimeout: 250 * time.Millisecond, MaxConnections: 8})
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	store, err := NewStore(pool, uuid.New(), make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	owner := integrationPrincipal(21)
	space, err := store.CreateSpace(ctx, owner, nil)
	if err != nil {
		t.Fatal(err)
	}
	ids := []uuid.UUID{
		uuid.MustParse("10000000-0000-0000-0000-000000000001"),
		uuid.MustParse("10000000-0000-0000-0000-000000000002"),
		uuid.MustParse("10000000-0000-0000-0000-000000000003"),
		uuid.MustParse("10000000-0000-0000-0000-000000000004"),
		uuid.MustParse("10000000-0000-0000-0000-000000000005"),
	}
	items := make([]domain.BatchItem, 4)
	for index := range items {
		items[index] = domain.BatchItem{Record: domain.WireRecord{ID: ids[index], Rev: "1", Blob: []byte{byte(index)}}}
	}
	created, err := store.Submit(ctx, owner, space.Scope.SpaceID, space.Scope, items)
	if err != nil {
		t.Fatal(err)
	}
	first, err := store.FetchChanges(ctx, owner, space.Scope.SpaceID, nil, 2)
	if err != nil || !first.HasMore || len(first.Records) != 2 {
		t.Fatalf("first snapshot page: %v %#v", err, first)
	}
	updateVersion := *created.Outcomes[2].RecordVersion
	deleteVersion := *created.Outcomes[3].RecordVersion
	_, err = store.Submit(ctx, owner, space.Scope.SpaceID, space.Scope, []domain.BatchItem{
		{Record: domain.WireRecord{ID: ids[2], Rev: "2", Blob: []byte("updated")}, ExpectedRecordVersion: &updateVersion},
		{Record: domain.WireRecord{ID: ids[3], Rev: "2", Deleted: true}, ExpectedRecordVersion: &deleteVersion},
		{Record: domain.WireRecord{ID: ids[4], Rev: "1", Blob: []byte("new")}},
	})
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.FetchChanges(ctx, owner, space.Scope.SpaceID, &first.Cursor, 2)
	if err != nil || second.HasMore || len(second.Records) != 2 {
		t.Fatalf("second snapshot page: %v %#v", err, second)
	}
	if second.Records[0].Record.ID != ids[2] || second.Records[0].Record.Rev != "1" ||
		second.Records[1].Record.ID != ids[3] || second.Records[1].Record.Rev != "1" || second.Records[1].Record.Deleted {
		t.Fatalf("snapshot crossed its watermark: %#v", second.Records)
	}
	delta, err := store.FetchChanges(ctx, owner, space.Scope.SpaceID, &second.Cursor, 50)
	if err != nil || delta.FullSnapshot || len(delta.Records) != 3 {
		t.Fatalf("delta after snapshot: %v %#v", err, delta)
	}
}

func integrationPrincipal(seed byte) domain.Principal {
	var identity, credential [32]byte
	for i := range identity {
		identity[i] = seed
		credential[i] = seed + 10
	}
	return domain.Principal{IdentityDigest: identity, CredentialDigest: credential, ExpiresAt: time.Now().Add(5 * time.Minute)}
}
