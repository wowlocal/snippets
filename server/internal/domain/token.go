package domain

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"

	"github.com/google/uuid"
)

type CursorKind string

const (
	SnapshotCursor CursorKind = "snapshot"
	DeltaCursor    CursorKind = "delta"
)

type CursorPayload struct {
	Version           int        `json:"version"`
	Kind              CursorKind `json:"kind"`
	ServerInstanceID  uuid.UUID  `json:"serverInstanceId"`
	SpaceID           uuid.UUID  `json:"spaceId"`
	DatasetGeneration uuid.UUID  `json:"datasetGeneration"`
	FeedEpoch         uuid.UUID  `json:"feedEpoch"`
	Sequence          int64      `json:"sequence"`
	SnapshotAfterID   *uuid.UUID `json:"snapshotAfterId"`
	SnapshotHighWater int64      `json:"snapshotHighWater"`
}

type RecordVersionPayload struct {
	Version           int       `json:"version"`
	ServerInstanceID  uuid.UUID `json:"serverInstanceId"`
	SpaceID           uuid.UUID `json:"spaceId"`
	DatasetGeneration uuid.UUID `json:"datasetGeneration"`
	RecordID          uuid.UUID `json:"recordId"`
	Generation        int64     `json:"generation"`
}

type TokenCodec struct{ secret []byte }

func NewTokenCodec(secret []byte) (*TokenCodec, error) {
	if len(secret) < 32 || len(secret) > 64 {
		return nil, NewError(InternalError)
	}
	return &TokenCodec{secret: append([]byte(nil), secret...)}, nil
}

func (c *TokenCodec) Encode(payload any) (string, error) {
	data, err := json.Marshal(payload)
	if err != nil {
		return "", NewError(InternalError)
	}
	mac := hmac.New(sha256.New, c.secret)
	_, _ = mac.Write(data)
	return "v2." + base64.RawURLEncoding.EncodeToString(data) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

func (c *TokenCodec) Decode(token string, destination any) error {
	if len(token) > 4096 {
		return NewError(CursorInvalid)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 || parts[0] != "v2" {
		return NewError(CursorInvalid)
	}
	data, err := base64.RawURLEncoding.Strict().DecodeString(parts[1])
	if err != nil || base64.RawURLEncoding.EncodeToString(data) != parts[1] {
		return NewError(CursorInvalid)
	}
	signature, err := base64.RawURLEncoding.Strict().DecodeString(parts[2])
	if err != nil || base64.RawURLEncoding.EncodeToString(signature) != parts[2] {
		return NewError(CursorInvalid)
	}
	mac := hmac.New(sha256.New, c.secret)
	_, _ = mac.Write(data)
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return NewError(CursorInvalid)
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return NewError(CursorInvalid)
	}
	canonical, err := json.Marshal(destination)
	if err != nil || !ConstantTimeEqual(canonical, data) {
		return NewError(CursorInvalid)
	}
	return nil
}
