package httpapi

import (
	"context"
	"net/http"

	"github.com/google/uuid"
	"github.com/wowlocal/snippets/server/internal/api"
	"github.com/wowlocal/snippets/server/internal/auth"
	"github.com/wowlocal/snippets/server/internal/domain"
)

type nativeIPContextKey struct{}

func nativeIP(ctx context.Context) string {
	value, _ := ctx.Value(nativeIPContextKey{}).(string)
	return value
}

type nativeProblem struct{ err error }

func (p nativeProblem) VisitCreateNativeAccountResponse(w http.ResponseWriter) error {
	writeProblem(w, p.err)
	return nil
}
func (p nativeProblem) VisitSignInWithAccountKeyResponse(w http.ResponseWriter) error {
	writeProblem(w, p.err)
	return nil
}
func (p nativeProblem) VisitRefreshNativeSessionResponse(w http.ResponseWriter) error {
	writeProblem(w, p.err)
	return nil
}
func (p nativeProblem) VisitRevokeNativeSessionResponse(w http.ResponseWriter) error {
	writeProblem(w, p.err)
	return nil
}
func (p nativeProblem) VisitCreateDeviceSignInRequestResponse(w http.ResponseWriter) error {
	writeProblem(w, p.err)
	return nil
}
func (p nativeProblem) VisitApproveDeviceSignInRequestResponse(w http.ResponseWriter) error {
	writeProblem(w, p.err)
	return nil
}
func (p nativeProblem) VisitClaimDeviceSignInRequestResponse(w http.ResponseWriter) error {
	writeProblem(w, p.err)
	return nil
}
func (h *Handler) CreateNativeAccount(ctx context.Context, _ api.CreateNativeAccountRequestObject) (api.CreateNativeAccountResponseObject, error) {
	if h.native == nil {
		return nativeProblem{domain.NewError(domain.NotFound)}, nil
	}
	value, err := h.native.CreateAccount(ctx, nativeIP(ctx))
	if err != nil {
		return nativeProblem{err}, nil
	}
	session, err := mapNativeTokens(value.Session)
	if err != nil {
		return nativeProblem{err}, nil
	}
	return api.CreateNativeAccount200JSONResponse{AccountKey: value.AccountKey, Session: session}, nil
}
func (h *Handler) SignInWithAccountKey(ctx context.Context, r api.SignInWithAccountKeyRequestObject) (api.SignInWithAccountKeyResponseObject, error) {
	if h.native == nil {
		return nativeProblem{domain.NewError(domain.NotFound)}, nil
	}
	if r.Body == nil {
		return nativeProblem{domain.NewError(domain.InvalidRequest)}, nil
	}
	value, err := h.native.SignIn(ctx, r.Body.AccountKey, nativeIP(ctx))
	if err != nil {
		return nativeProblem{err}, nil
	}
	session, err := mapNativeTokens(value)
	if err != nil {
		return nativeProblem{err}, nil
	}
	return api.SignInWithAccountKey200JSONResponse(session), nil
}
func (h *Handler) RefreshNativeSession(ctx context.Context, r api.RefreshNativeSessionRequestObject) (api.RefreshNativeSessionResponseObject, error) {
	if h.native == nil {
		return nativeProblem{domain.NewError(domain.NotFound)}, nil
	}
	if r.Body == nil {
		return nativeProblem{domain.NewError(domain.InvalidRequest)}, nil
	}
	value, err := h.native.Refresh(ctx, r.Body.RefreshToken, nativeIP(ctx))
	if err != nil {
		return nativeProblem{err}, nil
	}
	session, err := mapNativeTokens(value)
	if err != nil {
		return nativeProblem{err}, nil
	}
	return api.RefreshNativeSession200JSONResponse(session), nil
}
func (h *Handler) RevokeNativeSession(ctx context.Context, r api.RevokeNativeSessionRequestObject) (api.RevokeNativeSessionResponseObject, error) {
	if h.native == nil {
		return nativeProblem{domain.NewError(domain.NotFound)}, nil
	}
	if r.Body == nil {
		return nativeProblem{domain.NewError(domain.InvalidRequest)}, nil
	}
	if err := h.native.Revoke(ctx, r.Body.Token, string(r.Body.TokenTypeHint)); err != nil {
		return nativeProblem{err}, nil
	}
	return api.RevokeNativeSession204Response{}, nil
}
func (h *Handler) CreateDeviceSignInRequest(ctx context.Context, r api.CreateDeviceSignInRequestRequestObject) (api.CreateDeviceSignInRequestResponseObject, error) {
	if h.native == nil {
		return nativeProblem{domain.NewError(domain.NotFound)}, nil
	}
	if r.Body == nil {
		return nativeProblem{domain.NewError(domain.InvalidRequest)}, nil
	}
	value, err := h.native.CreateDeviceRequest(ctx, r.Body.RecipientPublicKey, r.Body.Nonce, nativeIP(ctx))
	if err != nil {
		return nativeProblem{err}, nil
	}
	return api.CreateDeviceSignInRequest200JSONResponse{RequestId: value.ID, PollToken: value.PollToken, ExpiresAt: value.ExpiresAt.UTC()}, nil
}

