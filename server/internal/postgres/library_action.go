package postgres

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/wowlocal/snippets/server/internal/domain"
)

// Same owner/space lock order as record submission and dataset rotation. This
// makes empty-library bootstrap and scope checks atomic with record mutations.
func lockKeySpace(ctx context.Context, tx pgx.Tx, id uuid.UUID) (domain.Space, error) {
	var locked bool
	if err := tx.QueryRow(ctx, "SELECT snippets_private.lock_storage_quota($1)", id).Scan(&locked); err != nil {
		return domain.Space{}, err
	}
	if !locked {
		return domain.Space{}, domain.NewError(domain.Forbidden)
	}
	return getSpace(ctx, tx, id)
}

func keyAuthority(ctx context.Context, tx pgx.Tx, space domain.Space) ([]byte, error) {
	var key []byte
	var epoch int
	err := tx.QueryRow(ctx, "SELECT public_key,key_epoch FROM library_key_authorities WHERE space_id=$1", space.Scope.SpaceID).Scan(&key, &epoch)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err == nil && epoch != space.KeyEpoch {
		return nil, domain.NewError(domain.Conflict)
	}
	return key, err
}

func (s *Store) GetKeyAuthority(ctx context.Context, p domain.Principal, id uuid.UUID) (domain.Space, []byte, error) {
	var space domain.Space
	var key []byte
	err := s.withPrincipal(ctx, p, func(tx pgx.Tx, _ uuid.UUID) error {
		var err error
		space, err = getSpace(ctx, tx, id)
		if err != nil {
			return err
		}
		key, err = keyAuthority(ctx, tx, space)
		return err
	})
	return space, key, err
}

func (s *Store) BootstrapLibraryKey(ctx context.Context, p domain.Principal, id uuid.UUID, r domain.KeyBootstrap) (domain.Space, domain.RecoveryEnvelope, error) {
	var space domain.Space
	var envelope domain.RecoveryEnvelope
	if len(r.PublicKey) != ed25519.PublicKeySize || r.Recovery.ExpectedVersion != nil || r.Recovery.Proof != nil {
		return space, envelope, domain.NewError(domain.InvalidRequest)
	}
	if err := r.Recovery.Validate(); err != nil {
		return space, envelope, err
	}
	err := s.withPrincipal(ctx, p, func(tx pgx.Tx, _ uuid.UUID) error {
		var err error
		space, err = lockKeySpace(ctx, tx, id)
		if err != nil {
			return err
		}
		if space.Role != domain.Owner {
			return domain.NewError(domain.Forbidden)
		}
		if err := r.ExpectedScope.RequireCurrentMutationScope(space.Scope); err != nil {
			return err
		}
		if r.Recovery.KeyEpoch != space.KeyEpoch {
			return domain.NewError(domain.Conflict)
		}
		var occupied bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM library_key_authorities WHERE space_id=$1)
 OR EXISTS(SELECT 1 FROM recovery_envelopes WHERE space_id=$1)
 OR EXISTS(SELECT 1 FROM records WHERE space_id=$1) OR EXISTS(SELECT 1 FROM changes WHERE space_id=$1)`, id).Scan(&occupied); err != nil {
			return err
		}
		if occupied {
			return domain.NewError(domain.Conflict)
		}
		if _, err := tx.Exec(ctx, "INSERT INTO library_key_authorities(space_id,public_key,key_epoch) VALUES($1,$2,$3)", id, r.PublicKey, space.KeyEpoch); err != nil {
			return err
		}
		return tx.QueryRow(ctx, "INSERT INTO recovery_envelopes(space_id,version,key_epoch,algorithm,ciphertext) VALUES($1,1,$2,$3,$4) RETURNING version,key_epoch,algorithm,ciphertext,created_at", id, r.Recovery.KeyEpoch, r.Recovery.Algorithm, r.Recovery.Ciphertext).Scan(&envelope.Version, &envelope.KeyEpoch, &envelope.Algorithm, &envelope.Ciphertext, &envelope.CreatedAt)
	})
	return space, envelope, err
}

func (s *Store) CreateLibraryChallenge(ctx context.Context, p domain.Principal, id uuid.UUID, r domain.CreateLibraryChallenge) (domain.Space, domain.LibraryChallenge, error) {
	var space domain.Space
	var challenge domain.LibraryChallenge
	if err := r.Validate(); err != nil {
		return space, challenge, err
	}
	err := s.withPrincipal(ctx, p, func(tx pgx.Tx, _ uuid.UUID) error {
		var err error
		space, err = lockKeySpace(ctx, tx, id)
		if err != nil {
			return err
		}
		if !space.Role.CanWrite() || (r.Action == domain.ReplaceRecovery && space.Role != domain.Owner) {
			return domain.NewError(domain.Forbidden)
		}
		if err := r.ExpectedScope.RequireCurrentMutationScope(space.Scope); err != nil {
			return err
		}
		if r.KeyEpoch != space.KeyEpoch {
			return domain.NewError(domain.Conflict)
		}
		key, err := keyAuthority(ctx, tx, space)
		if err != nil {
			return err
		}
		if len(key) == 0 {
			return domain.NewError(domain.IncompatibleVersion)
		}
		if _, err := tx.Exec(ctx, "DELETE FROM library_action_challenges WHERE space_id=$1 AND expires_at<=clock_timestamp()", id); err != nil {
			return err
		}
		var count int
		if err := tx.QueryRow(ctx, "SELECT count(*) FROM library_action_challenges WHERE space_id=$1", id).Scan(&count); err != nil {
			return err
		}
		if count >= domain.MaxLibraryChallenges {
			return domain.ErrorWithRetry(domain.RateLimited, 60)
		}
		challenge, err = domain.NewLibraryChallenge(r, time.Now())
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO library_action_challenges(space_id,challenge_id,identity_digest,scope_binding,dataset_generation,feed_epoch,action,key_epoch,request_hash,nonce,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`, id, challenge.ID, p.IdentityDigest[:], space.Scope.ScopeBinding, space.Scope.DatasetGeneration, space.Scope.FeedEpoch, challenge.Action, challenge.KeyEpoch, challenge.RequestHash, challenge.Nonce, challenge.ExpiresAt)
		return err
	})
	return space, challenge, err
}

