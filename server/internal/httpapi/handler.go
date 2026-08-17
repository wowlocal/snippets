package httpapi

import (
	"context"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/wowlocal/snippets/server/internal/api"
	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/domain"
)

type principalContextKey struct{}

func withPrincipal(ctx context.Context, principal domain.Principal) context.Context {
	return context.WithValue(ctx, principalContextKey{}, principal)
}

func principalFrom(ctx context.Context) (domain.Principal, error) {
	principal, ok := ctx.Value(principalContextKey{}).(domain.Principal)
	if !ok {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	return principal, nil
}

type Handler struct {
	configuration config.Server
	store         domain.Store
}

func NewHandler(configuration config.Server, store domain.Store) *Handler {
	return &Handler{configuration: configuration, store: store}
}

func (h *Handler) GetDiscovery(context.Context, api.GetDiscoveryRequestObject) (api.GetDiscoveryResponseObject, error) {
	amr := setValues(h.configuration.OIDC.StepUpAMR)
	acr := setValues(h.configuration.OIDC.StepUpACR)
	capabilities := []string{"account-without-required-email", "offline-recovery-v1", "oauth-refresh-token-rotation", "oauth-resource-indicators", "oauth-token-revocation", "oidc-pkce", "pairing-v2", "phishing-resistant-step-up", "resource-session-revocation"}
	return api.GetDiscovery200JSONResponse{
		ProtocolMajor: api.N2, ProtocolMinor: api.N0, ServerVersion: h.configuration.ServerVersion,
		ServerInstanceId: h.configuration.ServerInstanceID, ApiBase: h.configuration.PublicBaseURL.String() + "/v2",
		RecordProfile: api.SnippetsWireV1, Capabilities: capabilities,
		Limits: api.Limits{MaxBlobBytes: 900000, MaxRevisionBytes: 256, MaxBatchRecords: 50, MaxPageRecords: 50, MaxRequestBytes: 16777216, MaxResponseBytes: 67108864, MaxKeyEnvelopeBytes: 4096, MaxPairingSeconds: 600},
		Oidc:   api.OIDCDiscovery{Issuer: h.configuration.OIDC.Issuer.String(), Resource: h.configuration.PublicBaseURL.String(), ClientId: h.configuration.OIDC.ClientID, Scopes: append([]string(nil), h.configuration.OIDC.Scopes...), AuthorizationFlow: api.AuthorizationCodePkce, MaxAccessTokenAgeSeconds: int(h.configuration.OIDC.MaximumTokenAge / time.Second), StepUpMaxAgeSeconds: int(h.configuration.OIDC.StepUpMaximumAge / time.Second), StepUpAMRValues: amr, StepUpACRValues: acr},
	}, nil
}

func (h *Handler) GetLiveness(context.Context, api.GetLivenessRequestObject) (api.GetLivenessResponseObject, error) {
	return api.GetLiveness200JSONResponse{Status: api.Ok}, nil
}

func (h *Handler) GetReadiness(ctx context.Context, _ api.GetReadinessRequestObject) (api.GetReadinessResponseObject, error) {
	readyCtx, cancel := context.WithTimeout(ctx, h.configuration.HTTP.ReadinessTimeout)
	defer cancel()
	if err := h.store.Readiness(readyCtx); err != nil {
		problem := problemFrom(domain.NewError(domain.DependencyUnavailable))
		return api.GetReadiness503ApplicationProblemPlusJSONResponse{ServiceUnavailableApplicationProblemPlusJSONResponse: api.ServiceUnavailableApplicationProblemPlusJSONResponse(problem)}, nil
	}
	return api.GetReadiness200JSONResponse{Status: api.Ok}, nil
}

func (h *Handler) RevokeCurrentSession(ctx context.Context, _ api.RevokeCurrentSessionRequestObject) (api.RevokeCurrentSessionResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return revokeError(err), nil
	}
	if err := h.store.RevokeAccessToken(ctx, principal); err != nil {
		return revokeError(err), nil
	}
	return api.RevokeCurrentSession204Response{}, nil
}

