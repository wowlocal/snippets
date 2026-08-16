package domain

import "errors"

type ErrorCode string

const (
	InvalidRequest         ErrorCode = "invalid_request"
	AuthenticationRequired ErrorCode = "authentication_required"
	ReauthenticationNeeded ErrorCode = "reauthentication_required"
	Forbidden              ErrorCode = "forbidden"
	NotFound               ErrorCode = "not_found"
	Conflict               ErrorCode = "conflict"
	CursorInvalid          ErrorCode = "cursor_invalid"
	DatasetReset           ErrorCode = "dataset_reset"
	IncompatibleVersion    ErrorCode = "incompatible_version"
	PayloadTooLarge        ErrorCode = "payload_too_large"
	QuotaExceeded          ErrorCode = "quota_exceeded"
	RateLimited            ErrorCode = "rate_limited"
	PairingExpired         ErrorCode = "pairing_expired"
	DependencyUnavailable  ErrorCode = "dependency_unavailable"
	InternalError          ErrorCode = "internal_error"
)

type ServiceError struct {
	Code              ErrorCode
	Limit             *int
	RetryAfterSeconds *int
}

func (e *ServiceError) Error() string { return string(e.Code) }

func NewError(code ErrorCode) error { return &ServiceError{Code: code} }

func ErrorWithLimit(code ErrorCode, limit int) error {
	return &ServiceError{Code: code, Limit: &limit}
}

func ErrorWithRetry(code ErrorCode, seconds int) error {
	return &ServiceError{Code: code, RetryAfterSeconds: &seconds}
}

func AsServiceError(err error) *ServiceError {
	var serviceError *ServiceError
	if errors.As(err, &serviceError) {
		return serviceError
	}
	return &ServiceError{Code: InternalError}
}

func Status(code ErrorCode) int {
	switch code {
	case InvalidRequest:
		return 400
	case AuthenticationRequired, ReauthenticationNeeded:
		return 401
	case Forbidden:
		return 403
	case NotFound:
		return 404
	case Conflict, CursorInvalid, DatasetReset:
		return 409
	case PairingExpired:
		return 410
	case PayloadTooLarge:
		return 413
	case IncompatibleVersion:
		return 426
	case QuotaExceeded, RateLimited:
		return 429
	case DependencyUnavailable:
		return 503
	default:
		return 500
	}
}
