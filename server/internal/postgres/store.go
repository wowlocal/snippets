package postgres

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/url"
	"sort"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/domain"
)

type Store struct {
	pool             *pgxpool.Pool
	serverInstanceID uuid.UUID
	codec            *domain.TokenCodec
}

const minimumSchemaVersion int64 = 1
const maximumSchemaVersion int64 = 1

func NewPool(ctx context.Context, configuration config.Database) (*pgxpool.Pool, error) {
	poolConfig, err := newPoolConfig(configuration)
	if err != nil {
		return nil, err
	}
	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	if err := validateSchemaCompatibility(ctx, pool); err != nil {
		pool.Close()
		return nil, err
	}
	return pool, nil
}

func validateSchemaCompatibility(ctx context.Context, pool *pgxpool.Pool) error {
	var version, appliedCount int64
	if err := pool.QueryRow(ctx, "SELECT coalesce(max(version),0),count(*) FROM snippets_private.schema_migrations").Scan(&version, &appliedCount); err != nil {
		return fmt.Errorf("database schema version unavailable: %w", err)
	}
	if version < minimumSchemaVersion || version > maximumSchemaVersion {
		return fmt.Errorf("database schema version %d is outside supported range %d..%d", version, minimumSchemaVersion, maximumSchemaVersion)
	}
	// Versions are positive and unique, so count == max proves that the applied
	// production history is exactly 1...max. Pre-launch candidate histories were
	// deliberately squashed and receive no runtime compatibility exception.
	if appliedCount != version {
		return fmt.Errorf("database schema migration history is not contiguous through version %d", version)
	}
	return nil
}

func newPoolConfig(configuration config.Database) (*pgxpool.Config, error) {
	query := url.Values{"sslmode": []string{configuration.TLSMode}}
	if configuration.TLSRootCert != "" {
		query.Set("sslrootcert", configuration.TLSRootCert)
	}
	if configuration.ChannelBinding != "" {
		query.Set("channel_binding", configuration.ChannelBinding)
	}
	if configuration.RequireAuth != "" {
		query.Set("require_auth", configuration.RequireAuth)
	}
	if configuration.ConnectTimeout > 0 {
		query.Set("connect_timeout", strconv.Itoa(int(configuration.ConnectTimeout/time.Second)))
	}
	if configuration.StatementTimeout > 0 {
		query.Set("statement_timeout", strconv.FormatInt(configuration.StatementTimeout.Milliseconds(), 10))
	}
	if configuration.LockTimeout > 0 {
		query.Set("lock_timeout", strconv.FormatInt(configuration.LockTimeout.Milliseconds(), 10))
	}
	dsn := (&url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(configuration.RuntimeUser, configuration.RuntimePassword),
		Host:     net.JoinHostPort(configuration.Host, strconv.Itoa(configuration.Port)),
		Path:     "/" + configuration.Name,
		RawQuery: query.Encode(),
	}).String()
	poolConfig, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	poolConfig.MaxConns = configuration.MaxConnections
	poolConfig.MinConns = 1
	poolConfig.MaxConnLifetime = 30 * time.Minute
	poolConfig.MaxConnIdleTime = 5 * time.Minute
	poolConfig.HealthCheckPeriod = 30 * time.Second
	return poolConfig, nil
}

func NewStore(pool *pgxpool.Pool, serverInstanceID uuid.UUID, tokenSecret []byte) (*Store, error) {
	if pool == nil || serverInstanceID == uuid.Nil {
		return nil, domain.NewError(domain.InternalError)
	}
	codec, err := domain.NewTokenCodec(tokenSecret)
	if err != nil {
		return nil, err
	}
	return &Store{pool: pool, serverInstanceID: serverInstanceID, codec: codec}, nil
}

func (s *Store) Readiness(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *Store) IsAccessTokenRevoked(ctx context.Context, principal domain.Principal) (bool, error) {
	var revoked bool
	err := s.pool.QueryRow(ctx, "SELECT snippets_private.is_access_token_revoked($1)", principal.CredentialDigest[:]).Scan(&revoked)
	return revoked, mapDatabaseError(err)
}

func (s *Store) RevokeAccessToken(ctx context.Context, principal domain.Principal) error {
	for attempt := 0; attempt < 3; attempt++ {
		err := s.revokeAccessTokenAttempt(ctx, principal)
		if !isRetryableTransactionError(err) {
			return mapDatabaseError(err)
		}
		if err := waitForTransactionRetry(ctx, attempt); err != nil {
			return mapDatabaseError(err)
		}
	}
	return domain.ErrorWithRetry(domain.DependencyUnavailable, 1)
}

