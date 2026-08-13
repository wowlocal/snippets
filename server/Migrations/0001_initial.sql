CREATE SCHEMA IF NOT EXISTS snippets_private;
REVOKE ALL ON SCHEMA snippets_private FROM PUBLIC;

CREATE TABLE IF NOT EXISTS migration_history (
    version text PRIMARY KEY,
    sha256 text NOT NULL CHECK (length(sha256) = 64),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE users (
    id uuid PRIMARY KEY,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled', 'deleting')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE identities (
    identity_digest bytea PRIMARY KEY CHECK (octet_length(identity_digest) = 32),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX identities_user_idx ON identities(user_id);

CREATE TABLE spaces (
    id uuid PRIMARY KEY,
    owner_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    dataset_generation uuid NOT NULL,
    feed_epoch uuid NOT NULL,
    key_epoch integer NOT NULL DEFAULT 1 CHECK (key_epoch > 0),
    next_sequence bigint NOT NULL DEFAULT 0 CHECK (next_sequence >= 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE space_memberships (
    space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role text NOT NULL CHECK (role IN ('owner', 'writer', 'reader')),
    scope_binding bytea NOT NULL CHECK (octet_length(scope_binding) = 32),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (space_id, user_id)
);
CREATE INDEX space_memberships_user_idx ON space_memberships(user_id, space_id);

CREATE TABLE space_creation_requests (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    idempotency_key uuid NOT NULL,
    space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (user_id, idempotency_key)
);

CREATE TABLE records (
    space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    record_id uuid NOT NULL,
    rev text NOT NULL CHECK (octet_length(rev) BETWEEN 1 AND 256),
    deleted boolean NOT NULL,
    blob bytea NOT NULL CHECK (octet_length(blob) <= 900000),
    record_generation bigint NOT NULL CHECK (record_generation > 0),
    record_version text NOT NULL CHECK (octet_length(record_version) BETWEEN 32 AND 2048),
    last_sequence bigint NOT NULL CHECK (last_sequence >= 0),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (space_id, record_id),
    UNIQUE (space_id, record_version)
);

CREATE TABLE changes (
    space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    sequence bigint NOT NULL CHECK (sequence > 0),
    record_id uuid NOT NULL,
    rev text NOT NULL CHECK (octet_length(rev) BETWEEN 1 AND 256),
    deleted boolean NOT NULL,
    blob bytea NOT NULL CHECK (octet_length(blob) <= 900000),
    record_generation bigint NOT NULL CHECK (record_generation > 0),
    record_version text NOT NULL CHECK (octet_length(record_version) BETWEEN 32 AND 2048),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (space_id, sequence)
);
CREATE INDEX changes_record_idx ON changes(space_id, record_id, sequence DESC);

CREATE TABLE key_envelopes (
    space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    purpose text NOT NULL CHECK (purpose IN ('recovery')),
    version integer NOT NULL CHECK (version > 0),
    key_epoch integer NOT NULL CHECK (key_epoch > 0),
    algorithm text NOT NULL CHECK (octet_length(algorithm) BETWEEN 1 AND 64),
    ciphertext bytea NOT NULL CHECK (octet_length(ciphertext) <= 262144),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (space_id, purpose)
);

CREATE TABLE pairings (
    space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    pairing_id uuid NOT NULL,
    recipient_public_key bytea NOT NULL CHECK (octet_length(recipient_public_key) BETWEEN 1 AND 384),
    recipient_key_hash bytea NOT NULL CHECK (octet_length(recipient_key_hash) = 32),
    authentication_tag text NOT NULL CHECK (authentication_tag ~ '^[A-Z2-9]{6,12}$'),
    algorithm text CHECK (algorithm IS NULL OR octet_length(algorithm) BETWEEN 1 AND 64),
    ciphertext bytea CHECK (ciphertext IS NULL OR octet_length(ciphertext) <= 262144),
    approved_at timestamptz,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (space_id, pairing_id),
    CHECK ((approved_at IS NULL AND algorithm IS NULL AND ciphertext IS NULL)
        OR (approved_at IS NOT NULL AND algorithm IS NOT NULL AND ciphertext IS NOT NULL))
);
CREATE INDEX pairings_expiry_idx ON pairings(expires_at);

CREATE OR REPLACE FUNCTION snippets_private.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('app.user_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION snippets_private.is_space_member(target_space uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.space_memberships sm
        WHERE sm.space_id = target_space
          AND sm.user_id = snippets_private.current_user_id()
    )
$$;

CREATE OR REPLACE FUNCTION snippets_private.is_personal_space_owner(target_space uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.spaces s
        WHERE s.id = target_space
          AND s.owner_user_id = snippets_private.current_user_id()
    )
$$;

CREATE OR REPLACE FUNCTION snippets_private.can_write_space(target_space uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.space_memberships sm
        WHERE sm.space_id = target_space
          AND sm.user_id = snippets_private.current_user_id()
          AND sm.role IN ('owner', 'writer')
    )
$$;

CREATE OR REPLACE FUNCTION snippets_private.owns_space(target_space uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.space_memberships sm
        WHERE sm.space_id = target_space
          AND sm.user_id = snippets_private.current_user_id()
          AND sm.role = 'owner'
    )
$$;

CREATE OR REPLACE FUNCTION snippets_private.resolve_identity(identity_hash bytea, candidate_user uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    resolved uuid;
BEGIN
    IF octet_length(identity_hash) <> 32 THEN
        RAISE EXCEPTION 'invalid identity digest' USING ERRCODE = '22023';
    END IF;
    SELECT user_id INTO resolved FROM public.identities WHERE identity_digest = identity_hash;
    IF resolved IS NOT NULL THEN
        RETURN resolved;
    END IF;
    BEGIN
        INSERT INTO public.users(id) VALUES (candidate_user);
        INSERT INTO public.identities(identity_digest, user_id) VALUES (identity_hash, candidate_user);
        RETURN candidate_user;
    EXCEPTION WHEN unique_violation THEN
        DELETE FROM public.users WHERE id = candidate_user;
        SELECT user_id INTO resolved FROM public.identities WHERE identity_digest = identity_hash;
        IF resolved IS NULL THEN RAISE; END IF;
        RETURN resolved;
    END;
END
$$;

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;
CREATE POLICY users_self ON users USING (id = snippets_private.current_user_id());

ALTER TABLE identities ENABLE ROW LEVEL SECURITY;
ALTER TABLE identities FORCE ROW LEVEL SECURITY;
CREATE POLICY identities_self ON identities USING (user_id = snippets_private.current_user_id());

ALTER TABLE spaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE spaces FORCE ROW LEVEL SECURITY;
CREATE POLICY spaces_select ON spaces FOR SELECT USING (snippets_private.is_space_member(id));
CREATE POLICY spaces_insert ON spaces FOR INSERT
    WITH CHECK (owner_user_id = snippets_private.current_user_id());
CREATE POLICY spaces_update ON spaces FOR UPDATE
    USING (snippets_private.can_write_space(id)) WITH CHECK (snippets_private.can_write_space(id));
CREATE POLICY spaces_delete ON spaces FOR DELETE USING (snippets_private.owns_space(id));

ALTER TABLE space_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE space_memberships FORCE ROW LEVEL SECURITY;
CREATE POLICY memberships_select ON space_memberships FOR SELECT USING (snippets_private.is_space_member(space_id));
CREATE POLICY memberships_insert_owner ON space_memberships FOR INSERT
    WITH CHECK (
        user_id = snippets_private.current_user_id()
        AND role = 'owner'
        AND snippets_private.is_personal_space_owner(space_id)
    );
CREATE POLICY memberships_update ON space_memberships FOR UPDATE
    USING (snippets_private.owns_space(space_id)) WITH CHECK (snippets_private.owns_space(space_id));
CREATE POLICY memberships_delete ON space_memberships FOR DELETE USING (snippets_private.owns_space(space_id));

ALTER TABLE space_creation_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE space_creation_requests FORCE ROW LEVEL SECURITY;
CREATE POLICY creation_requests_self ON space_creation_requests
    USING (user_id = snippets_private.current_user_id())
    WITH CHECK (user_id = snippets_private.current_user_id());

ALTER TABLE records ENABLE ROW LEVEL SECURITY;
ALTER TABLE records FORCE ROW LEVEL SECURITY;
CREATE POLICY records_select ON records FOR SELECT USING (snippets_private.is_space_member(space_id));
CREATE POLICY records_write ON records FOR ALL
    USING (snippets_private.can_write_space(space_id))
    WITH CHECK (snippets_private.can_write_space(space_id));

ALTER TABLE changes ENABLE ROW LEVEL SECURITY;
ALTER TABLE changes FORCE ROW LEVEL SECURITY;
CREATE POLICY changes_select ON changes FOR SELECT USING (snippets_private.is_space_member(space_id));
CREATE POLICY changes_insert ON changes FOR INSERT WITH CHECK (snippets_private.can_write_space(space_id));

ALTER TABLE key_envelopes ENABLE ROW LEVEL SECURITY;
ALTER TABLE key_envelopes FORCE ROW LEVEL SECURITY;
CREATE POLICY key_envelopes_select ON key_envelopes FOR SELECT USING (snippets_private.is_space_member(space_id));
CREATE POLICY key_envelopes_write ON key_envelopes FOR ALL
    USING (snippets_private.owns_space(space_id))
    WITH CHECK (snippets_private.owns_space(space_id));

ALTER TABLE pairings ENABLE ROW LEVEL SECURITY;
ALTER TABLE pairings FORCE ROW LEVEL SECURITY;
CREATE POLICY pairings_select ON pairings FOR SELECT USING (snippets_private.is_space_member(space_id));
CREATE POLICY pairings_write ON pairings FOR ALL
    USING (snippets_private.can_write_space(space_id))
    WITH CHECK (snippets_private.can_write_space(space_id));

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA snippets_private FROM PUBLIC;

GRANT USAGE ON SCHEMA public, snippets_private TO snippets_runtime;
GRANT EXECUTE ON FUNCTION snippets_private.current_user_id() TO snippets_runtime;
GRANT EXECUTE ON FUNCTION snippets_private.is_space_member(uuid) TO snippets_runtime;
GRANT EXECUTE ON FUNCTION snippets_private.is_personal_space_owner(uuid) TO snippets_runtime;
GRANT EXECUTE ON FUNCTION snippets_private.can_write_space(uuid) TO snippets_runtime;
GRANT EXECUTE ON FUNCTION snippets_private.owns_space(uuid) TO snippets_runtime;
GRANT EXECUTE ON FUNCTION snippets_private.resolve_identity(bytea, uuid) TO snippets_runtime;
GRANT SELECT ON users TO snippets_runtime;
GRANT SELECT, INSERT ON spaces, space_memberships, space_creation_requests TO snippets_runtime;
GRANT UPDATE (next_sequence) ON spaces TO snippets_runtime;
GRANT SELECT, INSERT, UPDATE ON records TO snippets_runtime;
GRANT SELECT, INSERT ON changes TO snippets_runtime;
GRANT SELECT, INSERT, UPDATE ON key_envelopes TO snippets_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON pairings TO snippets_runtime;
