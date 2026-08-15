-- The resource server keeps only a keyed digest of a logged-out JWT. This closes
-- the normal stateless-JWT replay window without persisting bearer credentials or
-- relying on every identity provider to introspect self-contained access tokens.
CREATE TABLE snippets_private.revoked_access_tokens (
    credential_digest bytea PRIMARY KEY CHECK (octet_length(credential_digest) = 32),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX revoked_access_tokens_expiry_idx
    ON snippets_private.revoked_access_tokens(expires_at);

CREATE OR REPLACE FUNCTION snippets_private.is_access_token_revoked(token_digest bytea)
RETURNS boolean
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT CASE
        WHEN octet_length(token_digest) <> 32 THEN true
        ELSE EXISTS (
            SELECT 1
             FROM snippets_private.revoked_access_tokens
             WHERE credential_digest = token_digest
               -- JWT validation permits at most five minutes of configured clock
               -- skew, so a revoked token must remain denied through that same tail.
               AND expires_at >= clock_timestamp() - interval '5 minutes'
        )
    END
$$;

CREATE OR REPLACE FUNCTION snippets_private.revoke_access_token(
    token_digest bytea,
    token_expires_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF octet_length(token_digest) <> 32
       OR token_expires_at < clock_timestamp() - interval '5 minutes'
       OR token_expires_at > clock_timestamp() + interval '10 minutes' THEN
        RAISE EXCEPTION 'invalid access token revocation' USING ERRCODE = '22023';
    END IF;

    DELETE FROM snippets_private.revoked_access_tokens
     WHERE expires_at < clock_timestamp() - interval '5 minutes';

    INSERT INTO snippets_private.revoked_access_tokens(
        credential_digest, expires_at
    ) VALUES (
        token_digest, token_expires_at
    )
    ON CONFLICT (credential_digest) DO UPDATE
        SET expires_at = greatest(
                snippets_private.revoked_access_tokens.expires_at,
                EXCLUDED.expires_at
            ),
            revoked_at = clock_timestamp();
END
$$;

REVOKE ALL ON TABLE snippets_private.revoked_access_tokens FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.is_access_token_revoked(bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.revoke_access_token(bytea, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION snippets_private.is_access_token_revoked(bytea) TO snippets_runtime;
GRANT EXECUTE ON FUNCTION snippets_private.revoke_access_token(bytea, timestamptz) TO snippets_runtime;