func (h *Handler) ListSpaces(ctx context.Context, _ api.ListSpacesRequestObject) (api.ListSpacesResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return listError(err), nil
	}
	spaces, err := h.store.ListSpaces(ctx, principal)
	if err != nil {
		return listError(err), nil
	}
	result := make([]api.Space, len(spaces))
	for i, value := range spaces {
		result[i] = mapSpace(value, h.configuration.ServerInstanceID)
	}
	return api.ListSpaces200JSONResponse{Spaces: result}, nil
}

func (h *Handler) CreateSpace(ctx context.Context, request api.CreateSpaceRequestObject) (api.CreateSpaceResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return createSpaceError(err), nil
	}
	space, err := h.store.CreateSpace(ctx, principal, request.Params.IdempotencyKey)
	if err != nil {
		return createSpaceError(err), nil
	}
	return api.CreateSpace201JSONResponse(mapSpace(space, h.configuration.ServerInstanceID)), nil
}

func (h *Handler) GetSpace(ctx context.Context, request api.GetSpaceRequestObject) (api.GetSpaceResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return getSpaceError(err), nil
	}
	space, err := h.store.GetSpace(ctx, principal, request.Space)
	if err != nil {
		return getSpaceError(err), nil
	}
	return api.GetSpace200JSONResponse(mapSpace(space, h.configuration.ServerInstanceID)), nil
}

func (h *Handler) GetChanges(ctx context.Context, request api.GetChangesRequestObject) (api.GetChangesResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return changesError(err), nil
	}
	limit := domain.MaxPageRecords
	if request.Params.Limit != nil {
		limit = *request.Params.Limit
	}
	page, err := h.store.FetchChanges(ctx, principal, request.Space, request.Params.Cursor, limit)
	if err != nil {
		return changesError(err), nil
	}
	records := make([]api.ServerRecord, len(page.Records))
	for i, value := range page.Records {
		records[i] = mapServerRecord(value)
	}
	return api.GetChanges200JSONResponse{Scope: mapScope(page.Scope, h.configuration.ServerInstanceID), Records: records, Cursor: page.Cursor, HasMore: page.HasMore, FullSnapshot: page.FullSnapshot}, nil
}

func (h *Handler) SubmitRecords(ctx context.Context, request api.SubmitRecordsRequestObject) (api.SubmitRecordsResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return submitError(err), nil
	}
	if request.Body == nil {
		return submitError(domain.NewError(domain.InvalidRequest)), nil
	}
	if request.Body.ExpectedScope.ServerInstanceId != h.configuration.ServerInstanceID {
		return submitError(domain.NewError(domain.Forbidden)), nil
	}
	items := make([]domain.BatchItem, len(request.Body.Items))
	for i, value := range request.Body.Items {
		items[i] = domain.BatchItem{Record: domain.WireRecord{ID: value.Record.Id, Rev: value.Record.Rev, Deleted: value.Record.Deleted, Blob: append([]byte(nil), value.Record.Blob...)}, ExpectedRecordVersion: value.ExpectedRecordVersion}
	}
	expectedScope := domain.Scope{
		SpaceID:           request.Body.ExpectedScope.SpaceId,
		ScopeBinding:      request.Body.ExpectedScope.ScopeBinding,
		DatasetGeneration: request.Body.ExpectedScope.DatasetGeneration,
		FeedEpoch:         request.Body.ExpectedScope.FeedEpoch,
	}
	submission, err := h.store.Submit(ctx, principal, request.Space, expectedScope, items)
	if err != nil {
		return submitError(err), nil
	}
	outcomes := make([]api.BatchOutcome, len(submission.Outcomes))
	for i, value := range submission.Outcomes {
		outcomes[i] = mapOutcome(value)
	}
	return api.SubmitRecords200JSONResponse{Scope: mapScope(submission.Scope, h.configuration.ServerInstanceID), Outcomes: outcomes, Partial: submission.Partial}, nil
}

