package auth

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/wowlocal/snippets/server/internal/domain"
	"github.com/wowlocal/snippets/server/internal/postgres"
)

func TestNativePostgresExpiredAdmittedPrincipalCannotWriteAfterRevocation(t *testing.T) {
	for _, hint := range []string{"access_token", "refresh_token"} {
		for _, expireFamily := range []bool{false, true} {
			name := hint
			if expireFamily {
				name += "_after_family_cleanup"
			}
			t.Run(name, func(t *testing.T) {
				n, owner, sender := nativeFixture(t)
				ctx := context.Background()
				tokens := loginNative(t, n, sender, nativeEmail(), uuid.NewString())
				digest := n.digest("credential", tokens.AccessToken)
				var expires time.Time
				var family uuid.UUID
				if err := owner.QueryRow(ctx, "UPDATE snippets_private.native_tokens SET expires_at=clock_timestamp()+interval '250 milliseconds' WHERE digest=$1 RETURNING expires_at,family_id", digest[:]).Scan(&expires, &family); err != nil {
					t.Fatal("cannot shorten test access expiry")
				}
				if expireFamily {
					if _, err := owner.Exec(ctx, "UPDATE snippets_private.native_families SET expires_at=$2 WHERE id=$1", family, expires); err != nil {
						t.Fatal("cannot shorten test family expiry")
					}
				}
				// HTTP authenticates before reading the complete POST body. Preserve
				// that admitted principal while the body is delayed beyond expiry.
				admitted, err := n.Validate(ctx, tokens.AccessToken, Standard)
				if err != nil {
					t.Fatal("cannot admit test access token")
				}
				time.Sleep(time.Until(expires.Add(20 * time.Millisecond)))
				if _, err := n.pool.Exec(ctx, "SELECT snippets_private.native_cleanup()"); err != nil {
					t.Fatal("native maintenance failed")
				}
				token := tokens.AccessToken
				if hint == "refresh_token" {
					token = tokens.RefreshToken
				}
				if err := n.Revoke(ctx, token, hint); err != nil {
					t.Fatal("native revocation failed")
				}
				if _, err := n.Validate(ctx, tokens.AccessToken, Standard); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
					t.Fatal("fresh validation accepted revoked access")
				}
				store, err := postgres.NewStore(n.pool, uuid.New(), make([]byte, 32))
				if err != nil {
					t.Fatal("cannot construct test data plane")
				}
				if _, err := store.CreateSpace(ctx, admitted, nil); domain.AsServiceError(err).Code != domain.AuthenticationRequired {
					t.Fatal("admitted POST was not denied after acknowledged native revocation")
				}
				// The grace period must remain bounded, including expired families
				// whose original refresh tokens were retained for safe revocation.
				if _, err := owner.Exec(ctx, "UPDATE snippets_private.native_families SET expires_at=clock_timestamp()-interval '6 minutes' WHERE id=$1", family); err != nil {
					t.Fatal("cannot age test family")
				}
				if _, err := n.pool.Exec(ctx, "SELECT snippets_private.native_cleanup()"); err != nil {
					t.Fatal("native maintenance failed")
				}
				var remaining int
				if err := owner.QueryRow(ctx, "SELECT count(*) FROM snippets_private.native_families WHERE id=$1", family).Scan(&remaining); err != nil || remaining != 0 {
					t.Fatal("expired family outlived its cleanup grace period")
				}
			})
		}
	}
}

func TestNativePostgresOldRetainedAccessRevocationIsIdempotent(t *testing.T) {
	for _, hint := range []string{"access_token", "refresh_token"} {
		t.Run(hint, func(t *testing.T) {
			n, owner, sender := nativeFixture(t)
			ctx := context.Background()
			tokens := loginNative(t, n, sender, nativeEmail(), uuid.NewString())
			digest := n.digest("credential", tokens.AccessToken)
			if _, err := owner.Exec(ctx, "UPDATE snippets_private.native_tokens SET expires_at=clock_timestamp()-interval '6 minutes' WHERE digest=$1", digest[:]); err != nil {
				t.Fatal("cannot age test access token")
			}
			token := tokens.AccessToken
			if hint == "refresh_token" {
				token = tokens.RefreshToken
			}
			for attempt := 0; attempt < 2; attempt++ {
				if err := n.Revoke(ctx, token, hint); err != nil {
					t.Fatal("old retained credential revocation was not idempotent")
				}
			}
		})
	}
}
