package httpapi

import (
	"context"
	"crypto/rand"

	"github.com/google/uuid"
	"github.com/wowlocal/snippets/server/internal/api"
)

func newRequestID() uuid.UUID {
	var value uuid.UUID
	if _, err := rand.Read(value[:]); err != nil {
		panic("operating system random source unavailable")
	}
	value[6] = value[6]&0x0f | 0x40
	value[8] = value[8]&0x3f | 0x80
	return value
}

func revokeError(ctx context.Context, err error) api.RevokeCurrentSessionResponseObject {
	p := problemFrom(ctx, err)
	return api.RevokeCurrentSessiondefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func listError(ctx context.Context, err error) api.ListSpacesResponseObject {
	p := problemFrom(ctx, err)
	return api.ListSpacesdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func createSpaceError(ctx context.Context, err error) api.CreateSpaceResponseObject {
	p := problemFrom(ctx, err)
	return api.CreateSpacedefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func getSpaceError(ctx context.Context, err error) api.GetSpaceResponseObject {
	p := problemFrom(ctx, err)
	return api.GetSpacedefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func changesError(ctx context.Context, err error) api.GetChangesResponseObject {
	p := problemFrom(ctx, err)
	return api.GetChangesdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func submitError(ctx context.Context, err error) api.SubmitRecordsResponseObject {
	p := problemFrom(ctx, err)
	return api.SubmitRecordsdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func getRecoveryError(ctx context.Context, err error) api.GetRecoveryEnvelopeResponseObject {
	p := problemFrom(ctx, err)
	return api.GetRecoveryEnvelopedefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func putRecoveryError(ctx context.Context, err error) api.PutRecoveryEnvelopeResponseObject {
	p := problemFrom(ctx, err)
	return api.PutRecoveryEnvelopedefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func createPairingError(ctx context.Context, err error) api.CreatePairingResponseObject {
	p := problemFrom(ctx, err)
	return api.CreatePairingdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func getPairingError(ctx context.Context, err error) api.GetPairingResponseObject {
	p := problemFrom(ctx, err)
	return api.GetPairingdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func cancelPairingError(ctx context.Context, err error) api.CancelPairingResponseObject {
	p := problemFrom(ctx, err)
	return api.CancelPairingdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func approvePairingError(ctx context.Context, err error) api.ApprovePairingResponseObject {
	p := problemFrom(ctx, err)
	return api.ApprovePairingdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func claimPairingError(ctx context.Context, err error) api.ClaimPairingResponseObject {
	p := problemFrom(ctx, err)
	return api.ClaimPairingdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
