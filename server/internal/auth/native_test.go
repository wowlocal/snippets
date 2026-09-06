package auth

import (
	"context"
	"errors"
	"net"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/domain"
)

func TestNativeEmailValidationAndCodeBinding(t *testing.T) {
	value, err := NormalizeEmail("  User+label@Example.TEST ")
	if err != nil || value != "user+label@example.test" {
		t.Fatal("canonical email rejected")
	}
	for _, input := range []string{"", "a", "a@localhost", "Name <a@example.test>", "a@example.test\r\nBcc: attacker@example.test", "a@-example.test", "a@example..test", "a@例.test", strings.Repeat("a", 65) + "@example.test"} {
		if _, err := NormalizeEmail(input); err == nil {
			t.Fatal("malformed email accepted")
		}
	}
	native := &Native{configuration: config.NativeAuth{Secret: make([]byte, 32)}}
	if native.codeDigest("first", "123456") == native.codeDigest("second", "123456") {
		t.Fatal("code not bound to challenge")
	}
	first, _ := randomOpaque("sn_a_")
	second, _ := randomOpaque("sn_a_")
	if first == second || !validOpaque(first, "sn_a_") || validOpaque(first, "sn_r_") {
		t.Fatal("opaque credentials invalid")
	}
}

type captureCodeSender struct {
	mu     sync.Mutex
	code   string
	failed bool
}

