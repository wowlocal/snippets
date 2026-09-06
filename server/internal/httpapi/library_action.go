package httpapi

import (
	"context"
	"github.com/google/uuid"
	"github.com/wowlocal/snippets/server/internal/api"
	"github.com/wowlocal/snippets/server/internal/domain"
)

func mapProof(value *api.LibraryActionProof) *domain.LibraryActionProof {
	if value == nil {
		return nil
	}
	return &domain.LibraryActionProof{ChallengeID: value.ChallengeId, Signature: value.Signature}
}

func (h *Handler) expectedScope(value api.Scope, id uuid.UUID) (domain.Scope, error) {
	if value.ServerInstanceId != h.configuration.ServerInstanceID || value.SpaceId != id {
		return domain.Scope{}, domain.NewError(domain.Forbidden)
	}
	return domain.Scope{SpaceID: value.SpaceId, ScopeBinding: value.ScopeBinding, DatasetGeneration: value.DatasetGeneration, FeedEpoch: value.FeedEpoch}, nil
}

func (h *Handler) GetKeyAuthority(ctx context.Context, r api.GetKeyAuthorityRequestObject) (api.GetKeyAuthorityResponseObject, error) {
	p, err := principalFrom(ctx)
	var space domain.Space
	var key []byte
	if err == nil {
		space, key, err = h.store.GetKeyAuthority(ctx, p, r.Space)
	}
	if err != nil {
		problem := problemFrom(ctx, err)
		return api.GetKeyAuthoritydefaultApplicationProblemPlusJSONResponse{Body: problem, StatusCode: problem.Status}, nil
	}
	return api.GetKeyAuthority200JSONResponse{Scope: mapScope(space.Scope, h.configuration.ServerInstanceID), KeyEpoch: space.KeyEpoch, PublicKey: nullablePublicKey(key)}, nil
}

func (h *Handler) BootstrapLibraryKey(ctx context.Context, r api.BootstrapLibraryKeyRequestObject) (api.BootstrapLibraryKeyResponseObject, error) {
	p, err := principalFrom(ctx)
	var space domain.Space
	var envelope domain.RecoveryEnvelope
	if r.Body == nil {
		err = domain.NewError(domain.InvalidRequest)
	}
	if err == nil {
		var scope domain.Scope
		scope, err = h.expectedScope(r.Body.ExpectedScope, r.Space)
		if err == nil {
			v := r.Body.Recovery
			space, envelope, err = h.store.BootstrapLibraryKey(ctx, p, r.Space, domain.KeyBootstrap{ExpectedScope: scope, PublicKey: r.Body.PublicKey, Recovery: domain.PutRecoveryEnvelope{ExpectedVersion: v.ExpectedVersion, KeyEpoch: v.KeyEpoch, Algorithm: string(v.Algorithm), Ciphertext: v.Ciphertext, Proof: mapProof(v.Proof)}})
		}
	}
	if err != nil {
		problem := problemFrom(ctx, err)
		return api.BootstrapLibraryKeydefaultApplicationProblemPlusJSONResponse{Body: problem, StatusCode: problem.Status}, nil
	}
	return api.BootstrapLibraryKey200JSONResponse(mapRecoveryResponse(space, &envelope, h.configuration.ServerInstanceID)), nil
}

func (h *Handler) CreateLibraryChallenge(ctx context.Context, r api.CreateLibraryChallengeRequestObject) (api.CreateLibraryChallengeResponseObject, error) {
	p, err := principalFrom(ctx)
	var space domain.Space
	var c domain.LibraryChallenge
	if r.Body == nil {
		err = domain.NewError(domain.InvalidRequest)
	}
	if err == nil {
		var scope domain.Scope
		scope, err = h.expectedScope(r.Body.ExpectedScope, r.Space)
		if err == nil {
			space, c, err = h.store.CreateLibraryChallenge(ctx, p, r.Space, domain.CreateLibraryChallenge{ExpectedScope: scope, Action: domain.LibraryAction(r.Body.Action), KeyEpoch: r.Body.KeyEpoch, RequestHash: r.Body.RequestHash})
		}
	}
	if err != nil {
		problem := problemFrom(ctx, err)
		return api.CreateLibraryChallengedefaultApplicationProblemPlusJSONResponse{Body: problem, StatusCode: problem.Status}, nil
	}
	return api.CreateLibraryChallenge200JSONResponse{Scope: mapScope(space.Scope, h.configuration.ServerInstanceID), Challenge: api.LibraryChallenge{ChallengeId: c.ID, Action: api.LibraryChallengeAction(c.Action), KeyEpoch: c.KeyEpoch, RequestHash: c.RequestHash, Nonce: c.Nonce, ExpiresAt: c.ExpiresAt}}, nil
}

func nullablePublicKey(key []byte) *[]byte {
	if len(key) == 0 {
		return nil
	}
	return &key
}
