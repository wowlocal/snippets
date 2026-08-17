package postgres

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
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

func NewPool(ctx context.Context, configuration config.Database) (*pgxpool.Pool, error) {
	dsn := (&url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(configuration.RuntimeUser, configuration.RuntimePassword),
		Host:     configuration.Host + ":" + strconv.Itoa(configuration.Port),
		Path:     "/" + configuration.Name,
		RawQuery: url.Values{"sslmode": []string{configuration.TLSMode}}.Encode(),
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
	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return pool, nil
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
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return mapDatabaseError(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := lockCredential(ctx, tx, principal.CredentialDigest); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "SELECT snippets_private.revoke_access_token($1, $2)", principal.CredentialDigest[:], principal.ExpiresAt); err != nil {
		return mapDatabaseError(err)
	}
	return mapDatabaseError(tx.Commit(ctx))
}

func (s *Store) ListSpaces(ctx context.Context, principal domain.Principal) ([]domain.Space, error) {
	var result []domain.Space
	err := s.withPrincipal(ctx, principal, func(tx pgx.Tx, _ uuid.UUID) error {
		rows, err := tx.Query(ctx, `SELECT s.id, encode(sm.scope_binding, 'base64'), s.dataset_generation, s.feed_epoch, sm.role, s.key_epoch
            FROM spaces s JOIN space_memberships sm ON sm.space_id = s.id
            WHERE sm.user_id = snippets_private.current_user_id() ORDER BY s.id`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			value, err := scanSpace(rows)
			if err != nil {
				return err
			}
			result = append(result, value)
		}
		return rows.Err()
	})
	return result, err
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
	rows, err := tx.Query(ctx, `SELECT record_id,rev,deleted,blob,record_generation FROM records
        WHERE space_id=$1 AND ($2::uuid IS NULL OR record_id>$2) ORDER BY record_id LIMIT $3`, space.Scope.SpaceID, after, limit+1)
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
		space, err := getSpace(ctx, tx, spaceID)
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
			oldBytes := 0
			if exists {
				oldBytes = len(current.Blob) + len([]byte(current.Rev))
			}
			newBytes := len(item.Record.Blob) + len([]byte(item.Record.Rev))
			countDelta := int64(0)
			if !exists {
				countDelta = 1
			}
			var within bool
			if err := tx.QueryRow(ctx, "SELECT snippets_private.record_write_within_quota($1,$2,$3,$4)", spaceID, newBytes-oldBytes, newBytes, countDelta).Scan(&within); err != nil {
				return err
			}
			if !within {
				code := domain.QuotaExceeded
				outcomes[value.index] = domain.BatchOutcome{Kind: "rejected", ErrorCode: &code}
				continue
			}
			generation++
			var sequence int64
			if err := tx.QueryRow(ctx, "UPDATE spaces SET next_sequence=next_sequence+1 WHERE id=$1 RETURNING next_sequence", spaceID).Scan(&sequence); err != nil {
				return err
			}
			_, err = tx.Exec(ctx, `INSERT INTO records(space_id,record_id,rev,deleted,blob,record_generation,last_sequence) VALUES($1,$2,$3,$4,$5,$6,$7)
                    ON CONFLICT(space_id,record_id) DO UPDATE SET rev=EXCLUDED.rev,deleted=EXCLUDED.deleted,blob=EXCLUDED.blob,record_generation=EXCLUDED.record_generation,last_sequence=EXCLUDED.last_sequence,updated_at=clock_timestamp()`, spaceID, item.Record.ID, item.Record.Rev, item.Record.Deleted, item.Record.Blob, generation, sequence)
			if err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, "INSERT INTO changes(space_id,sequence,record_id,rev,deleted,blob,record_generation) VALUES($1,$2,$3,$4,$5,$6,$7)", spaceID, sequence, item.Record.ID, item.Record.Rev, item.Record.Deleted, item.Record.Blob, generation); err != nil {
				return err
			}
			serverRecord, err := s.makeServerRecord(space, item.Record, generation)
			if err != nil {
				return err
			}
			version, revision := serverRecord.RecordVersion, item.Record.Rev
			outcomes[value.index] = domain.BatchOutcome{Kind: "accepted", RecordVersion: &version, Revision: &revision}
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
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return mapDatabaseError(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := lockCredential(ctx, tx, principal.CredentialDigest); err != nil {
		return err
	}
	var revoked bool
	if err := tx.QueryRow(ctx, "SELECT snippets_private.is_access_token_revoked($1)", principal.CredentialDigest[:]).Scan(&revoked); err != nil {
		return mapDatabaseError(err)
	}
	if revoked {
		return domain.NewError(domain.AuthenticationRequired)
	}
	userID := uuid.New()
	if err := tx.QueryRow(ctx, "SELECT snippets_private.resolve_identity($1,$2)", principal.IdentityDigest[:], userID).Scan(&userID); err != nil {
		return mapDatabaseError(err)
	}
	if _, err := tx.Exec(ctx, "SELECT set_config('app.user_id',$1,true)", userID.String()); err != nil {
		return mapDatabaseError(err)
	}
	var status string
	if err := tx.QueryRow(ctx, "SELECT status FROM users WHERE id=$1", userID).Scan(&status); err != nil {
		return mapDatabaseError(err)
	}
	if status != "active" {
		return domain.NewError(domain.Forbidden)
	}
	if err := operation(tx, userID); err != nil {
		return mapDatabaseError(err)
	}
	return mapDatabaseError(tx.Commit(ctx))
}

func lockCredential(ctx context.Context, tx pgx.Tx, digest [32]byte) error {
	_, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended(encode($1::bytea,'hex'), 11))", digest[:])
	return mapDatabaseError(err)
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
		case "40001", "40P01":
			return domain.ErrorWithRetry(domain.RateLimited, 1)
		case "42501":
			return domain.NewError(domain.Forbidden)
		}
	}
	return fmt.Errorf("database operation failed: %w", domain.NewError(domain.DependencyUnavailable))
}

var _ domain.Store = (*Store)(nil)
