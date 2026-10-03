package auth

import (
	"context"
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

func TestAccountKeyFormatAndOpaqueCredentials(t *testing.T) {
	// ADR 0006 vectors; every client implements the same check.
	for body, check := range map[string]string{
		"00000000000000000000000000": "HF", "ZZZZZZZZZZZZZZZZZZZZZZZZZZ": "8R",
		"7KQF9M2XR4TDH8WBZN3CP6YE1A": "Q7", "0123456789ABCDEFGHJKMNPQRS": "45",
	} {
		if accountKeyCheck(body) != check || !validAccountKey(body+check) {
			t.Fatal("account key check differs from ADR vector", body)
		}
	}
	for _, input := range []string{"", "7KQF9M2XR4TDH8WBZN3CP6YE1AQ8", "7kqf9m2xr4tdh8wbzn3cp6ye1aq7", "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7", "UKQF9M2XR4TDH8WBZN3CP6YE1AQ7", "7KQF9M2XR4TDH8WBZN3CP6YE1AQ", "7KQF9M2XR4TDH8WBZN3CP6YE1AQ77"} {
		if validAccountKey(input) {
			t.Fatal("non-canonical account key accepted", input)
		}
	}
	seen := make(map[string]bool)
	for i := 0; i < 1000; i++ {
		key, err := newAccountKey()
		if err != nil || !validAccountKey(key) || seen[key] {
			t.Fatal("generated account key invalid or repeated")
		}
		seen[key] = true
	}
	first, _ := randomOpaque("sn_a_")
	second, _ := randomOpaque("sn_a_")
	if first == second || !validOpaque(first, "sn_a_") || validOpaque(first, "sn_r_") {
		t.Fatal("opaque credentials invalid")
	}
}

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
func nativeFixture(t *testing.T) (*Native, *pgxpool.Pool) {
	t.Helper()
	runtime := nativeTestPool(t, false)
	owner := nativeTestPool(t, true)
	native, err := NewNative(runtime, config.NativeAuth{Secret: make([]byte, 32), IdentityPepper: []byte(strings.Repeat("p", 32))})
	if err != nil {
		t.Fatal(err)
	}
	return native, owner
}
func createNative(t *testing.T, n *Native, ip string) NativeAccountCreation {
	t.Helper()
	created, err := n.CreateAccount(context.Background(), ip)
	if err != nil {
		t.Fatal(err)
	}
	return created
}
func loginNative(t *testing.T, n *Native, ip string) NativeTokens {
	t.Helper()
	return createNative(t, n, ip).Session
}
func TestNativePostgresAccountLifecycleRotationRevocationAndIsolation(t *testing.T) {
	n, owner := nativeFixture(t)
	ctx := context.Background()
	ip := uuid.NewString()
	created := createNative(t, n, ip)
	tokens := created.Session
	if !validAccountKey(created.AccountKey) || uuid.Validate(tokens.Account.ID) != nil || tokens.TokenType != "Bearer" || tokens.ExpiresIn < 290 {
		t.Fatal("invalid account creation metadata")
	}
	var stored int
	if err := owner.QueryRow(ctx, "SELECT count(*) FROM snippets_private.native_accounts WHERE id=$1 AND key_digest=$2", tokens.Account.ID, func() []byte { d := n.accountKeyDigest(created.AccountKey); return d[:] }()).Scan(&stored); err != nil || stored != 1 {
		t.Fatal("account key digest was not stored")
	}
	var columns string
	if err := owner.QueryRow(ctx, "SELECT string_agg(column_name,',' ORDER BY column_name) FROM information_schema.columns WHERE table_schema='snippets_private' AND table_name='native_accounts'").Scan(&columns); err != nil || columns != "created_at,id,key_digest" {
		t.Fatal("native accounts hold more than a key digest", columns)
	}
	principal, err := n.Validate(ctx, tokens.AccessToken, Standard)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := n.Validate(ctx, tokens.RefreshToken, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatal("refresh used as access")
	}
	if _, err := n.Validate(ctx, tokens.AccessToken, RecentPhishingResistant); domain.AsServiceError(err).Code != domain.ReauthenticationNeeded {
		t.Fatal("account key treated as phishing resistant")
	}
	rotated, err := n.Refresh(ctx, tokens.RefreshToken, ip)
	if err != nil {
		t.Fatal(err)
	}
	next, err := n.Validate(ctx, rotated.AccessToken, Standard)
	if err != nil || next.IdentityDigest != principal.IdentityDigest || next.CredentialDigest == principal.CredentialDigest || rotated.Account.ID != tokens.Account.ID {
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
	separate, err := n.SignIn(ctx, created.AccountKey, uuid.NewString())
	if err != nil {
		t.Fatal(err)
	}
	if separate.Account.ID != tokens.Account.ID {
		t.Fatal("account identity not stable across sign-in")
	}
	other := loginNative(t, n, uuid.NewString())
	if other.Account.ID == tokens.Account.ID {
		t.Fatal("account creation reused an account")
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
	original, err := n.SignIn(ctx, created.AccountKey, uuid.NewString())
	if err != nil {
		t.Fatal(err)
	}
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
	unknown, _ := newAccountKey()
	for _, key := range []string{unknown, strings.ToLower(created.AccountKey), created.AccountKey[:27] + "0", ""} {
		if _, err := n.SignIn(ctx, key, uuid.NewString()); domain.AsServiceError(err).Code != domain.InvalidAccountKey {
			t.Fatal("unknown or malformed account key accepted")
		}
	}
	for _, table := range []string{"native_accounts", "native_tokens", "native_families", "native_rates"} {
		if _, err := n.pool.Exec(ctx, "SELECT * FROM snippets_private."+table); err == nil {
			t.Fatal("runtime can enumerate authentication tables")
		}
		if _, err := n.pool.Exec(ctx, "DELETE FROM snippets_private."+table); err == nil {
			t.Fatal("runtime can directly mutate authentication tables")
		}
	}
	// Only key-proving entry points may open a family for an account.
	if _, err := n.pool.Exec(ctx, "SELECT * FROM snippets_private.native_open_family($1,$2,$3,$4)", tokens.Account.ID, uuid.New(), make([]byte, 32), make([]byte, 32)); err == nil {
		t.Fatal("runtime can open a session family without an account key")
	}
	if err := n.Revoke(ctx, "unknown", "refresh_token"); err != nil {
		t.Fatal("unknown revocation not idempotent")
	}
}
func TestNativePostgresKeyDigestCollisionCreatesNoSharedAccount(t *testing.T) {
	n, owner := nativeFixture(t)
	ctx := context.Background()
	created := createNative(t, n, uuid.NewString())
	digest := n.accountKeyDigest(created.AccountKey)
	rows, err := n.pool.Query(ctx, "SELECT id FROM snippets_private.native_create($1,$2,$3,$4,$5)", uuid.New(), digest[:], uuid.New(), make([]byte, 32), make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	returned := 0
	for rows.Next() {
		returned++
	}
	rows.Close()
	if rows.Err() != nil || returned != 0 {
		t.Fatal("colliding key digest created or reused an account")
	}
	var accounts int
	if err := owner.QueryRow(ctx, "SELECT count(*) FROM snippets_private.native_accounts WHERE key_digest=$1", digest[:]).Scan(&accounts); err != nil || accounts != 1 {
		t.Fatal("key digest is not unique")
	}
}
func TestNativePostgresConcurrentRefreshAndAccessExpiry(t *testing.T) {
	n, owner := nativeFixture(t)
	ctx := context.Background()
	tokens := loginNative(t, n, uuid.NewString())
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
	tokens = loginNative(t, n, uuid.NewString())
	digest := n.digest("credential", tokens.AccessToken)
	if _, err := owner.Exec(ctx, "UPDATE snippets_private.native_tokens SET expires_at=$2 WHERE digest=$1", digest[:], time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := n.Validate(ctx, tokens.AccessToken, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatal("expired access accepted")
	}
}

func TestNativePostgresPersistentRatesAndSecretRotation(t *testing.T) {
	n, owner := nativeFixture(t)
	ctx := context.Background()
	created := createNative(t, n, uuid.NewString())
	// A native credential-secret rotation loses sessions, never the existing account
	// or its stable sync identity. The separate identity pepper remains persistent.
	rotatedConfiguration := n.configuration
	rotatedConfiguration.Secret = []byte(strings.Repeat("r", 32))
	rotated, err := NewNative(n.pool, rotatedConfiguration)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rotated.Validate(ctx, created.Session.AccessToken, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
		t.Fatal("session survived credential-secret rotation")
	}
	second, err := rotated.SignIn(ctx, created.AccountKey, uuid.NewString())
	if err != nil || second.Account.ID != created.Session.Account.ID {
		t.Fatal("credential-secret rotation lost the account")
	}
	a, _ := n.Validate(ctx, created.Session.AccessToken, Standard)
	b, _ := rotated.Validate(ctx, second.AccessToken, Standard)
	if a.IdentityDigest != b.IdentityDigest {
		t.Fatal("credential-secret rotation changed sync identity")
	}
	repeppered := n.configuration
	repeppered.IdentityPepper = []byte(strings.Repeat("q", 32))
	other, err := NewNative(n.pool, repeppered)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := other.SignIn(ctx, created.AccountKey, uuid.NewString()); domain.AsServiceError(err).Code != domain.InvalidAccountKey {
		t.Fatal("account lookup ignores the identity pepper")
	}
	for _, scenario := range []struct {
		kind, key string
		budget    int
		attempt   func(*Native, string) error
	}{
		{"create_ip", uuid.NewString(), 10, func(n *Native, ip string) error { _, err := n.CreateAccount(ctx, ip); return err }},
		{"create_global", "global", 1000, func(n *Native, _ string) error { _, err := n.CreateAccount(ctx, uuid.NewString()); return err }},
		{"sign_in_ip", uuid.NewString(), 300, func(n *Native, ip string) error { _, err := n.SignIn(ctx, created.AccountKey, ip); return err }},
		{"sign_in_global", "global", 10000, func(n *Native, _ string) error {
			_, err := n.SignIn(ctx, created.AccountKey, uuid.NewString())
			return err
		}},
	} {
		// Exercise admission at a database-persisted boundary in an isolated rate namespace.
		secretConfiguration := n.configuration
		secretConfiguration.Secret = []byte(uuid.NewString())
		isolated, err := NewNative(n.pool, secretConfiguration)
		if err != nil {
			t.Fatal(err)
		}
		key := isolated.digest("rate-"+scenario.kind, scenario.key)
		if _, err := owner.Exec(ctx, "INSERT INTO snippets_private.native_rates VALUES($1,$2,clock_timestamp(),clock_timestamp()+interval '1 hour',$3)", key[:], scenario.kind, scenario.budget); err != nil {
			t.Fatal(err)
		}
		if domain.AsServiceError(scenario.attempt(isolated, scenario.key)).Code != domain.RateLimited {
			t.Fatal("persistent rate boundary bypassed", scenario.kind)
		}
	}
}