// Approval is bound to library-key authority: the caller must hold an approved pairing for
// the request's recipient key, which needed a library-action proof. A bearer token alone
// cannot mint a session for another device.
func (h *Handler) ApproveDeviceSignInRequest(ctx context.Context, r api.ApproveDeviceSignInRequestRequestObject) (api.ApproveDeviceSignInRequestResponseObject, error) {
	if h.native == nil {
		return nativeProblem{domain.NewError(domain.NotFound)}, nil
	}
	principal, err := principalFrom(ctx)
	if err != nil {
		return nativeProblem{err}, nil
	}
	if r.Body == nil {
		return nativeProblem{domain.NewError(domain.InvalidRequest)}, nil
	}
	space, pairing, err := h.store.GetPairing(ctx, principal, r.Body.SpaceId, r.Body.PairingId)
	if err != nil {
		return nativeProblem{err}, nil
	}
	if !space.Role.CanWrite() {
		return nativeProblem{domain.NewError(domain.Forbidden)}, nil
	}
	if pairing.State != domain.PairingApproved {
		return nativeProblem{domain.NewError(domain.Conflict)}, nil
	}
	if err := h.native.ApproveDeviceRequest(ctx, principal.CredentialDigest, r.DeviceRequest, r.Body.SpaceId, r.Body.PairingId, pairing.RecipientPublicKey, pairing.Nonce); err != nil {
		return nativeProblem{err}, nil
	}
	return api.ApproveDeviceSignInRequest204Response{}, nil
}
func (h *Handler) ClaimDeviceSignInRequest(ctx context.Context, r api.ClaimDeviceSignInRequestRequestObject) (api.ClaimDeviceSignInRequestResponseObject, error) {
	if h.native == nil {
		return nativeProblem{domain.NewError(domain.NotFound)}, nil
	}
	if r.Body == nil {
		return nativeProblem{domain.NewError(domain.InvalidRequest)}, nil
	}
	value, err := h.native.ClaimDeviceRequest(ctx, r.DeviceRequest, r.Body.PollToken, nativeIP(ctx))
	if err != nil {
		return nativeProblem{err}, nil
	}
	result := api.ClaimDeviceSignInRequest200JSONResponse{State: api.DeviceSignInClaimStatePending, ExpiresAt: value.ExpiresAt.UTC()}
	if value.Approved {
		session, err := mapNativeTokens(value.Session)
		if err != nil {
			return nativeProblem{err}, nil
		}
		result.State, result.SpaceId, result.PairingId, result.Session = api.DeviceSignInClaimStateApproved, &value.SpaceID, &value.PairingID, &session
	}
	return result, nil
}
func mapNativeTokens(value auth.NativeTokens) (api.NativeTokenResponse, error) {
	account, err := uuid.Parse(value.Account.ID)
	if err != nil {
		return api.NativeTokenResponse{}, domain.NewError(domain.InternalError)
	}
	return api.NativeTokenResponse{AccessToken: value.AccessToken, RefreshToken: value.RefreshToken, ExpiresIn: value.ExpiresIn, TokenType: api.Bearer, Account: api.NativeAccount{Id: account}}, nil
}
