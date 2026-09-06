package auth

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"math/big"
	"net/mail"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/domain"
)

type NativeChallenge struct {
	ChallengeID string `json:"challengeId"`
	ExpiresIn   int    `json:"expiresIn"`
	ResendAfter int    `json:"resendAfter"`
	CodeLength  int    `json:"codeLength"`
}
type NativeAccount struct {
	ID    string `json:"id"`
	Email string `json:"email"`
}
type NativeTokens struct {
	AccessToken  string        `json:"access_token"`
	RefreshToken string        `json:"refresh_token"`
	ExpiresIn    int           `json:"expires_in"`
	TokenType    string        `json:"token_type"`
	Account      NativeAccount `json:"account"`
}
type NativeService interface {
	Validator
	Start(context.Context, string, string) (NativeChallenge, error)
	Verify(context.Context, string, string, string) (NativeTokens, error)
	Refresh(context.Context, string, string) (NativeTokens, error)
	Revoke(context.Context, string, string) error
}
type Native struct {
	pool          *pgxpool.Pool
	configuration config.NativeAuth
	sender        CodeSender
}

func NewNative(pool *pgxpool.Pool, configuration config.NativeAuth, sender CodeSender) (*Native, error) {
	if pool == nil || len(configuration.Secret) < 32 || len(configuration.IdentityPepper) < 32 || sender == nil {
		return nil, domain.NewError(domain.InternalError)
	}
	return &Native{pool: pool, configuration: configuration, sender: sender}, nil
}
func NormalizeEmail(raw string) (string, error) {
	value := strings.ToLower(strings.TrimSpace(raw))
	if len(value) == 0 || len(value) > 254 || strings.ContainsAny(value, "\r\n\x00") {
		return "", domain.NewError(domain.InvalidEmail)
	}
	for _, c := range value {
		if c > 126 || c < 33 {
			return "", domain.NewError(domain.InvalidEmail)
		}
	}
	parsed, err := mail.ParseAddress(value)
	parts := strings.Split(value, "@")
	if err != nil || parsed.Address != value || parsed.Name != "" || len(parts) != 2 || len(parts[0]) > 64 || strings.ContainsAny(parts[0], "\"\\") || !strings.Contains(parts[1], ".") {
		return "", domain.NewError(domain.InvalidEmail)
	}
	for _, label := range strings.Split(parts[1], ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return "", domain.NewError(domain.InvalidEmail)
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') && c != '-' {
				return "", domain.NewError(domain.InvalidEmail)
			}
		}
	}
	return value, nil
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
func (n *Native) codeDigest(challenge, code string) [32]byte {
	return keyedDigest(n.configuration.Secret, "snippets-native-email-code-v1", []byte(challenge), []byte(code))
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
func (n *Native) rates(ctx context.Context, tx pgx.Tx, operation, ip, email string) error {
	entries := [][2]string{{operation + "_global", "global"}, {operation + "_ip", ip}}
	if operation == "start" {
		entries = append(entries, [2]string{"start_email_cooldown", email}, [2]string{"start_email_hour", email}, [2]string{"start_email_day", email})
	}
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
func (n *Native) Start(ctx context.Context, email, ip string) (NativeChallenge, error) {
	email, err := NormalizeEmail(email)
	if err != nil {
		return NativeChallenge{}, err
	}
	challenge, err := randomOpaque("sn_c_")
	if err != nil {
		return NativeChallenge{}, err
	}
	number, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return NativeChallenge{}, domain.NewError(domain.InternalError)
	}
	code := fmt.Sprintf("%06d", number.Int64())
	digest := n.digest("challenge", challenge)
	emailDigest := keyedDigest(n.configuration.IdentityPepper, "snippets-native-email-identity-v1", []byte(email))
	codeDigest := n.codeDigest(challenge, code)
	tx, err := n.begin(ctx)
	if err != nil {
		return NativeChallenge{}, err
	}
	defer tx.Rollback(ctx)
	if err := n.rates(ctx, tx, "start", ip, email); err != nil {
		return NativeChallenge{}, err
	}
	if _, err := tx.Exec(ctx, "SELECT snippets_private.native_cleanup()"); err != nil {
		return NativeChallenge{}, domain.NewError(domain.DependencyUnavailable)
	}
	if _, err := tx.Exec(ctx, "SELECT snippets_private.native_start($1,$2,$3,$4)", digest[:], emailDigest[:], email, codeDigest[:]); err != nil {
		return NativeChallenge{}, domain.NewError(domain.DependencyUnavailable)
	}
	if err := tx.Commit(ctx); err != nil {
		return NativeChallenge{}, domain.NewError(domain.DependencyUnavailable)
	}
	if err := n.sender.SendCode(ctx, email, code); err != nil {
		cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
		defer cancel()
		_, _ = n.pool.Exec(cleanupCtx, "SELECT snippets_private.native_drop_challenge($1)", digest[:])
		return NativeChallenge{}, domain.NewError(domain.DependencyUnavailable)
	}
	return NativeChallenge{ChallengeID: challenge, ExpiresIn: 600, ResendAfter: 60, CodeLength: 6}, nil
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
func (n *Native) Verify(ctx context.Context, challenge, code, ip string) (NativeTokens, error) {
	if !validOpaque(challenge, "sn_c_") {
		return NativeTokens{}, domain.NewError(domain.InvalidCode)
	}
	if len(code) != 6 {
		return NativeTokens{}, domain.NewError(domain.InvalidCode)
	}
	for _, c := range code {
		if c < '0' || c > '9' {
			return NativeTokens{}, domain.NewError(domain.InvalidCode)
		}
	}
	tx, err := n.begin(ctx)
	if err != nil {
		return NativeTokens{}, err
	}
	defer tx.Rollback(ctx)
	if err := n.rates(ctx, tx, "verify", ip, ""); err != nil {
		return NativeTokens{}, err
	}
	digest := n.digest("challenge", challenge)
	provided := n.codeDigest(challenge, code)
	var expected []byte
	var expires time.Time
	var attempts int
	var consumed bool
	err = tx.QueryRow(ctx, "SELECT code_digest,expires_at,attempts,consumed FROM snippets_private.native_lock_challenge($1)", digest[:]).Scan(&expected, &expires, &attempts, &consumed)
	outcome := domain.ErrorCode("")
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		outcome = domain.InvalidCode
	case err != nil:
		return NativeTokens{}, domain.NewError(domain.DependencyUnavailable)
	case consumed:
		outcome = domain.InvalidCode
	case !expires.After(time.Now()):
		outcome = domain.CodeExpired
	case attempts >= 5:
		outcome = domain.TooManyAttempts
	case subtle.ConstantTimeCompare(expected, provided[:]) != 1:
		_, err = tx.Exec(ctx, "SELECT snippets_private.native_fail_challenge($1)", digest[:])
		if err != nil {
			return NativeTokens{}, domain.NewError(domain.DependencyUnavailable)
		}
		outcome = domain.InvalidCode
		if attempts == 4 {
			outcome = domain.TooManyAttempts
		}
	}
	if outcome != "" {
		if err := tx.Commit(ctx); err != nil {
			return NativeTokens{}, domain.NewError(domain.DependencyUnavailable)
		}
		return NativeTokens{}, domain.NewError(outcome)
	}
	result, err := newNativeTokens()
	if err != nil {
		return NativeTokens{}, err
	}
	access, refresh := n.digest("credential", result.AccessToken), n.digest("credential", result.RefreshToken)
	err = tx.QueryRow(ctx, "SELECT id::text,email,expires_at FROM snippets_private.native_issue($1,$2,$3,$4,$5)", digest[:], uuid.New(), uuid.New(), access[:], refresh[:]).Scan(&result.Account.ID, &result.Account.Email, &expires)
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
	if err := n.rates(ctx, tx, "refresh", ip, ""); err != nil {
		return NativeTokens{}, err
	}
	digest, access, refresh := n.digest("credential", token), n.digest("credential", result.AccessToken), n.digest("credential", result.RefreshToken)
	var expires time.Time
	err = tx.QueryRow(ctx, "SELECT id::text,email,expires_at FROM snippets_private.native_refresh($1,$2,$3)", digest[:], access[:], refresh[:]).Scan(&result.Account.ID, &result.Account.Email, &expires)
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
	return domain.Principal{IdentityDigest: identity, CredentialDigest: digest, ExpiresAt: expires, AuthenticatedAt: authenticated, AMR: []string{"email"}}, nil
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