func (s *captureCodeSender) SendCode(_ context.Context, _, code string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.code = code
	if s.failed {
		return errors.New("private smtp recipient and message")
	}
	return nil
}
func (s *captureCodeSender) last() string { s.mu.Lock(); defer s.mu.Unlock(); return s.code }
func nativeTestPool(t *testing.T, owner bool) *pgxpool.Pool {
	t.Helper()
	if os.Getenv("SNIPPETS_INTEGRATION_TESTS") != "1" {
		t.Skip("set SNIPPETS_INTEGRATION_TESTS=1")
	}
	role := "RUNTIME"
	if owner {
		role = "OWNER"
	}
	address := net.JoinHostPort(os.Getenv("DATABASE_HOST"), os.Getenv("DATABASE_PORT"))
	dsn := (&url.URL{Scheme: "postgres", Host: address, Path: "/" + os.Getenv("DATABASE_NAME"), User: url.UserPassword(os.Getenv("DATABASE_"+role+"_USER"), os.Getenv("DATABASE_"+role+"_PASSWORD")), RawQuery: "sslmode=" + url.QueryEscape(os.Getenv("DATABASE_TLS_MODE"))}).String()
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatal("test database unavailable")
	}
	t.Cleanup(pool.Close)
	return pool
}
func nativeFixture(t *testing.T) (*Native, *pgxpool.Pool, *captureCodeSender) {
	t.Helper()
	runtime := nativeTestPool(t, false)
	owner := nativeTestPool(t, true)
	sender := &captureCodeSender{}
	native, err := NewNative(runtime, config.NativeAuth{Secret: make([]byte, 32), IdentityPepper: []byte(strings.Repeat("p", 32))}, sender)
	if err != nil {
		t.Fatal(err)
	}
	return native, owner, sender
}
func nativeEmail() string { return uuid.NewString() + "@native.example.test" }
func resetNativeResend(t *testing.T, n *Native, owner *pgxpool.Pool, email string) {
	t.Helper()
	digest := n.digest("rate-start_email_cooldown", email)
	if _, err := owner.Exec(context.Background(), "DELETE FROM snippets_private.native_rates WHERE digest=$1", digest[:]); err != nil {
		t.Fatal(err)
	}
}
func loginNative(t *testing.T, n *Native, s *captureCodeSender, email, ip string) NativeTokens {
	t.Helper()
	ctx := context.Background()
	challenge, err := n.Start(ctx, email, ip)
	if err != nil {
		t.Fatal(err)
	}
	tokens, err := n.Verify(ctx, challenge.ChallengeID, s.last(), ip)
	if err != nil {
		t.Fatal(err)
	}
	return tokens
}
func TestNativePostgresLoginRotationRevocationAndIsolation(t *testing.T) {
	n, owner, sender := nativeFixture(t)
	ctx := context.Background()
	email, ip := nativeEmail(), uuid.NewString()
	tokens := loginNative(t, n, sender, email, ip)
	if tokens.Account.Email != email || tokens.Account.ID == "" || tokens.TokenType != "Bearer" || tokens.ExpiresIn < 290 {
		t.Fatal("invalid session metadata")
	}
	principal, err := n.Validate(ctx, tokens.AccessToken, Standard)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := n.Validate(ctx, tokens.RefreshToken, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatal("refresh used as access")
	}
	if _, err := n.Validate(ctx, tokens.AccessToken, RecentPhishingResistant); domain.AsServiceError(err).Code != domain.ReauthenticationNeeded {
		t.Fatal("email treated as phishing resistant")
	}
	rotated, err := n.Refresh(ctx, tokens.RefreshToken, ip)
	if err != nil {
		t.Fatal(err)
	}
	next, err := n.Validate(ctx, rotated.AccessToken, Standard)
	if err != nil || next.IdentityDigest != principal.IdentityDigest || next.CredentialDigest == principal.CredentialDigest {
		t.Fatal("rotation changed identity")
	}
	if err := n.Revoke(ctx, tokens.AccessToken, "access_token"); err != nil {
		t.Fatal(err)
	}
	if _, err := n.Validate(ctx, tokens.AccessToken, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatal("access revocation ineffective")
	}
	if _, err := n.Validate(ctx, rotated.AccessToken, Standard); err != nil {
		t.Fatal("exact access revocation revoked sibling")
	}
	resetNativeResend(t, n, owner, email)
	separate := loginNative(t, n, sender, email, uuid.NewString())
	if separate.Account.ID != tokens.Account.ID {
		t.Fatal("account identity not stable")
	}
	if _, err := n.Refresh(ctx, tokens.RefreshToken, ip); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatal("retired refresh accepted")
	}
	if _, err := n.Validate(ctx, rotated.AccessToken, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatal("reuse did not revoke family")
	}
	if _, err := n.Validate(ctx, separate.AccessToken, Standard); err != nil {
		t.Fatal("reuse affected another session")
	}
	resetNativeResend(t, n, owner, email)
	original := loginNative(t, n, sender, email, uuid.NewString())
	current, err := n.Refresh(ctx, original.RefreshToken, uuid.NewString())
	if err != nil {
		t.Fatal(err)
	}
	if err := n.Revoke(ctx, original.RefreshToken, "refresh_token"); err != nil {
		t.Fatal(err)
	}
	if _, err := n.Validate(ctx, current.AccessToken, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatal("old refresh failed to revoke current family")
	}
	for _, table := range []string{"native_accounts", "native_challenges", "native_tokens", "native_families", "native_rates"} {
		if _, err := n.pool.Exec(ctx, "SELECT * FROM snippets_private."+table); err == nil {
			t.Fatal("runtime can enumerate authentication tables")
		}
		if _, err := n.pool.Exec(ctx, "DELETE FROM snippets_private."+table); err == nil {
			t.Fatal("runtime can directly mutate authentication tables")
		}
	}
	if err := n.Revoke(ctx, "unknown", "refresh_token"); err != nil {
		t.Fatal("unknown revocation not idempotent")
	}
}
func TestNativePostgresCodeBudgetsExpiryAndDeliveryFailure(t *testing.T) {
	n, owner, sender := nativeFixture(t)
	ctx := context.Background()
	email, ip := nativeEmail(), uuid.NewString()
	challenge, err := n.Start(ctx, email, ip)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := n.Start(ctx, email, ip); domain.AsServiceError(err).Code != domain.RateLimited {
		t.Fatal("resend cooldown absent")
	}
	code := sender.last()
	wrong := "000000"
	if code == wrong {
		wrong = "000001"
	}
	var wg sync.WaitGroup
	results := make(chan error, 10)
	for i := 0; i < 10; i++ {
		wg.Go(func() { _, err := n.Verify(ctx, challenge.ChallengeID, wrong, ip); results <- err })
	}
	wg.Wait()
	close(results)
	invalid, limited := 0, 0
	for err := range results {
		switch domain.AsServiceError(err).Code {
		case domain.InvalidCode:
			invalid++
		case domain.TooManyAttempts:
			limited++
		default:
			t.Fatal("unexpected concurrent code outcome", err)
		}
	}
	if invalid != 4 || limited != 6 {
		t.Fatal("attempt budget not atomic")
	}
	if _, err := n.Verify(ctx, challenge.ChallengeID, code, ip); domain.AsServiceError(err).Code != domain.TooManyAttempts {
		t.Fatal("exhausted code accepted")
	}
	resetNativeResend(t, n, owner, email)
	newChallenge, err := n.Start(ctx, email, ip)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := n.Verify(ctx, challenge.ChallengeID, code, ip); domain.AsServiceError(err).Code != domain.InvalidCode {
		t.Fatal("old code survived resend")
	}
	digest := n.digest("challenge", newChallenge.ChallengeID)
	if _, err := owner.Exec(ctx, "UPDATE snippets_private.native_challenges SET expires_at=clock_timestamp()-interval '1 second' WHERE digest=$1", digest[:]); err != nil {
		t.Fatal(err)
	}
	if _, err := n.Verify(ctx, newChallenge.ChallengeID, sender.last(), ip); domain.AsServiceError(err).Code != domain.CodeExpired {
		t.Fatal("expired code accepted")
	}
	resetNativeResend(t, n, owner, email)
	newChallenge, err = n.Start(ctx, email, ip)
	if err != nil {
		t.Fatal(err)
	}
	code = sender.last()
	var successes int
	results = make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Go(func() { _, err := n.Verify(ctx, newChallenge.ChallengeID, code, ip); results <- err })
	}
	wg.Wait()
	close(results)
	for err := range results {
		if err == nil {
			successes++
		} else if domain.AsServiceError(err).Code != domain.InvalidCode {
			t.Fatal(err)
		}
	}
	if successes != 1 {
		t.Fatal("one-time code issued multiple sessions")
	}
	sender.failed = true
	_, err = n.Start(ctx, nativeEmail(), uuid.NewString())
	if domain.AsServiceError(err).Code != domain.DependencyUnavailable || strings.Contains(err.Error(), "private") {
		t.Fatal("delivery failure not sanitized")
	}
}
func TestNativePostgresConcurrentRefreshAndAccessExpiry(t *testing.T) {
	n, owner, sender := nativeFixture(t)
	ctx := context.Background()
	tokens := loginNative(t, n, sender, nativeEmail(), uuid.NewString())
	var wg sync.WaitGroup
	results := make(chan NativeTokens, 2)
	failures := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Go(func() {
			next, err := n.Refresh(ctx, tokens.RefreshToken, uuid.NewString())
			results <- next
			failures <- err
		})
	}
	wg.Wait()
	close(results)
	close(failures)
	successes := 0
	for err := range failures {
		if err == nil {
			successes++
		} else if domain.AsServiceError(err).Code != domain.AuthenticationRequired {
			t.Fatal(err)
		}
	}
	if successes != 1 {
		t.Fatal("concurrent refresh issued multiple sessions")
	}
	for next := range results {
		if next.AccessToken != "" {
			if _, err := n.Validate(ctx, next.AccessToken, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
				t.Fatal("concurrent reuse family remains active")
			}
		}
	}
	tokens = loginNative(t, n, sender, nativeEmail(), uuid.NewString())
	digest := n.digest("credential", tokens.AccessToken)
	if _, err := owner.Exec(ctx, "UPDATE snippets_private.native_tokens SET expires_at=$2 WHERE digest=$1", digest[:], time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := n.Validate(ctx, tokens.AccessToken, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatal("expired access accepted")
	}
}