func checkLibraryAction(ctx context.Context, tx pgx.Tx, p domain.Principal, space domain.Space, proof *domain.LibraryActionProof, action domain.LibraryAction, hash []byte) (domain.LibraryActionReceipt, error) {
	var receipt domain.LibraryActionReceipt
	key, err := keyAuthority(ctx, tx, space)
	if err != nil {
		return receipt, err
	}
	if len(key) == 0 {
		return receipt, domain.NewError(domain.IncompatibleVersion)
	}
	if proof == nil {
		return receipt, domain.NewError(domain.IncompatibleVersion)
	}
	var challenge domain.LibraryChallenge
	var identity, raw []byte
	scope := domain.Scope{SpaceID: space.Scope.SpaceID}
	err = tx.QueryRow(ctx, `SELECT challenge_id,identity_digest,scope_binding,dataset_generation,feed_epoch,action,key_epoch,request_hash,nonce,expires_at,receipt FROM library_action_challenges WHERE space_id=$1 AND challenge_id=$2 FOR UPDATE`, space.Scope.SpaceID, proof.ChallengeID).Scan(&challenge.ID, &identity, &scope.ScopeBinding, &scope.DatasetGeneration, &scope.FeedEpoch, &challenge.Action, &challenge.KeyEpoch, &challenge.RequestHash, &challenge.Nonce, &challenge.ExpiresAt, &raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return receipt, domain.NewError(domain.Forbidden)
	}
	if err != nil {
		return receipt, err
	}
	if !domain.ConstantTimeEqual(identity, p.IdentityDigest[:]) {
		return receipt, domain.NewError(domain.Forbidden)
	}
	if err := scope.RequireCurrentMutationScope(space.Scope); err != nil {
		return receipt, err
	}
	if err := challenge.Verify(key, proof, action, space.KeyEpoch, hash, time.Now()); err != nil {
		return receipt, err
	}
	if raw != nil {
		if err := json.Unmarshal(raw, &receipt); err != nil {
			return receipt, err
		}
	}
	return receipt, nil
}

func storeLibraryReceipt(ctx context.Context, tx pgx.Tx, space domain.Space, proof *domain.LibraryActionProof, receipt domain.LibraryActionReceipt) error {
	if proof == nil {
		return nil
	}
	raw, err := json.Marshal(receipt)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, "UPDATE library_action_challenges SET receipt=$3 WHERE space_id=$1 AND challenge_id=$2", space.Scope.SpaceID, proof.ChallengeID, raw)
	return err
}