func (s *Store) revokeAccessTokenAttempt(ctx context.Context, principal domain.Principal) error {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := lockCredentialExclusive(ctx, tx, principal.CredentialDigest); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "SELECT snippets_private.revoke_access_token($1, $2)", principal.CredentialDigest[:], principal.ExpiresAt); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Store) ListSpaces(ctx context.Context, principal domain.Principal) ([]domain.Space, error) {
	return withPrincipalValue(s, ctx, principal, func(tx pgx.Tx, _ uuid.UUID) ([]domain.Space, error) {
		rows, err := tx.Query(ctx, `SELECT s.id, encode(sm.scope_binding, 'base64'), s.dataset_generation, s.feed_epoch, sm.role, s.key_epoch
            FROM spaces s JOIN space_memberships sm ON sm.space_id = s.id
            WHERE sm.user_id = snippets_private.current_user_id() ORDER BY s.id`)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		result := make([]domain.Space, 0)
		for rows.Next() {
			value, err := scanSpace(rows)
			if err != nil {
				return nil, err
			}
			result = append(result, value)
		}
		if err := rows.Err(); err != nil {
			return nil, err
		}
		return result, nil
	})
}

func (s *Store) CreateSpace(ctx context.Context, principal domain.Principal, idempotencyKey *uuid.UUID) (domain.Space, error) {
	var result domain.Space
	err := s.withPrincipal(ctx, principal, func(tx pgx.Tx, userID uuid.UUID) error {
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1, 17))", userID.String()); err != nil {
			return err
		}
		if idempotencyKey != nil {
			row := tx.QueryRow(ctx, `SELECT s.id, encode(sm.scope_binding, 'base64'), s.dataset_generation, s.feed_epoch, sm.role, s.key_epoch
                    FROM space_creation_requests cr JOIN spaces s ON s.id = cr.space_id
                    JOIN space_memberships sm ON sm.space_id = s.id AND sm.user_id = cr.user_id
                    WHERE cr.user_id = $1 AND cr.idempotency_key = $2`, userID, *idempotencyKey)
			value, err := scanSpace(row)
			if err == nil {
				result = value
				return nil
			}
			if !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
		}
		var count int
		if err := tx.QueryRow(ctx, "SELECT count(*) FROM spaces WHERE owner_user_id = $1", userID).Scan(&count); err != nil {
			return err
		}
		if count >= domain.MaxSpacesPerUser {
			return domain.ErrorWithLimit(domain.QuotaExceeded, domain.MaxSpacesPerUser)
		}
		spaceID, dataset, feed := uuid.New(), uuid.New(), uuid.New()
		binding := randomBytes(32)
		if _, err := tx.Exec(ctx, "INSERT INTO spaces(id, owner_user_id, dataset_generation, feed_epoch, key_epoch, next_sequence) VALUES($1,$2,$3,$4,1,0)", spaceID, userID, dataset, feed); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "INSERT INTO space_memberships(space_id,user_id,role,scope_binding) VALUES($1,$2,'owner',$3)", spaceID, userID, binding); err != nil {
			return err
		}
		if idempotencyKey != nil {
			if _, err := tx.Exec(ctx, "INSERT INTO space_creation_requests(user_id,idempotency_key,space_id) VALUES($1,$2,$3)", userID, *idempotencyKey, spaceID); err != nil {
				return err
			}
		}
		result = domain.Space{Scope: domain.Scope{SpaceID: spaceID, ScopeBinding: base64.RawURLEncoding.EncodeToString(binding), DatasetGeneration: dataset, FeedEpoch: feed}, Role: domain.Owner, KeyEpoch: 1}
		return nil
	})
	return result, err
}

func (s *Store) GetSpace(ctx context.Context, principal domain.Principal, spaceID uuid.UUID) (domain.Space, error) {
	var result domain.Space
	err := s.withPrincipal(ctx, principal, func(tx pgx.Tx, _ uuid.UUID) error {
		value, err := getSpace(ctx, tx, spaceID)
		result = value
		return err
	})
	return result, err
}

