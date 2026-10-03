package auth

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/domain"
)

type NativeAccount struct {
	ID string `json:"id"`
}
type NativeTokens struct {
	AccessToken  string        `json:"access_token"`
	RefreshToken string        `json:"refresh_token"`
	ExpiresIn    int           `json:"expires_in"`
	TokenType    string        `json:"token_type"`
	Account      NativeAccount `json:"account"`
}
type NativeAccountCreation struct {
	AccountKey string
	Session    NativeTokens
}
type NativeDeviceRequest struct {
	ID        uuid.UUID
	PollToken string
	ExpiresAt time.Time
}
type NativeDeviceClaim struct {
	Approved  bool
	ExpiresAt time.Time
	SpaceID   uuid.UUID
	PairingID uuid.UUID
	Session   NativeTokens
}
type NativeService interface {
	Validator
	CreateAccount(context.Context, string) (NativeAccountCreation, error)
	SignIn(context.Context, string, string) (NativeTokens, error)
	Refresh(context.Context, string, string) (NativeTokens, error)
	Revoke(context.Context, string, string) error
	CreateDeviceRequest(context.Context, []byte, []byte, string) (NativeDeviceRequest, error)
	ApproveDeviceRequest(context.Context, [32]byte, uuid.UUID, uuid.UUID, uuid.UUID, []byte, []byte) error
	ClaimDeviceRequest(context.Context, uuid.UUID, string, string) (NativeDeviceClaim, error)
}
type Native struct {
	pool          *pgxpool.Pool
	configuration config.NativeAuth
}

func NewNative(pool *pgxpool.Pool, configuration config.NativeAuth) (*Native, error) {
	if pool == nil || len(configuration.Secret) < 32 || len(configuration.IdentityPepper) < 32 {
		return nil, domain.NewError(domain.InternalError)
	}
	return &Native{pool: pool, configuration: configuration}, nil
}
func randomOpaque(prefix string) (string, error) {
	var value [32]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", domain.NewError(domain.InternalError)
	}
	return prefix + base64.RawURLEncoding.EncodeToString(value[:]), nil
}
func (n *Native) digest(label, value string) [32]byte {
	return keyedDigest(n.configuration.Secret, "snippets-native-"+label+"-v1", []byte(value))
}

// Account lookup survives NATIVE_AUTH_SECRET loss: it uses the persistent identity pepper.
func (n *Native) accountKeyDigest(key string) [32]byte {
	return keyedDigest(n.configuration.IdentityPepper, "snippets-native-account-key-v1", []byte(key))
}
func (n *Native) begin(ctx context.Context) (pgx.Tx, error) {
	tx, err := n.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, domain.NewError(domain.DependencyUnavailable)
	}
	return tx, nil
}

// Rate rows are transactionally locked. A denied attempt still commits counters
// already charged in this request, including the shared deployment-wide budget.
func (n *Native) rates(ctx context.Context, tx pgx.Tx, operation, ip string) error {
	entries := [][2]string{{operation + "_global", "global"}, {operation + "_ip", ip}}
	for _, entry := range entries {
		digest := n.digest("rate-"+entry[0], entry[1])
		var retry int
		if err := tx.QueryRow(ctx, "SELECT snippets_private.native_rate($1,$2)", digest[:], entry[0]).Scan(&retry); err != nil {
			return domain.NewError(domain.DependencyUnavailable)
		}
		if retry > 0 {
			if err := tx.Commit(ctx); err != nil {
				return domain.NewError(domain.DependencyUnavailable)
			}
			return domain.ErrorWithRetry(domain.RateLimited, retry)
		}
	}
	return nil
}
func validOpaque(value, prefix string) bool {
	if !strings.HasPrefix(value, prefix) || len(value) != len(prefix)+43 {
		return false
	}
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(strings.TrimPrefix(value, prefix))
	return err == nil && len(decoded) == 32
}
func newNativeTokens() (NativeTokens, error) {
	access, err := randomOpaque("sn_a_")
	if err != nil {
		return NativeTokens{}, err
	}
	refresh, err := randomOpaque("sn_r_")
	if err != nil {
		return NativeTokens{}, err
	}
	return NativeTokens{AccessToken: access, RefreshToken: refresh, ExpiresIn: 300, TokenType: "Bearer"}, nil
}

// A key-digest collision is astronomically unlikely, but the unique index turns one into
// a fresh generation rather than a shared account.
const maximumAccountKeyAttempts = 3

