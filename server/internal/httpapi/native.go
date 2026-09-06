package httpapi

import (
	"context"
	"net/http"

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

func (p nativeProblem) VisitStartEmailAuthenticationResponse(w http.ResponseWriter) error {
	writeProblem(w, p.err)
	return nil
}
func (p nativeProblem) VisitVerifyEmailAuthenticationResponse(w http.ResponseWriter) error {
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
func (h *Handler) StartEmailAuthentication(ctx context.Context, r api.StartEmailAuthenticationRequestObject) (api.StartEmailAuthenticationResponseObject, error) {
	if h.native == nil {
		return nativeProblem{domain.NewError(domain.NotFound)}, nil
	}
	if r.Body == nil {
		return nativeProblem{domain.NewError(domain.InvalidRequest)}, nil
	}
	value, err := h.native.Start(ctx, r.Body.Email, nativeIP(ctx))
	if err != nil {
		return nativeProblem{err}, nil
	}
	return api.StartEmailAuthentication200JSONResponse{ChallengeId: value.ChallengeID, ExpiresIn: api.EmailChallengeExpiresIn(value.ExpiresIn), ResendAfter: api.EmailChallengeResendAfter(value.ResendAfter), CodeLength: api.EmailChallengeCodeLength(value.CodeLength)}, nil
}
func (h *Handler) VerifyEmailAuthentication(ctx context.Context, r api.VerifyEmailAuthenticationRequestObject) (api.VerifyEmailAuthenticationResponseObject, error) {
	if h.native == nil {
		return nativeProblem{domain.NewError(domain.NotFound)}, nil
	}
	if r.Body == nil {
		return nativeProblem{domain.NewError(domain.InvalidRequest)}, nil
	}
	value, err := h.native.Verify(ctx, r.Body.ChallengeId, r.Body.Code, nativeIP(ctx))
	if err != nil {
		return nativeProblem{err}, nil
	}
	return api.VerifyEmailAuthentication200JSONResponse(mapNativeTokens(value)), nil
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
	return api.RefreshNativeSession200JSONResponse(mapNativeTokens(value)), nil
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
func mapNativeTokens(value auth.NativeTokens) api.NativeTokenResponse {
	return api.NativeTokenResponse{AccessToken: value.AccessToken, RefreshToken: value.RefreshToken, ExpiresIn: value.ExpiresIn, TokenType: api.Bearer, Account: api.NativeAccount{Id: value.Account.ID, Email: value.Account.Email}}
}