func (s *Store) FetchChanges(ctx context.Context, principal domain.Principal, spaceID uuid.UUID, cursor *string, limit int) (domain.ChangesPage, error) {
	if limit < 1 || limit > domain.MaxPageRecords {
		return domain.ChangesPage{}, domain.NewError(domain.InvalidRequest)
	}
	var result domain.ChangesPage
	err := s.withPrincipal(ctx, principal, func(tx pgx.Tx, _ uuid.UUID) error {
		space, err := getSpace(ctx, tx, spaceID)
		if err != nil {
			return err
		}
		var highWater int64
		if err := tx.QueryRow(ctx, "SELECT next_sequence FROM spaces WHERE id=$1", spaceID).Scan(&highWater); err != nil {
			return err
		}
		if cursor == nil {
			result, err = s.snapshot(ctx, tx, space, nil, highWater, limit)
			return err
		}
		var payload domain.CursorPayload
		if err := s.codec.Decode(*cursor, &payload); err != nil {
			return err
		}
		if payload.Version != 2 || payload.ServerInstanceID != s.serverInstanceID || payload.SpaceID != spaceID {
			return domain.NewError(domain.CursorInvalid)
		}
		if payload.DatasetGeneration != space.Scope.DatasetGeneration {
			return domain.NewError(domain.DatasetReset)
		}
		if payload.FeedEpoch != space.Scope.FeedEpoch {
			return domain.NewError(domain.CursorInvalid)
		}
		if payload.Kind == domain.SnapshotCursor {
			result, err = s.snapshot(ctx, tx, space, payload.SnapshotAfterID, payload.SnapshotHighWater, limit)
			return err
		}
		if payload.Kind != domain.DeltaCursor || payload.Sequence < 0 {
			return domain.NewError(domain.CursorInvalid)
		}
		rows, err := tx.Query(ctx, `SELECT record_id,rev,deleted,blob,record_generation,sequence FROM changes
                WHERE space_id=$1 AND sequence>$2 ORDER BY sequence LIMIT $3`, spaceID, payload.Sequence, limit+1)
		if err != nil {
			return err
		}
		defer rows.Close()
		var records []domain.ServerRecord
		sequence := payload.Sequence
		rowCount := 0
		for rows.Next() {
			rowCount++
			var record domain.WireRecord
			var generation, currentSequence int64
			if err := rows.Scan(&record.ID, &record.Rev, &record.Deleted, &record.Blob, &generation, &currentSequence); err != nil {
				return err
			}
			if len(records) < limit {
				serverRecord, err := s.makeServerRecord(space, record, generation)
				if err != nil {
					return err
				}
				records = append(records, serverRecord)
				sequence = currentSequence
			}
		}
		if err := rows.Err(); err != nil {
			return err
		}
		hasMore := rowCount > limit
		next, err := s.codec.Encode(domain.CursorPayload{Version: 2, Kind: domain.DeltaCursor, ServerInstanceID: s.serverInstanceID, SpaceID: spaceID, DatasetGeneration: space.Scope.DatasetGeneration, FeedEpoch: space.Scope.FeedEpoch, Sequence: sequence})
		if err != nil {
			return err
		}
		result = domain.ChangesPage{Scope: space.Scope, Records: records, Cursor: next, HasMore: hasMore, FullSnapshot: false}
		return nil
	})
	return result, err
}

func (s *Store) snapshot(ctx context.Context, tx pgx.Tx, space domain.Space, after *uuid.UUID, highWater int64, limit int) (domain.ChangesPage, error) {
	rows, err := tx.Query(ctx, `SELECT record_id,rev,deleted,blob,record_generation
	        FROM (
	            SELECT DISTINCT ON (record_id) record_id,rev,deleted,blob,record_generation
	            FROM changes
	            WHERE space_id=$1 AND sequence<=$2 AND ($3::uuid IS NULL OR record_id>$3)
	            ORDER BY record_id,sequence DESC
	        ) AS snapshot
	        ORDER BY record_id LIMIT $4`, space.Scope.SpaceID, highWater, after, limit+1)
	if err != nil {
		return domain.ChangesPage{}, err
	}
	defer rows.Close()
	var records []domain.ServerRecord
	for rows.Next() {
		var record domain.WireRecord
		var generation int64
		if err := rows.Scan(&record.ID, &record.Rev, &record.Deleted, &record.Blob, &generation); err != nil {
			return domain.ChangesPage{}, err
		}
		value, err := s.makeServerRecord(space, record, generation)
		if err != nil {
			return domain.ChangesPage{}, err
		}
		records = append(records, value)
	}
	if err := rows.Err(); err != nil {
		return domain.ChangesPage{}, err
	}
	hasMore := len(records) > limit
	if hasMore {
		records = records[:limit]
	}
	payload := domain.CursorPayload{Version: 2, Kind: domain.DeltaCursor, ServerInstanceID: s.serverInstanceID, SpaceID: space.Scope.SpaceID, DatasetGeneration: space.Scope.DatasetGeneration, FeedEpoch: space.Scope.FeedEpoch, Sequence: highWater}
	if hasMore {
		last := records[len(records)-1].Record.ID
		payload.Kind, payload.Sequence, payload.SnapshotAfterID, payload.SnapshotHighWater = domain.SnapshotCursor, 0, &last, highWater
	}
	cursor, err := s.codec.Encode(payload)
	if err != nil {
		return domain.ChangesPage{}, err
	}
	return domain.ChangesPage{Scope: space.Scope, Records: records, Cursor: cursor, HasMore: hasMore, FullSnapshot: true}, nil
}