func (h *Handler) GetRecoveryEnvelope(ctx context.Context, request api.GetRecoveryEnvelopeRequestObject) (api.GetRecoveryEnvelopeResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return getRecoveryError(err), nil
	}
	space, envelope, err := h.store.GetRecoveryEnvelope(ctx, principal, request.Space)
	if err != nil {
		return getRecoveryError(err), nil
	}
	return api.GetRecoveryEnvelope200JSONResponse(mapRecoveryResponse(space, envelope, h.configuration.ServerInstanceID)), nil
}

func (h *Handler) PutRecoveryEnvelope(ctx context.Context, request api.PutRecoveryEnvelopeRequestObject) (api.PutRecoveryEnvelopeResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return putRecoveryError(err), nil
	}
	if request.Body == nil {
		return putRecoveryError(domain.NewError(domain.InvalidRequest)), nil
	}
	space, envelope, err := h.store.PutRecoveryEnvelope(ctx, principal, request.Space, domain.PutRecoveryEnvelope{ExpectedVersion: request.Body.ExpectedVersion, KeyEpoch: request.Body.KeyEpoch, Algorithm: string(request.Body.Algorithm), Ciphertext: append([]byte(nil), request.Body.Ciphertext...)})
	if err != nil {
		return putRecoveryError(err), nil
	}
	return api.PutRecoveryEnvelope200JSONResponse(mapRecoveryResponse(space, &envelope, h.configuration.ServerInstanceID)), nil
}

func (h *Handler) CreatePairing(ctx context.Context, request api.CreatePairingRequestObject) (api.CreatePairingResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return createPairingError(err), nil
	}
	if request.Body == nil {
		return createPairingError(domain.NewError(domain.InvalidRequest)), nil
	}
	space, pairing, err := h.store.CreatePairing(ctx, principal, request.Space, domain.CreatePairing{RecipientPublicKey: append([]byte(nil), request.Body.RecipientPublicKey...), Nonce: append([]byte(nil), request.Body.Nonce...), ExpiresInSeconds: request.Body.ExpiresInSeconds})
	if err != nil {
		return createPairingError(err), nil
	}
	return api.CreatePairing201JSONResponse{Scope: mapScope(space.Scope, h.configuration.ServerInstanceID), Pairing: mapPairing(pairing)}, nil
}

func (h *Handler) GetPairing(ctx context.Context, request api.GetPairingRequestObject) (api.GetPairingResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return getPairingError(err), nil
	}
	space, pairing, err := h.store.GetPairing(ctx, principal, request.Space, request.Pairing)
	if err != nil {
		return getPairingError(err), nil
	}
	return api.GetPairing200JSONResponse{Scope: mapScope(space.Scope, h.configuration.ServerInstanceID), Pairing: mapPairing(pairing)}, nil
}

func (h *Handler) CancelPairing(ctx context.Context, request api.CancelPairingRequestObject) (api.CancelPairingResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return cancelPairingError(err), nil
	}
	if err := h.store.CancelPairing(ctx, principal, request.Space, request.Pairing); err != nil {
		return cancelPairingError(err), nil
	}
	return api.CancelPairing204Response{}, nil
}

func (h *Handler) ApprovePairing(ctx context.Context, request api.ApprovePairingRequestObject) (api.ApprovePairingResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return approvePairingError(err), nil
	}
	if request.Body == nil {
		return approvePairingError(domain.NewError(domain.InvalidRequest)), nil
	}
	space, pairing, err := h.store.ApprovePairing(ctx, principal, request.Space, request.Pairing, domain.ApprovePairing{RecipientKeyHash: append([]byte(nil), request.Body.RecipientKeyHash...), Algorithm: string(request.Body.Algorithm), Ciphertext: append([]byte(nil), request.Body.Ciphertext...)})
	if err != nil {
		return approvePairingError(err), nil
	}
	return api.ApprovePairing200JSONResponse{Scope: mapScope(space.Scope, h.configuration.ServerInstanceID), Pairing: mapPairing(pairing)}, nil
}

