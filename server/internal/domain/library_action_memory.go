package domain

import (
	"context"
	"crypto/ed25519"
	"github.com/google/uuid"
)

func (s *MemoryStore) GetKeyAuthority(_ context.Context, p Principal, id uuid.UUID) (Space, []byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, member, err := s.authorized(p, id)
	if err != nil {
		return Space{}, nil, err
	}
	return descriptor(id, state, member), append([]byte(nil), state.authority...), nil
}

func (s *MemoryStore) BootstrapLibraryKey(_ context.Context, p Principal, id uuid.UUID, r KeyBootstrap) (Space, RecoveryEnvelope, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, member, err := s.authorized(p, id)
	if err != nil {
		return Space{}, RecoveryEnvelope{}, err
	}
	space := descriptor(id, state, member)
	if err := r.ExpectedScope.RequireCurrentMutationScope(space.Scope); err != nil {
		return Space{}, RecoveryEnvelope{}, err
	}
	if member.role != Owner {
		return Space{}, RecoveryEnvelope{}, NewError(Forbidden)
	}
	if len(r.PublicKey) != ed25519.PublicKeySize || r.Recovery.ExpectedVersion != nil || r.Recovery.Proof != nil {
		return Space{}, RecoveryEnvelope{}, NewError(InvalidRequest)
	}
	if err := r.Recovery.Validate(); err != nil {
		return Space{}, RecoveryEnvelope{}, err
	}
	if r.Recovery.KeyEpoch != state.keyEpoch {
		return Space{}, RecoveryEnvelope{}, NewError(Conflict)
	}
	if len(state.authority) != 0 || state.recovery != nil || len(state.records) != 0 || len(state.changes) != 0 {
		return Space{}, RecoveryEnvelope{}, NewError(Conflict)
	}
	envelope := RecoveryEnvelope{Version: 1, KeyEpoch: state.keyEpoch, Algorithm: r.Recovery.Algorithm, Ciphertext: append([]byte(nil), r.Recovery.Ciphertext...), CreatedAt: s.now().UTC()}
	state.authority = append([]byte(nil), r.PublicKey...)
	state.recovery = &envelope
	return space, envelope, nil
}

func (s *MemoryStore) CreateLibraryChallenge(_ context.Context, p Principal, id uuid.UUID, r CreateLibraryChallenge) (Space, LibraryChallenge, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, member, err := s.authorized(p, id)
	if err != nil {
		return Space{}, LibraryChallenge{}, err
	}
	space := descriptor(id, state, member)
	if err := r.Validate(); err != nil {
		return Space{}, LibraryChallenge{}, err
	}
	if err := r.ExpectedScope.RequireCurrentMutationScope(space.Scope); err != nil {
		return Space{}, LibraryChallenge{}, err
	}
	if !member.role.CanWrite() || (r.Action == ReplaceRecovery && member.role != Owner) {
		return Space{}, LibraryChallenge{}, NewError(Forbidden)
	}
	if len(state.authority) == 0 {
		return Space{}, LibraryChallenge{}, NewError(IncompatibleVersion)
	}
	if r.KeyEpoch != state.keyEpoch {
		return Space{}, LibraryChallenge{}, NewError(Conflict)
	}
	if state.challenges == nil {
		state.challenges = make(map[uuid.UUID]*memoryLibraryChallenge)
	}
	for id, value := range state.challenges {
		if !value.value.ExpiresAt.After(s.now()) {
			delete(state.challenges, id)
		}
	}
	if len(state.challenges) >= MaxLibraryChallenges {
		return Space{}, LibraryChallenge{}, ErrorWithRetry(RateLimited, 60)
	}
	challenge, err := NewLibraryChallenge(r, s.now())
	if err != nil {
		return Space{}, LibraryChallenge{}, err
	}
	state.challenges[challenge.ID] = &memoryLibraryChallenge{value: challenge, identity: p.IdentityDigest, scope: space.Scope}
	return space, challenge, nil
}

func (s *MemoryStore) checkLibraryAction(state *memorySpace, member memoryMembership, p Principal, id uuid.UUID, proof *LibraryActionProof, action LibraryAction, hash []byte) (*memoryLibraryChallenge, error) {
	if len(state.authority) == 0 {
		return nil, NewError(IncompatibleVersion)
	}
	if proof == nil {
		return nil, NewError(IncompatibleVersion)
	}
	c := state.challenges[proof.ChallengeID]
	if c == nil || c.identity != p.IdentityDigest {
		return nil, NewError(Forbidden)
	}
	if err := c.scope.RequireCurrentMutationScope(descriptor(id, state, member).Scope); err != nil {
		return nil, err
	}
	if err := c.value.Verify(state.authority, proof, action, state.keyEpoch, hash, s.now()); err != nil {
		return nil, err
	}
	return c, nil
}