func (s *Store) Submit(ctx context.Context, principal domain.Principal, spaceID uuid.UUID, expectedScope domain.Scope, items []domain.BatchItem) (domain.BatchSubmission, error) {
	if len(items) == 0 || len(items) > domain.MaxBatchRecords {
		return domain.BatchSubmission{}, domain.NewError(domain.InvalidRequest)
	}
	seen := map[uuid.UUID]struct{}{}
	for _, item := range items {
		if _, ok := seen[item.Record.ID]; ok {
			return domain.BatchSubmission{}, domain.NewError(domain.InvalidRequest)
		}
		seen[item.Record.ID] = struct{}{}
	}
	var result domain.BatchSubmission
	err := s.withPrincipal(ctx, principal, func(tx pgx.Tx, _ uuid.UUID) error {
		space, err := getSpace(ctx, tx, spaceID)
		if err != nil {
			return err
		}
		if !space.Role.CanWrite() {
			return domain.NewError(domain.Forbidden)
		}
		// The quota lock serializes dataset/feed rotation with the scope read below.
		// Checking an earlier unlocked snapshot would leave a window in which a stale
		// create-only write could land in a newly restored dataset.
		var locked bool
		if err := tx.QueryRow(ctx, "SELECT snippets_private.lock_storage_quota($1)", spaceID).Scan(&locked); err != nil {
			return err
		}
		if !locked {
			return domain.NewError(domain.NotFound)
		}
		space, err = getSpace(ctx, tx, spaceID)
		if err != nil {
			return err
		}
		if !space.Role.CanWrite() {
			return domain.NewError(domain.Forbidden)
		}
		if err := expectedScope.RequireCurrentMutationScope(space.Scope); err != nil {
			return err
		}
		type indexed struct {
			index int
			item  domain.BatchItem
		}
		ordered := make([]indexed, len(items))
		for i, item := range items {
			ordered[i] = indexed{i, item}
		}
		sort.Slice(ordered, func(i, j int) bool { return ordered[i].item.Record.ID.String() < ordered[j].item.Record.ID.String() })
		for _, value := range ordered {
			if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1, 29))", spaceID.String()+":"+value.item.Record.ID.String()); err != nil {
				return err
			}
		}
		outcomes := make([]domain.BatchOutcome, len(items))
		type preparedMutation struct {
			indexed
			blob             []byte
			generation       int64
			currentByteDelta int64
			changeBytes      int64
			recordCountDelta int64
			accepted         bool
			sequence         int64
		}
		prepared := make([]preparedMutation, 0, len(items))
		for _, value := range ordered {
			item := value.item
			if err := item.Record.Validate(); err != nil {
				code := domain.AsServiceError(err).Code
				outcomes[value.index] = domain.BatchOutcome{Kind: "rejected", ErrorCode: &code}
				continue
			}
			if item.ExpectedRecordVersion != nil && (len(*item.ExpectedRecordVersion) < 32 || len(*item.ExpectedRecordVersion) > 2048) {
				code := domain.InvalidRequest
				outcomes[value.index] = domain.BatchOutcome{Kind: "rejected", ErrorCode: &code}
				continue
			}
			var current domain.WireRecord
			var generation int64
			err := tx.QueryRow(ctx, "SELECT record_id,rev,deleted,blob,record_generation FROM records WHERE space_id=$1 AND record_id=$2", spaceID, item.Record.ID).Scan(&current.ID, &current.Rev, &current.Deleted, &current.Blob, &generation)
			exists := err == nil
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
			matches := !exists && item.ExpectedRecordVersion == nil
			var authoritative *domain.ServerRecord
			if exists {
				serverRecord, err := s.makeServerRecord(space, current, generation)
				if err != nil {
					return err
				}
				authoritative = &serverRecord
				if item.ExpectedRecordVersion != nil {
					matches = serverRecord.RecordVersion == *item.ExpectedRecordVersion
				}
			}
			if !matches {
				outcomes[value.index] = domain.BatchOutcome{Kind: "conflict", AuthoritativeRecord: authoritative}
				continue
			}
			blob := item.Record.Blob
			if blob == nil {
				blob = []byte{}
			}
			oldBytes := 0
			if exists {
				oldBytes = len(current.Blob) + len([]byte(current.Rev))
			}
			newBytes := len(blob) + len([]byte(item.Record.Rev))
			countDelta := int64(0)
			if !exists {
				countDelta = 1
			}
			prepared = append(prepared, preparedMutation{
				indexed: value, blob: blob, generation: generation + 1,
				currentByteDelta: int64(newBytes - oldBytes), changeBytes: int64(newBytes),
				recordCountDelta: countDelta,
			})
		}

		var currentByteDelta, changeBytes, recordCountDelta, changeCountDelta int64
		needsCompaction := false
		admissionOrder := make([]int, len(prepared))
		for index := range prepared {
			admissionOrder[index] = index
		}
		// Record locks stay UUID ordered, but total-storage-releasing mutations are
		// admitted first. Applying in this same order also prevents transient quota
		// violations in the statement-level accounting triggers.
		sort.SliceStable(admissionOrder, func(i, j int) bool {
			left := &prepared[admissionOrder[i]]
			right := &prepared[admissionOrder[j]]
			return left.currentByteDelta+left.changeBytes < right.currentByteDelta+right.changeBytes
		})
		for _, index := range admissionOrder {
			candidate := &prepared[index]
			nextCurrentDelta := currentByteDelta + candidate.currentByteDelta
			nextChangeBytes := changeBytes + candidate.changeBytes
			nextRecordDelta := recordCountDelta + candidate.recordCountDelta
			nextChangeCount := changeCountDelta + 1
			var within bool
			if err := tx.QueryRow(ctx, "SELECT snippets_private.batch_write_within_quota($1,$2,$3,$4,$5,$6)",
				spaceID, nextCurrentDelta, nextChangeBytes, nextRecordDelta, nextChangeCount, needsCompaction).Scan(&within); err != nil {
				return err
			}
			if !within && !needsCompaction {
				if err := tx.QueryRow(ctx, "SELECT snippets_private.batch_write_within_quota($1,$2,$3,$4,$5,true)",
					spaceID, nextCurrentDelta, nextChangeBytes, nextRecordDelta, nextChangeCount).Scan(&within); err != nil {
					return err
				}
				if within {
					needsCompaction = true
				}
			}
			if !within {
				code := domain.QuotaExceeded
				outcomes[candidate.index] = domain.BatchOutcome{Kind: "rejected", ErrorCode: &code}
				continue
			}
			candidate.accepted = true
			currentByteDelta, changeBytes = nextCurrentDelta, nextChangeBytes
			recordCountDelta, changeCountDelta = nextRecordDelta, nextChangeCount
		}
		if needsCompaction {
			var compacted bool
			if err := tx.QueryRow(ctx, "SELECT snippets_private.compact_change_history_if_needed($1,$2,$3,$4,$5,true)",
				spaceID, currentByteDelta, changeBytes, recordCountDelta, changeCountDelta).Scan(&compacted); err != nil {
				return err
			}
			if !compacted {
				// Batch preflight and the definitive maintenance predicate execute
				// under the same quota locks and must agree.
				return domain.NewError(domain.InternalError)
			}
		}

		acceptedCount := int64(0)
		for index := range prepared {
			if prepared[index].accepted {
				acceptedCount++
			}
		}
		if acceptedCount > 0 {
			var finalSequence int64
			if err := tx.QueryRow(ctx,
				"UPDATE spaces SET next_sequence=next_sequence+$2 WHERE id=$1 RETURNING next_sequence",
				spaceID, acceptedCount).Scan(&finalSequence); err != nil {
				return err
			}
			nextSequence := finalSequence - acceptedCount
			// Preserve the established UUID-ordered feed even though physical writes run
			// in admission order to keep every accounting-trigger boundary within quota.
			for index := range prepared {
				if prepared[index].accepted {
					nextSequence++
					prepared[index].sequence = nextSequence
				}
			}
		}
		accepted := acceptedCount > 0
		for _, index := range admissionOrder {
			candidate := prepared[index]
			if !candidate.accepted {
				continue
			}
			item := candidate.item
			_, err = tx.Exec(ctx, `INSERT INTO records(space_id,record_id,rev,deleted,blob,record_generation,last_sequence) VALUES($1,$2,$3,$4,$5,$6,$7)
			    ON CONFLICT(space_id,record_id) DO UPDATE SET rev=EXCLUDED.rev,deleted=EXCLUDED.deleted,blob=EXCLUDED.blob,record_generation=EXCLUDED.record_generation,last_sequence=EXCLUDED.last_sequence,updated_at=clock_timestamp()`, spaceID, item.Record.ID, item.Record.Rev, item.Record.Deleted, candidate.blob, candidate.generation, candidate.sequence)
			if err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, "INSERT INTO changes(space_id,sequence,record_id,rev,deleted,blob,record_generation) VALUES($1,$2,$3,$4,$5,$6,$7)", spaceID, candidate.sequence, item.Record.ID, item.Record.Rev, item.Record.Deleted, candidate.blob, candidate.generation); err != nil {
				return err
			}
			storedRecord := item.Record
			storedRecord.Blob = candidate.blob
			serverRecord, err := s.makeServerRecord(space, storedRecord, candidate.generation)
			if err != nil {
				return err
			}
			version, revision := serverRecord.RecordVersion, item.Record.Rev
			outcomes[candidate.index] = domain.BatchOutcome{Kind: "accepted", RecordVersion: &version, Revision: &revision}
		}
		if accepted && !needsCompaction {
			var compacted bool
			if err := tx.QueryRow(ctx, "SELECT snippets_private.compact_change_history_if_needed($1,0,0,0,0,false)", spaceID).Scan(&compacted); err != nil {
				return err
			}
		}
		if accepted {
			// Return the committed scope even when this write performed the single
			// allowed feed rotation. The writer does not need a failed retry.
			space, err = getSpace(ctx, tx, spaceID)
			if err != nil {
				return err
			}
		}
		partial := false
		for _, outcome := range outcomes {
			if outcome.Kind != "accepted" {
				partial = true
				break
			}
		}
		result = domain.BatchSubmission{Scope: space.Scope, Outcomes: outcomes, Partial: partial}
		return nil
	})
	return result, err
}