func (n *Native) CreateAccount(ctx context.Context, ip string) (NativeAccountCreation, error) {
	tx, err := n.begin(ctx)
	if err != nil {
		return NativeAccountCreation{}, err
	}
	defer tx.Rollback(ctx)
	if err := n.rates(ctx, tx, "create", ip); err != nil {
		return NativeAccountCreation{}, err
	}
	if _, err := tx.Exec(ctx, "SELECT snippets_private.native_cleanup()"); err != nil {
		return NativeAccountCreation{}, domain.NewError(domain.DependencyUnavailable)
	}
	for attempt := 0; attempt < maximumAccountKeyAttempts; attempt++ {
		key, err := newAccountKey()
		if err != nil {
			return NativeAccountCreation{}, domain.NewError(domain.InternalError)
		}
		result, err := newNativeTokens()
		if err != nil {
			return NativeAccountCreation{}, err
		}
		keyDigest := n.accountKeyDigest(key)
		access, refresh := n.digest("credential", result.AccessToken), n.digest("credential", result.RefreshToken)
		var expires time.Time
		err = tx.QueryRow(ctx, "SELECT id::text,expires_at FROM snippets_private.native_create($1,$2,$3,$4,$5)", uuid.New(), keyDigest[:], uuid.New(), access[:], refresh[:]).Scan(&result.Account.ID, &expires)
		if errors.Is(err, pgx.ErrNoRows) {
			continue
		}
		if err != nil {
			return NativeAccountCreation{}, domain.NewError(domain.DependencyUnavailable)
		}
		if err := tx.Commit(ctx); err != nil {
			return NativeAccountCreation{}, domain.NewError(domain.DependencyUnavailable)
		}
		result.ExpiresIn = tokenLifetime(expires)
		return NativeAccountCreation{AccountKey: key, Session: result}, nil
	}
	return NativeAccountCreation{}, domain.NewError(domain.InternalError)
}
func (n *Native) SignIn(ctx context.Context, key, ip string) (NativeTokens, error) {
	// Malformed keys are refused before they consume a rate budget or reach PostgreSQL.
	if !validAccountKey(key) {
		return NativeTokens{}, domain.NewError(domain.InvalidAccountKey)
	}
	result, err := newNativeTokens()
	if err != nil {
		return NativeTokens{}, err
	}
	tx, err := n.begin(ctx)
	if err != nil {
		return NativeTokens{}, err
	}
	defer tx.Rollback(ctx)
	if err := n.rates(ctx, tx, "sign_in", ip); err != nil {
		return NativeTokens{}, err
	}
	keyDigest := n.accountKeyDigest(key)
	access, refresh := n.digest("credential", result.AccessToken), n.digest("credential", result.RefreshToken)
	var expires time.Time
	err = tx.QueryRow(ctx, "SELECT id::text,expires_at FROM snippets_private.native_sign_in($1,$2,$3,$4)", keyDigest[:], uuid.New(), access[:], refresh[:]).Scan(&result.Account.ID, &expires)
	if errors.Is(err, pgx.ErrNoRows) {
		// Commit the charged rate counters; nothing else changed.
		if err := tx.Commit(ctx); err != nil {
			return NativeTokens{}, domain.NewError(domain.DependencyUnavailable)
		}
		return NativeTokens{}, domain.NewError(domain.InvalidAccountKey)
	}
	if err != nil {
		return NativeTokens{}, domain.NewError(domain.DependencyUnavailable)
	}
	if err := tx.Commit(ctx); err != nil {
		return NativeTokens{}, domain.NewError(domain.DependencyUnavailable)
	}
	result.ExpiresIn = tokenLifetime(expires)
	return result, nil
}
func tokenLifetime(expires time.Time) int {
	seconds := int(time.Until(expires).Seconds())
	if seconds < 1 {
		return 1
	}
	if seconds > 300 {
		return 300
	}
	return seconds
}
func (n *Native) Refresh(ctx context.Context, token, ip string) (NativeTokens, error) {
	if !validOpaque(token, "sn_r_") {
		return NativeTokens{}, domain.NewError(domain.AuthenticationRequired)
	}
	result, err := newNativeTokens()
	if err != nil {
		return NativeTokens{}, err
	}
	tx, err := n.begin(ctx)
	if err != nil {
		return NativeTokens{}, err
	}
	defer tx.Rollback(ctx)
	if err := n.rates(ctx, tx, "refresh", ip); err != nil {
		return NativeTokens{}, err
	}
	digest, access, refresh := n.digest("credential", token), n.digest("credential", result.AccessToken), n.digest("credential", result.RefreshToken)
	var expires time.Time
	err = tx.QueryRow(ctx, "SELECT id::text,expires_at FROM snippets_private.native_refresh($1,$2,$3)", digest[:], access[:], refresh[:]).Scan(&result.Account.ID, &expires)
	if errors.Is(err, pgx.ErrNoRows) {
		// Reuse revokes the family in the same transaction. Do not roll that back.
		if err := tx.Commit(ctx); err != nil {
			return NativeTokens{}, domain.NewError(domain.DependencyUnavailable)
		}
		return NativeTokens{}, domain.NewError(domain.AuthenticationRequired)
	}
	if err != nil {
		return NativeTokens{}, domain.NewError(domain.DependencyUnavailable)
	}
	if err := tx.Commit(ctx); err != nil {
		return NativeTokens{}, domain.NewError(domain.DependencyUnavailable)
	}
	result.ExpiresIn = tokenLifetime(expires)
	return result, nil
}
func (n *Native) Validate(ctx context.Context, token string, requirement Requirement) (domain.Principal, error) {
	if !validOpaque(token, "sn_a_") {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	if requirement != Standard {
		return domain.Principal{}, domain.NewError(domain.ReauthenticationNeeded)
	}
	digest := n.digest("credential", token)
	var accountID string
	var expires, authenticated time.Time
	err := n.pool.QueryRow(ctx, "SELECT id::text,expires_at,authenticated_at FROM snippets_private.native_validate($1)", digest[:]).Scan(&accountID, &expires, &authenticated)
	if errors.Is(err, pgx.ErrNoRows) {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	if err != nil {
		return domain.Principal{}, domain.NewError(domain.DependencyUnavailable)
	}
	identity := keyedDigest(n.configuration.IdentityPepper, "snippets-native-identity-v1", []byte(accountID))
	return domain.Principal{IdentityDigest: identity, CredentialDigest: digest, ExpiresAt: expires, AuthenticatedAt: authenticated, AMR: []string{"account_key"}}, nil
}
func (n *Native) Revoke(ctx context.Context, token, hint string) error {
	if hint != "access_token" && hint != "refresh_token" {
		return domain.NewError(domain.InvalidRequest)
	}
	prefix := "sn_a_"
	if hint == "refresh_token" {
		prefix = "sn_r_"
	}
	if !validOpaque(token, prefix) {
		return nil
	}
	digest := n.digest("credential", token)
	if _, err := n.pool.Exec(ctx, "SELECT snippets_private.native_revoke($1,$2)", digest[:], hint); err != nil {
		return domain.NewError(domain.DependencyUnavailable)
	}
	return nil
}

// Device-approved sign-in (ADR 0007). The recipient key and nonce are the pairing
// recipient material the requesting device will later use to claim the library key.
func (n *Native) CreateDeviceRequest(ctx context.Context, publicKey, nonce []byte, ip string) (NativeDeviceRequest, error) {
	if len(publicKey) != 65 || publicKey[0] != 4 || len(nonce) != 32 {
		return NativeDeviceRequest{}, domain.NewError(domain.InvalidRequest)
	}
	if _, err := ecdh.P256().NewPublicKey(publicKey); err != nil {
		return NativeDeviceRequest{}, domain.NewError(domain.InvalidRequest)
	}
	poll, err := randomOpaque("sn_d_")
	if err != nil {
		return NativeDeviceRequest{}, err
	}
	tx, err := n.begin(ctx)
	if err != nil {
		return NativeDeviceRequest{}, err
	}
	defer tx.Rollback(ctx)
	if err := n.rates(ctx, tx, "device_request", ip); err != nil {
		return NativeDeviceRequest{}, err
	}
	if _, err := tx.Exec(ctx, "SELECT snippets_private.native_cleanup()"); err != nil {
		return NativeDeviceRequest{}, domain.NewError(domain.DependencyUnavailable)
	}
	request := NativeDeviceRequest{ID: uuid.New(), PollToken: poll}
	pollDigest, keyHash := n.digest("device-poll", poll), sha256.Sum256(publicKey)
	if err := tx.QueryRow(ctx, "SELECT snippets_private.native_device_request($1,$2,$3,$4)", request.ID, pollDigest[:], keyHash[:], nonce).Scan(&request.ExpiresAt); err != nil {
		return NativeDeviceRequest{}, domain.NewError(domain.DependencyUnavailable)
	}
	if err := tx.Commit(ctx); err != nil {
		return NativeDeviceRequest{}, domain.NewError(domain.DependencyUnavailable)
	}
	return request, nil
}

// The caller must already have verified, as the approving principal, that the pairing is
// approved in a writable space. The account comes from the approving credential.
func (n *Native) ApproveDeviceRequest(ctx context.Context, credential [32]byte, requestID, spaceID, pairingID uuid.UUID, publicKey, nonce []byte) error {
	keyHash := sha256.Sum256(publicKey)
	var outcome string
	if err := n.pool.QueryRow(ctx, "SELECT snippets_private.native_approve_device($1,$2,$3,$4,$5,$6)", requestID, credential[:], spaceID, pairingID, keyHash[:], nonce).Scan(&outcome); err != nil {
		return domain.NewError(domain.DependencyUnavailable)
	}
	switch outcome {
	case "approved":
		return nil
	case "unauthenticated":
		return domain.NewError(domain.AuthenticationRequired)
	case "not_found":
		return domain.NewError(domain.NotFound)
	case "expired":
		return domain.NewError(domain.PairingExpired)
	default:
		return domain.NewError(domain.Conflict)
	}
}

func (n *Native) ClaimDeviceRequest(ctx context.Context, requestID uuid.UUID, poll, ip string) (NativeDeviceClaim, error) {
	if !validOpaque(poll, "sn_d_") {
		return NativeDeviceClaim{}, domain.NewError(domain.NotFound)
	}
	tokens, err := newNativeTokens()
	if err != nil {
		return NativeDeviceClaim{}, err
	}
	tx, err := n.begin(ctx)
	if err != nil {
		return NativeDeviceClaim{}, err
	}
	defer tx.Rollback(ctx)
	if err := n.rates(ctx, tx, "device_claim", ip); err != nil {
		return NativeDeviceClaim{}, err
	}
	pollDigest := n.digest("device-poll", poll)
	access, refresh := n.digest("credential", tokens.AccessToken), n.digest("credential", tokens.RefreshToken)
	var state string
	var claim NativeDeviceClaim
	var account, space, pairing *uuid.UUID
	var tokenExpires *time.Time
	err = tx.QueryRow(ctx, "SELECT state,request_expires_at,account,space,pairing,token_expires_at FROM snippets_private.native_claim_device($1,$2,$3,$4,$5)", requestID, pollDigest[:], uuid.New(), access[:], refresh[:]).Scan(&state, &claim.ExpiresAt, &account, &space, &pairing, &tokenExpires)
	if errors.Is(err, pgx.ErrNoRows) {
		state = "unknown"
	} else if err != nil {
		return NativeDeviceClaim{}, domain.NewError(domain.DependencyUnavailable)
	}
	// Commit charged rate counters for every outcome, and the issued family on approval.
	if err := tx.Commit(ctx); err != nil {
		return NativeDeviceClaim{}, domain.NewError(domain.DependencyUnavailable)
	}
	switch state {
	case "pending":
		return claim, nil
	case "approved":
		if account == nil || space == nil || pairing == nil || tokenExpires == nil {
			return NativeDeviceClaim{}, domain.NewError(domain.InternalError)
		}
		tokens.Account.ID = account.String()
		tokens.ExpiresIn = tokenLifetime(*tokenExpires)
		claim.Approved, claim.SpaceID, claim.PairingID, claim.Session = true, *space, *pairing, tokens
		return claim, nil
	case "expired":
		return NativeDeviceClaim{}, domain.NewError(domain.PairingExpired)
	case "exhausted":
		return NativeDeviceClaim{}, domain.NewError(domain.Conflict)
	default:
		return NativeDeviceClaim{}, domain.NewError(domain.NotFound)
	}
}

var _ NativeService = (*Native)(nil)

// Maintenance runs independently of sign-in traffic. A client that only refreshes
// sessions must not retain expired authentication records indefinitely.
func (n *Native) RunMaintenance(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		cleanupCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		_, _ = n.pool.Exec(cleanupCtx, "SELECT snippets_private.native_cleanup()")
		cancel()
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