func TestNativePostgresPersistentRatesAndSecretRotation(t *testing.T) {
	n, owner, sender := nativeFixture(t)
	ctx := context.Background()
	email, ip := nativeEmail(), uuid.NewString()
	first := loginNative(t, n, sender, email, ip)
	replica, err := NewNative(n.pool, n.configuration, sender)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := replica.Start(ctx, email, uuid.NewString()); domain.AsServiceError(err).Code != domain.RateLimited {
		t.Fatal("replica bypassed email cooldown")
	}
	// A native credential-secret rotation loses sessions, never the existing account
	// or its stable sync identity. The separate identity pepper remains persistent.
	rotatedConfiguration := n.configuration
	rotatedConfiguration.Secret = []byte(strings.Repeat("r", 32))
	rotated, err := NewNative(n.pool, rotatedConfiguration, sender)
	if err != nil {
		t.Fatal(err)
	}
	second := loginNative(t, rotated, sender, email, uuid.NewString())
	if second.Account.ID != first.Account.ID {
		t.Fatal("credential-secret rotation created a new account")
	}
	a, _ := n.Validate(ctx, first.AccessToken, Standard)
	b, _ := rotated.Validate(ctx, second.AccessToken, Standard)
	if a.IdentityDigest != b.IdentityDigest {
		t.Fatal("credential-secret rotation changed sync identity")
	}
	for _, scenario := range []struct {
		kind, key string
		budget    int
	}{{"start_ip", uuid.NewString(), 30}, {"start_global", "global", 1000}} {
		// Exercise admission at a database-persisted boundary without sending mail.
		secretConfiguration := n.configuration
		secretConfiguration.Secret = []byte(uuid.NewString())
		isolated, err := NewNative(n.pool, secretConfiguration, sender)
		if err != nil {
			t.Fatal(err)
		}
		key := isolated.digest("rate-"+scenario.kind, scenario.key)
		if _, err := owner.Exec(ctx, "INSERT INTO snippets_private.native_rates VALUES($1,$2,clock_timestamp(),clock_timestamp()+interval '1 hour',$3)", key[:], scenario.kind, scenario.budget); err != nil {
			t.Fatal(err)
		}
		_, err = isolated.Start(ctx, nativeEmail(), scenario.key)
		if domain.AsServiceError(err).Code != domain.RateLimited {
			t.Fatal("persistent rate boundary bypassed")
		}
	}
}