func (s *Store) withPrincipal(ctx context.Context, principal domain.Principal, operation func(pgx.Tx, uuid.UUID) error) error {
	_, err := withPrincipalValue(s, ctx, principal, func(tx pgx.Tx, userID uuid.UUID) (struct{}, error) {
		return struct{}{}, operation(tx, userID)
	})
	return err
}

func withPrincipalValue[T any](s *Store, ctx context.Context, principal domain.Principal, operation func(pgx.Tx, uuid.UUID) (T, error)) (T, error) {
	var zero T
	for attempt := 0; attempt < 3; attempt++ {
		value, err := withPrincipalValueAttempt(s, ctx, principal, operation)
		if !isRetryableTransactionError(err) {
			return value, mapDatabaseError(err)
		}
		if err := waitForTransactionRetry(ctx, attempt); err != nil {
			return zero, mapDatabaseError(err)
		}
	}
	return zero, domain.ErrorWithRetry(domain.DependencyUnavailable, 1)
}

func withPrincipalValueAttempt[T any](s *Store, ctx context.Context, principal domain.Principal, operation func(pgx.Tx, uuid.UUID) (T, error)) (T, error) {
	var zero T
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return zero, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := lockCredentialShared(ctx, tx, principal.CredentialDigest); err != nil {
		return zero, err
	}
	var revoked bool
	if err := tx.QueryRow(ctx, "SELECT snippets_private.is_access_token_revoked($1)", principal.CredentialDigest[:]).Scan(&revoked); err != nil {
		return zero, err
	}
	if revoked {
		return zero, domain.NewError(domain.AuthenticationRequired)
	}
	userID := uuid.New()
	if err := tx.QueryRow(ctx, "SELECT snippets_private.resolve_identity($1,$2)", principal.IdentityDigest[:], userID).Scan(&userID); err != nil {
		return zero, err
	}
	if _, err := tx.Exec(ctx, "SELECT set_config('app.user_id',$1,true)", userID.String()); err != nil {
		return zero, err
	}
	var status string
	if err := tx.QueryRow(ctx, "SELECT status FROM users WHERE id=$1", userID).Scan(&status); err != nil {
		return zero, err
	}
	if status != "active" {
		return zero, domain.NewError(domain.Forbidden)
	}
	value, err := operation(tx, userID)
	if err != nil {
		return zero, err
	}
	if err := tx.Commit(ctx); err != nil {
		return zero, err
	}
	return value, nil
}