func (h *Handler) ClaimPairing(ctx context.Context, request api.ClaimPairingRequestObject) (api.ClaimPairingResponseObject, error) {
	principal, err := principalFrom(ctx)
	if err != nil {
		return claimPairingError(err), nil
	}
	space, pairing, err := h.store.ClaimPairing(ctx, principal, request.Space, request.Pairing)
	if err != nil {
		return claimPairingError(err), nil
	}
	if pairing.Algorithm == nil {
		return claimPairingError(domain.NewError(domain.InternalError)), nil
	}
	return api.ClaimPairing200JSONResponse{Scope: mapScope(space.Scope, h.configuration.ServerInstanceID), PairingId: pairing.ID, Algorithm: api.ClaimPairingResponseAlgorithm(*pairing.Algorithm), Ciphertext: append([]byte(nil), pairing.Ciphertext...)}, nil
}

func mapScope(value domain.Scope, serverInstanceID uuid.UUID) api.Scope {
	return api.Scope{ServerInstanceId: serverInstanceID, SpaceId: value.SpaceID, ScopeBinding: value.ScopeBinding, DatasetGeneration: value.DatasetGeneration, FeedEpoch: value.FeedEpoch}
}
func mapSpace(value domain.Space, serverInstanceID uuid.UUID) api.Space {
	return api.Space{Scope: mapScope(value.Scope, serverInstanceID), Role: api.SpaceRole(value.Role), KeyEpoch: value.KeyEpoch}
}
func mapServerRecord(value domain.ServerRecord) api.ServerRecord {
	return api.ServerRecord{Id: value.Record.ID, Rev: value.Record.Rev, Deleted: value.Record.Deleted, Blob: append([]byte(nil), value.Record.Blob...), RecordVersion: value.RecordVersion}
}
func mapOutcome(value domain.BatchOutcome) api.BatchOutcome {
	result := api.BatchOutcome{Kind: api.BatchOutcomeKind(value.Kind), RecordVersion: value.RecordVersion, Revision: value.Revision, RetryAfterSeconds: value.RetryAfterSeconds}
	if value.ErrorCode != nil {
		code := api.ErrorCode(*value.ErrorCode)
		result.ErrorCode = &code
	}
	if value.AuthoritativeRecord != nil {
		record := mapServerRecord(*value.AuthoritativeRecord)
		result.AuthoritativeRecord = &record
	}
	return result
}
func mapRecoveryResponse(space domain.Space, value *domain.RecoveryEnvelope, serverInstanceID uuid.UUID) api.RecoveryEnvelopeResponse {
	result := api.RecoveryEnvelopeResponse{Scope: mapScope(space.Scope, serverInstanceID), KeyEpoch: space.KeyEpoch}
	if value != nil {
		result.Recovery = &api.RecoveryEnvelope{Purpose: api.Recovery, Version: value.Version, KeyEpoch: value.KeyEpoch, Algorithm: api.RecoveryEnvelopeAlgorithm(value.Algorithm), Ciphertext: append([]byte(nil), value.Ciphertext...), CreatedAt: value.CreatedAt}
	}
	return result
}
func mapPairing(value domain.Pairing) api.Pairing {
	// Approval and polling responses reveal state but not any part of the sealed
	// envelope. The atomic claim response is the only release boundary.
	return api.Pairing{PairingId: value.ID, RecipientPublicKey: append([]byte(nil), value.RecipientPublicKey...), Nonce: append([]byte(nil), value.Nonce...), AuthenticationTag: value.AuthenticationTag, State: api.PairingState(value.State), ExpiresAt: value.ExpiresAt}
}

func problemFrom(err error) api.Problem {
	value := domain.AsServiceError(err)
	status := domain.Status(value.Code)
	return api.Problem{Type: "urn:snippets:error:" + string(value.Code), Status: status, Code: api.ErrorCode(value.Code), RequestId: newRequestID(), RetryAfterSeconds: value.RetryAfterSeconds, Limit: value.Limit}
}
func setValues(values map[string]struct{}) []string {
	result := make([]string, 0, len(values))
	for value := range values {
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}
