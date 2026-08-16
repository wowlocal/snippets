package postgres

import (
	"context"
	"crypto/sha256"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/wowlocal/snippets/server/internal/domain"
)

func (s *Store) GetRecoveryEnvelope(ctx context.Context, principal domain.Principal, spaceID uuid.UUID) (domain.Space, *domain.RecoveryEnvelope, error) {
	var space domain.Space
	var envelope *domain.RecoveryEnvelope
	err := s.withPrincipal(ctx, principal, func(tx pgx.Tx, _ uuid.UUID) error {
		var err error
		space, err = getSpace(ctx, tx, spaceID)
		if err != nil {
			return err
		}
		var value domain.RecoveryEnvelope
		err = tx.QueryRow(ctx, "SELECT version,key_epoch,algorithm,ciphertext,created_at FROM recovery_envelopes WHERE space_id=$1", spaceID).Scan(&value.Version, &value.KeyEpoch, &value.Algorithm, &value.Ciphertext, &value.CreatedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		envelope = &value
		return nil
	})
	return space, envelope, err
}

func (s *Store) PutRecoveryEnvelope(ctx context.Context, principal domain.Principal, spaceID uuid.UUID, request domain.PutRecoveryEnvelope) (domain.Space, domain.RecoveryEnvelope, error) {
	if err := request.Validate(); err != nil {
		return domain.Space{}, domain.RecoveryEnvelope{}, err
	}
	var space domain.Space
	var envelope domain.RecoveryEnvelope
	err := s.withPrincipal(ctx, principal, func(tx pgx.Tx, _ uuid.UUID) error {
		var err error
		space, err = getSpace(ctx, tx, spaceID)
		if err != nil {
			return err
		}
		if space.Role != domain.Owner {
			return domain.NewError(domain.Forbidden)
		}
		if request.KeyEpoch != space.KeyEpoch {
			return domain.NewError(domain.Conflict)
		}
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1, 37))", spaceID.String()+":recovery"); err != nil {
			return err
		}
		var current int
		err = tx.QueryRow(ctx, "SELECT version FROM recovery_envelopes WHERE space_id=$1", spaceID).Scan(&current)
		if errors.Is(err, pgx.ErrNoRows) {
			current = 0
		} else if err != nil {
			return err
		}
		if (request.ExpectedVersion == nil && current != 0) || (request.ExpectedVersion != nil && *request.ExpectedVersion != current) {
			return domain.NewError(domain.Conflict)
		}
		next := current + 1
		err = tx.QueryRow(ctx, `INSERT INTO recovery_envelopes(space_id,version,key_epoch,algorithm,ciphertext) VALUES($1,$2,$3,$4,$5)
            ON CONFLICT(space_id) DO UPDATE SET version=EXCLUDED.version,key_epoch=EXCLUDED.key_epoch,algorithm=EXCLUDED.algorithm,ciphertext=EXCLUDED.ciphertext,created_at=clock_timestamp(),updated_at=clock_timestamp()
            RETURNING version,key_epoch,algorithm,ciphertext,created_at`, spaceID, next, request.KeyEpoch, request.Algorithm, request.Ciphertext).Scan(&envelope.Version, &envelope.KeyEpoch, &envelope.Algorithm, &envelope.Ciphertext, &envelope.CreatedAt)
		return err
	})
	return space, envelope, err
}

func (s *Store) CreatePairing(ctx context.Context, principal domain.Principal, spaceID uuid.UUID, request domain.CreatePairing) (domain.Space, domain.Pairing, error) {
	if err := request.Validate(); err != nil {
		return domain.Space{}, domain.Pairing{}, err
	}
	var space domain.Space
	var pairing domain.Pairing
	err := s.withPrincipal(ctx, principal, func(tx pgx.Tx, _ uuid.UUID) error {
		var err error
		space, err = getSpace(ctx, tx, spaceID)
		if err != nil {
			return err
		}
		if !space.Role.CanWrite() {
			return domain.NewError(domain.Forbidden)
		}
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1, 41))", spaceID.String()+":pairings"); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "DELETE FROM pairings WHERE space_id=$1 AND expires_at<=clock_timestamp()", spaceID); err != nil {
			return err
		}
		var count int
		if err := tx.QueryRow(ctx, "SELECT count(*) FROM pairings WHERE space_id=$1", spaceID).Scan(&count); err != nil {
			return err
		}
		if count >= domain.MaxPairingsPerSpace {
			return domain.ErrorWithRetry(domain.RateLimited, 60)
		}
		hash := sha256.Sum256(request.RecipientPublicKey)
		pairing = domain.Pairing{ID: uuid.New(), SpaceID: spaceID, RecipientPublicKey: append([]byte(nil), request.RecipientPublicKey...), Nonce: append([]byte(nil), request.Nonce...), AuthenticationTag: pairingTag(request.Nonce, request.RecipientPublicKey), State: domain.PairingPending, ExpiresAt: time.Now().UTC().Add(time.Duration(request.ExpiresInSeconds) * time.Second)}
		_, err = tx.Exec(ctx, "INSERT INTO pairings(space_id,pairing_id,recipient_public_key,recipient_key_hash,nonce,authentication_tag,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7)", spaceID, pairing.ID, pairing.RecipientPublicKey, hash[:], pairing.Nonce, pairing.AuthenticationTag, pairing.ExpiresAt)
		return err
	})
	return space, pairing, err
}

