package httpapi

import (
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

func revokeError(err error) api.RevokeCurrentSessionResponseObject {
	p := problemFrom(err)
	return api.RevokeCurrentSessiondefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func listError(err error) api.ListSpacesResponseObject {
	p := problemFrom(err)
	return api.ListSpacesdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func createSpaceError(err error) api.CreateSpaceResponseObject {
	p := problemFrom(err)
	return api.CreateSpacedefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func getSpaceError(err error) api.GetSpaceResponseObject {
	p := problemFrom(err)
	return api.GetSpacedefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func changesError(err error) api.GetChangesResponseObject {
	p := problemFrom(err)
	return api.GetChangesdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func submitError(err error) api.SubmitRecordsResponseObject {
	p := problemFrom(err)
	return api.SubmitRecordsdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func getRecoveryError(err error) api.GetRecoveryEnvelopeResponseObject {
	p := problemFrom(err)
	return api.GetRecoveryEnvelopedefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func putRecoveryError(err error) api.PutRecoveryEnvelopeResponseObject {
	p := problemFrom(err)
	return api.PutRecoveryEnvelopedefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func createPairingError(err error) api.CreatePairingResponseObject {
	p := problemFrom(err)
	return api.CreatePairingdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func getPairingError(err error) api.GetPairingResponseObject {
	p := problemFrom(err)
	return api.GetPairingdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func cancelPairingError(err error) api.CancelPairingResponseObject {
	p := problemFrom(err)
	return api.CancelPairingdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func approvePairingError(err error) api.ApprovePairingResponseObject {
	p := problemFrom(err)
	return api.ApprovePairingdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
func claimPairingError(err error) api.ClaimPairingResponseObject {
	p := problemFrom(err)
	return api.ClaimPairingdefaultApplicationProblemPlusJSONResponse{Body: p, StatusCode: p.Status}
}