func lockCredentialExclusive(ctx context.Context, tx pgx.Tx, digest [32]byte) error {
	_, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended(encode($1::bytea,'hex'), 11))", digest[:])
	return err
}

func lockCredentialShared(ctx context.Context, tx pgx.Tx, digest [32]byte) error {
	_, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock_shared(hashtextextended(encode($1::bytea,'hex'), 11))", digest[:])
	return err
}

func isRetryableTransactionError(err error) bool {
	var pgError *pgconn.PgError
	return errors.As(err, &pgError) && (pgError.Code == "40001" || pgError.Code == "40P01")
}

func waitForTransactionRetry(ctx context.Context, attempt int) error {
	delay := time.Duration(10*(1<<attempt)) * time.Millisecond
	var jitter [1]byte
	if _, err := rand.Read(jitter[:]); err == nil {
		delay += time.Duration(jitter[0]%10) * time.Millisecond
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

type rowScanner interface{ Scan(...any) error }

func scanSpace(row rowScanner) (domain.Space, error) {
	var value domain.Space
	var binding string
	var role string
	err := row.Scan(&value.Scope.SpaceID, &binding, &value.Scope.DatasetGeneration, &value.Scope.FeedEpoch, &role, &value.KeyEpoch)
	if err != nil {
		return domain.Space{}, err
	}
	decoded, err := base64.StdEncoding.DecodeString(binding)
	if err != nil || len(decoded) != 32 {
		return domain.Space{}, domain.NewError(domain.InternalError)
	}
	value.Scope.ScopeBinding = base64.RawURLEncoding.EncodeToString(decoded)
	value.Role = domain.SpaceRole(role)
	return value, nil
}
func getSpace(ctx context.Context, tx pgx.Tx, spaceID uuid.UUID) (domain.Space, error) {
	value, err := scanSpace(tx.QueryRow(ctx, `SELECT s.id,encode(sm.scope_binding,'base64'),s.dataset_generation,s.feed_epoch,sm.role,s.key_epoch FROM spaces s JOIN space_memberships sm ON sm.space_id=s.id AND sm.user_id=snippets_private.current_user_id() WHERE s.id=$1`, spaceID))
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.Space{}, domain.NewError(domain.NotFound)
	}
	return value, err
}
func (s *Store) makeServerRecord(space domain.Space, record domain.WireRecord, generation int64) (domain.ServerRecord, error) {
	token, err := s.codec.Encode(domain.RecordVersionPayload{Version: 2, ServerInstanceID: s.serverInstanceID, SpaceID: space.Scope.SpaceID, DatasetGeneration: space.Scope.DatasetGeneration, RecordID: record.ID, Generation: generation})
	return domain.ServerRecord{Record: record, RecordVersion: token}, err
}
func randomBytes(count int) []byte {
	value := make([]byte, count)
	if _, err := rand.Read(value); err != nil {
		panic("operating system random source unavailable")
	}
	return value
}

func mapDatabaseError(err error) error {
	if err == nil {
		return nil
	}
	var service *domain.ServiceError
	if errors.As(err, &service) {
		return err
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.NewError(domain.NotFound)
	}
	var pgError *pgconn.PgError
	if errors.As(err, &pgError) {
		switch pgError.Code {
		case "23505":
			return domain.NewError(domain.Conflict)
		case "23514", "22023", "22P02":
			return domain.NewError(domain.InvalidRequest)
		case "40001", "40P01", "55P03":
			return domain.ErrorWithRetry(domain.DependencyUnavailable, 1)
		case "42501":
			return domain.NewError(domain.Forbidden)
		}
	}
	return fmt.Errorf("database operation failed: %w: %w", domain.NewError(domain.DependencyUnavailable), err)
}

var _ domain.Store = (*Store)(nil)