func (s *Store) ApprovePairing(ctx context.Context, principal domain.Principal, spaceID, pairingID uuid.UUID, request domain.ApprovePairing) (domain.Space, domain.Pairing, error) {
	if err := request.Validate(); err != nil {
		return domain.Space{}, domain.Pairing{}, err
	}
	var space domain.Space
	var pairing domain.Pairing
	err := s.withPrincipal(ctx, principal, func(tx pgx.Tx, _ uuid.UUID) error {
		var err error
		space, err = getSpace(ctx, tx, spaceID)
		if err != nil {
			return err
		}
		if !space.Role.CanWrite() {
			return domain.NewError(domain.Forbidden)
		}
		var keyHash []byte
		pairing, keyHash, err = scanPairing(tx.QueryRow(ctx, `SELECT pairing_id,space_id,recipient_public_key,recipient_key_hash,nonce,authentication_tag,algorithm,ciphertext,approved_at,expires_at FROM pairings WHERE space_id=$1 AND pairing_id=$2 FOR UPDATE`, spaceID, pairingID))
		if err != nil {
			return err
		}
		if !pairing.ExpiresAt.After(time.Now()) {
			return domain.NewError(domain.PairingExpired)
		}
		if pairing.State != domain.PairingPending || !domain.ConstantTimeEqual(request.RecipientKeyHash, keyHash) {
			return domain.NewError(domain.Conflict)
		}
		algorithm := request.Algorithm
		_, err = tx.Exec(ctx, "UPDATE pairings SET algorithm=$3,ciphertext=$4,approved_at=clock_timestamp() WHERE space_id=$1 AND pairing_id=$2", spaceID, pairingID, algorithm, request.Ciphertext)
		if err != nil {
			return err
		}
		pairing.State = domain.PairingApproved
		pairing.Algorithm = &algorithm
		pairing.Ciphertext = append([]byte(nil), request.Ciphertext...)
		return nil
	})
	return space, pairing, err
}

func (s *Store) GetPairing(ctx context.Context, principal domain.Principal, spaceID, pairingID uuid.UUID) (domain.Space, domain.Pairing, error) {
	var space domain.Space
	var pairing domain.Pairing
	err := s.withPrincipal(ctx, principal, func(tx pgx.Tx, _ uuid.UUID) error {
		var err error
		space, err = getSpace(ctx, tx, spaceID)
		if err != nil {
			return err
		}
		pairing, _, err = scanPairing(tx.QueryRow(ctx, `SELECT pairing_id,space_id,recipient_public_key,recipient_key_hash,nonce,authentication_tag,algorithm,NULL::bytea,approved_at,expires_at FROM pairings WHERE space_id=$1 AND pairing_id=$2`, spaceID, pairingID))
		if err != nil {
			return err
		}
		if !pairing.ExpiresAt.After(time.Now()) {
			return domain.NewError(domain.PairingExpired)
		}
		return nil
	})
	return space, pairing, err
}

func (s *Store) ClaimPairing(ctx context.Context, principal domain.Principal, spaceID, pairingID uuid.UUID) (domain.Space, domain.Pairing, error) {
	var space domain.Space
	var pairing domain.Pairing
	err := s.withPrincipal(ctx, principal, func(tx pgx.Tx, _ uuid.UUID) error {
		var err error
		space, err = getSpace(ctx, tx, spaceID)
		if err != nil {
			return err
		}
		pairing, _, err = scanPairing(tx.QueryRow(ctx, `SELECT pairing_id,space_id,recipient_public_key,recipient_key_hash,nonce,authentication_tag,algorithm,ciphertext,approved_at,expires_at FROM pairings WHERE space_id=$1 AND pairing_id=$2 FOR UPDATE`, spaceID, pairingID))
		if err != nil {
			return err
		}
		if !pairing.ExpiresAt.After(time.Now()) {
			return domain.NewError(domain.PairingExpired)
		}
		if pairing.State != domain.PairingApproved {
			return domain.NewError(domain.Conflict)
		}
		_, err = tx.Exec(ctx, "DELETE FROM pairings WHERE space_id=$1 AND pairing_id=$2", spaceID, pairingID)
		return err
	})
	return space, pairing, err
}

func (s *Store) CancelPairing(ctx context.Context, principal domain.Principal, spaceID, pairingID uuid.UUID) error {
	return s.withPrincipal(ctx, principal, func(tx pgx.Tx, _ uuid.UUID) error {
		space, err := getSpace(ctx, tx, spaceID)
		if err != nil {
			return err
		}
		if !space.Role.CanWrite() {
			return domain.NewError(domain.Forbidden)
		}
		_, err = tx.Exec(ctx, "DELETE FROM pairings WHERE space_id=$1 AND pairing_id=$2", spaceID, pairingID)
		return err
	})
}

func scanPairing(row rowScanner) (domain.Pairing, []byte, error) {
	var value domain.Pairing
	var keyHash []byte
	var approvedAt *time.Time
	err := row.Scan(&value.ID, &value.SpaceID, &value.RecipientPublicKey, &keyHash, &value.Nonce, &value.AuthenticationTag, &value.Algorithm, &value.Ciphertext, &approvedAt, &value.ExpiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.Pairing{}, nil, domain.NewError(domain.NotFound)
	}
	if err != nil {
		return domain.Pairing{}, nil, err
	}
	if approvedAt == nil {
		value.State = domain.PairingPending
	} else {
		value.State = domain.PairingApproved
	}
	return value, keyHash, nil
}

func pairingTag(nonce, publicKey []byte) string {
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
