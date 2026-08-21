BEGIN;

CREATE SCHEMA snippets_private;
REVOKE ALL ON SCHEMA snippets_private FROM PUBLIC;

CREATE TABLE snippets_private.schema_migrations (
    version bigint PRIMARY KEY CHECK (version > 0),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO snippets_private.schema_migrations(version) VALUES (1);

CREATE TABLE users (
    id uuid PRIMARY KEY,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled', 'deleting')),
    storage_bytes bigint NOT NULL DEFAULT 0 CHECK (storage_bytes BETWEEN 0 AND 2147483648),
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
    current_record_bytes bigint NOT NULL DEFAULT 0 CHECK (current_record_bytes >= 0),
    change_history_bytes bigint NOT NULL DEFAULT 0 CHECK (change_history_bytes >= 0),
    record_count bigint NOT NULL DEFAULT 0 CHECK (record_count BETWEEN 0 AND 100000),
    change_count bigint NOT NULL DEFAULT 0 CHECK (change_count BETWEEN 0 AND 250000),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (current_record_bytes + change_history_bytes <= 536870912)
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
    last_sequence bigint NOT NULL CHECK (last_sequence >= 0),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (space_id, record_id)
);

CREATE TABLE changes (
    space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    sequence bigint NOT NULL CHECK (sequence > 0),
    record_id uuid NOT NULL,
    rev text NOT NULL CHECK (octet_length(rev) BETWEEN 1 AND 256),
    deleted boolean NOT NULL,
    blob bytea NOT NULL CHECK (octet_length(blob) <= 900000),
    record_generation bigint NOT NULL CHECK (record_generation > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (space_id, sequence)
);
CREATE INDEX changes_record_idx ON changes(space_id, record_id, sequence DESC);

CREATE TABLE recovery_envelopes (
    space_id uuid PRIMARY KEY REFERENCES spaces(id) ON DELETE CASCADE,
    version integer NOT NULL CHECK (version > 0),
    key_epoch integer NOT NULL CHECK (key_epoch > 0),
    algorithm text NOT NULL CHECK (algorithm = 'snippets-recovery-hkdf-sha256-aes256gcm-v1'),
    ciphertext bytea NOT NULL CHECK (octet_length(ciphertext) <= 4096),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pairings (
    space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    pairing_id uuid NOT NULL,
    recipient_public_key bytea NOT NULL CHECK (octet_length(recipient_public_key) = 65 AND get_byte(recipient_public_key, 0) = 4),
    recipient_key_hash bytea NOT NULL CHECK (octet_length(recipient_key_hash) = 32),
    nonce bytea NOT NULL CHECK (octet_length(nonce) = 32),
    authentication_tag text NOT NULL CHECK (authentication_tag ~ '^[A-Z2-9]{8}$'),
    algorithm text CHECK (algorithm IS NULL OR algorithm = 'snippets-pairing-p256-hkdf-sha256-aes256gcm-v1'),
    ciphertext bytea CHECK (ciphertext IS NULL OR octet_length(ciphertext) <= 4096),
    approved_at timestamptz,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (space_id, pairing_id),
    CHECK ((approved_at IS NULL AND algorithm IS NULL AND ciphertext IS NULL)
        OR (approved_at IS NOT NULL AND algorithm IS NOT NULL AND ciphertext IS NOT NULL))
);
CREATE INDEX pairings_expiry_idx ON pairings(expires_at);

CREATE TABLE snippets_private.revoked_access_tokens (
    credential_digest bytea PRIMARY KEY CHECK (octet_length(credential_digest) = 32),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX revoked_access_tokens_expiry_idx ON snippets_private.revoked_access_tokens(expires_at);

CREATE OR REPLACE FUNCTION snippets_private.current_user_id() RETURNS uuid
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
    SELECT NULLIF(current_setting('app.user_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION snippets_private.is_space_member(target_space uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT EXISTS (SELECT 1 FROM public.space_memberships
      WHERE space_id = target_space AND user_id = snippets_private.current_user_id())
$$;

CREATE OR REPLACE FUNCTION snippets_private.is_personal_space_owner(target_space uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT EXISTS (SELECT 1 FROM public.spaces
      WHERE id = target_space AND owner_user_id = snippets_private.current_user_id())
$$;

CREATE OR REPLACE FUNCTION snippets_private.can_write_space(target_space uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT EXISTS (SELECT 1 FROM public.space_memberships
      WHERE space_id = target_space AND user_id = snippets_private.current_user_id()
        AND role IN ('owner', 'writer'))
$$;

CREATE OR REPLACE FUNCTION snippets_private.owns_space(target_space uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT EXISTS (SELECT 1 FROM public.space_memberships
      WHERE space_id = target_space AND user_id = snippets_private.current_user_id() AND role = 'owner')
$$;

CREATE OR REPLACE FUNCTION snippets_private.resolve_identity(identity_hash bytea, candidate_user uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE resolved uuid;
BEGIN
    IF octet_length(identity_hash) <> 32 THEN
        RAISE EXCEPTION 'invalid identity digest' USING ERRCODE = '22023';
    END IF;
    SELECT user_id INTO resolved FROM public.identities WHERE identity_digest = identity_hash;
    IF resolved IS NOT NULL THEN RETURN resolved; END IF;
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

CREATE OR REPLACE FUNCTION snippets_private.lock_storage_quota(target_space uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE owner_id uuid;
BEGIN
    IF NOT snippets_private.can_write_space(target_space) THEN RETURN false; END IF;
    SELECT owner_user_id INTO owner_id FROM public.spaces WHERE id = target_space;
    IF NOT FOUND THEN RETURN false; END IF;
    PERFORM 1 FROM public.users WHERE id = owner_id FOR UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;
    PERFORM 1 FROM public.spaces WHERE id = target_space FOR UPDATE;
    RETURN FOUND;
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.record_write_within_quota(
    target_space uuid, current_byte_delta bigint, new_change_bytes bigint, record_count_delta bigint
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE owner_id uuid; current_bytes bigint; history_bytes bigint; records_count bigint; changes_count bigint; owner_bytes bigint;
BEGIN
    IF current_byte_delta NOT BETWEEN -900256 AND 900256 OR new_change_bytes NOT BETWEEN 1 AND 900256
       OR record_count_delta NOT IN (0, 1) OR NOT snippets_private.can_write_space(target_space) THEN RETURN false; END IF;
    SELECT owner_user_id, current_record_bytes, change_history_bytes, record_count, change_count
      INTO owner_id, current_bytes, history_bytes, records_count, changes_count
      FROM public.spaces WHERE id = target_space FOR UPDATE;
    SELECT storage_bytes INTO owner_bytes FROM public.users WHERE id = owner_id FOR UPDATE;
    RETURN current_bytes + current_byte_delta >= 0
       AND current_bytes + current_byte_delta + history_bytes + new_change_bytes <= 536870912
       AND records_count + record_count_delta <= 100000 AND changes_count + 1 <= 250000
       AND owner_bytes + current_byte_delta + new_change_bytes BETWEEN 0 AND 2147483648;
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.compact_change_history_if_needed(
    target_space uuid, incoming_change_bytes bigint, incoming_change_count bigint
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
    owner_id uuid; current_bytes bigint; history_bytes bigint; records_count bigint;
    changes_count bigint; owner_bytes bigint;
BEGIN
    IF incoming_change_bytes NOT BETWEEN 0 AND 45012800 OR incoming_change_count NOT BETWEEN 0 AND 50
       OR NOT snippets_private.can_write_space(target_space) THEN RETURN false; END IF;
    SELECT owner_user_id, current_record_bytes, change_history_bytes, record_count, change_count
      INTO owner_id, current_bytes, history_bytes, records_count, changes_count
      FROM public.spaces WHERE id = target_space FOR UPDATE;
    IF NOT FOUND OR (changes_count + incoming_change_count <= 200000
       AND current_bytes + history_bytes + incoming_change_bytes <= 503316480) THEN RETURN false; END IF;
    SELECT storage_bytes INTO owner_bytes FROM public.users WHERE id = owner_id FOR UPDATE;
    -- A compacted feed contains one immutable baseline version per current record.
    -- If even that baseline cannot fit, preserve the old feed and let the normal
    -- quota response fail closed rather than discarding history.
    IF current_bytes * 2 + incoming_change_bytes > 536870912
       OR records_count + incoming_change_count > 250000
       OR owner_bytes - history_bytes + current_bytes + incoming_change_bytes > 2147483648 THEN
        RETURN false;
    END IF;
    UPDATE public.spaces SET feed_epoch = gen_random_uuid(), next_sequence = 0 WHERE id = target_space;
    DELETE FROM public.changes WHERE space_id = target_space;
    INSERT INTO public.changes(space_id, sequence, record_id, rev, deleted, blob, record_generation)
      SELECT space_id, row_number() OVER (ORDER BY record_id), record_id, rev, deleted, blob, record_generation
      FROM public.records WHERE space_id = target_space ORDER BY record_id;
    UPDATE public.records AS records SET last_sequence = baseline.sequence
      FROM public.changes AS baseline
      WHERE records.space_id = target_space AND baseline.space_id = target_space
        AND records.record_id = baseline.record_id;
    UPDATE public.spaces SET next_sequence = records_count WHERE id = target_space;
    RETURN true;
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.account_record_storage() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE byte_delta bigint; count_delta bigint; owner_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN byte_delta := octet_length(NEW.blob) + octet_length(NEW.rev); count_delta := 1;
    ELSIF TG_OP = 'UPDATE' THEN byte_delta := octet_length(NEW.blob) + octet_length(NEW.rev) - octet_length(OLD.blob) - octet_length(OLD.rev); count_delta := 0;
    ELSE byte_delta := -octet_length(OLD.blob) - octet_length(OLD.rev); count_delta := -1; END IF;
    UPDATE public.spaces SET current_record_bytes = current_record_bytes + byte_delta,
      record_count = record_count + count_delta WHERE id = coalesce(NEW.space_id, OLD.space_id)
      RETURNING owner_user_id INTO owner_id;
    IF FOUND THEN UPDATE public.users SET storage_bytes = storage_bytes + byte_delta WHERE id = owner_id; END IF;
    RETURN coalesce(NEW, OLD);
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.account_change_storage() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE byte_delta bigint; count_delta bigint; owner_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN byte_delta := octet_length(NEW.blob) + octet_length(NEW.rev); count_delta := 1;
    ELSE byte_delta := -octet_length(OLD.blob) - octet_length(OLD.rev); count_delta := -1; END IF;
    UPDATE public.spaces SET change_history_bytes = change_history_bytes + byte_delta,
      change_count = change_count + count_delta WHERE id = coalesce(NEW.space_id, OLD.space_id)
      RETURNING owner_user_id INTO owner_id;
    IF FOUND THEN UPDATE public.users SET storage_bytes = storage_bytes + byte_delta WHERE id = owner_id; END IF;
    RETURN coalesce(NEW, OLD);
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.account_deleted_space_storage() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
    UPDATE public.users SET storage_bytes = storage_bytes - OLD.current_record_bytes - OLD.change_history_bytes
      WHERE id = OLD.owner_user_id;
    RETURN OLD;
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.rotate_dataset_after_restore(target_space uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
    UPDATE public.spaces SET dataset_generation = gen_random_uuid(), feed_epoch = gen_random_uuid(), next_sequence = 0
      WHERE id = target_space;
    IF NOT FOUND THEN RAISE EXCEPTION 'space not found' USING ERRCODE = 'P0002'; END IF;
    DELETE FROM public.changes WHERE space_id = target_space;
    UPDATE public.records SET record_generation = record_generation + 1, last_sequence = 0,
      updated_at = clock_timestamp() WHERE space_id = target_space;
    INSERT INTO public.changes(space_id, sequence, record_id, rev, deleted, blob, record_generation)
      SELECT space_id, row_number() OVER (ORDER BY record_id), record_id, rev, deleted, blob, record_generation
      FROM public.records WHERE space_id = target_space ORDER BY record_id;
    UPDATE public.records AS records SET last_sequence = baseline.sequence
      FROM public.changes AS baseline
      WHERE records.space_id = target_space AND baseline.space_id = target_space
        AND records.record_id = baseline.record_id;
    UPDATE public.spaces SET next_sequence = (
      SELECT count(*) FROM public.changes WHERE space_id = target_space
    ) WHERE id = target_space;
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.is_access_token_revoked(token_digest bytea) RETURNS boolean
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT CASE WHEN octet_length(token_digest) <> 32 THEN true ELSE EXISTS (
      SELECT 1 FROM snippets_private.revoked_access_tokens WHERE credential_digest = token_digest
        AND expires_at >= clock_timestamp() - interval '5 minutes') END
$$;

CREATE OR REPLACE FUNCTION snippets_private.revoke_access_token(token_digest bytea, token_expires_at timestamptz) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
    IF octet_length(token_digest) <> 32 OR token_expires_at < clock_timestamp() - interval '5 minutes'
       OR token_expires_at > clock_timestamp() + interval '10 minutes' THEN
        RAISE EXCEPTION 'invalid access token revocation' USING ERRCODE = '22023';
    END IF;
    DELETE FROM snippets_private.revoked_access_tokens WHERE expires_at < clock_timestamp() - interval '5 minutes';
    INSERT INTO snippets_private.revoked_access_tokens(credential_digest, expires_at)
      VALUES (token_digest, token_expires_at) ON CONFLICT (credential_digest) DO UPDATE
      SET expires_at = greatest(snippets_private.revoked_access_tokens.expires_at, EXCLUDED.expires_at), revoked_at = clock_timestamp();
END
$$;

CREATE TRIGGER records_storage_accounting AFTER INSERT OR UPDATE OR DELETE ON records
FOR EACH ROW EXECUTE FUNCTION snippets_private.account_record_storage();
CREATE TRIGGER changes_storage_accounting AFTER INSERT OR DELETE ON changes
FOR EACH ROW EXECUTE FUNCTION snippets_private.account_change_storage();
CREATE TRIGGER spaces_storage_accounting BEFORE DELETE ON spaces
FOR EACH ROW EXECUTE FUNCTION snippets_private.account_deleted_space_storage();

ALTER TABLE users ENABLE ROW LEVEL SECURITY; ALTER TABLE users FORCE ROW LEVEL SECURITY;
CREATE POLICY users_self ON users USING (id = snippets_private.current_user_id());
ALTER TABLE identities ENABLE ROW LEVEL SECURITY; ALTER TABLE identities FORCE ROW LEVEL SECURITY;
CREATE POLICY identities_self ON identities USING (user_id = snippets_private.current_user_id());
ALTER TABLE spaces ENABLE ROW LEVEL SECURITY; ALTER TABLE spaces FORCE ROW LEVEL SECURITY;
CREATE POLICY spaces_select ON spaces FOR SELECT USING (snippets_private.is_space_member(id));
CREATE POLICY spaces_insert ON spaces FOR INSERT WITH CHECK (owner_user_id = snippets_private.current_user_id());
CREATE POLICY spaces_update ON spaces FOR UPDATE USING (snippets_private.can_write_space(id)) WITH CHECK (snippets_private.can_write_space(id));
CREATE POLICY spaces_delete ON spaces FOR DELETE USING (snippets_private.owns_space(id));
ALTER TABLE space_memberships ENABLE ROW LEVEL SECURITY; ALTER TABLE space_memberships FORCE ROW LEVEL SECURITY;
CREATE POLICY memberships_select ON space_memberships FOR SELECT USING (snippets_private.is_space_member(space_id));
CREATE POLICY memberships_insert_owner ON space_memberships FOR INSERT WITH CHECK (
    user_id = snippets_private.current_user_id() AND role = 'owner' AND snippets_private.is_personal_space_owner(space_id));
CREATE POLICY memberships_update ON space_memberships FOR UPDATE USING (snippets_private.owns_space(space_id)) WITH CHECK (snippets_private.owns_space(space_id));
CREATE POLICY memberships_delete ON space_memberships FOR DELETE USING (snippets_private.owns_space(space_id));
ALTER TABLE space_creation_requests ENABLE ROW LEVEL SECURITY; ALTER TABLE space_creation_requests FORCE ROW LEVEL SECURITY;
CREATE POLICY creation_requests_self ON space_creation_requests USING (user_id = snippets_private.current_user_id()) WITH CHECK (user_id = snippets_private.current_user_id());
ALTER TABLE records ENABLE ROW LEVEL SECURITY; ALTER TABLE records FORCE ROW LEVEL SECURITY;
CREATE POLICY records_select ON records FOR SELECT USING (snippets_private.is_space_member(space_id));
CREATE POLICY records_write ON records FOR ALL USING (snippets_private.can_write_space(space_id)) WITH CHECK (snippets_private.can_write_space(space_id));
ALTER TABLE changes ENABLE ROW LEVEL SECURITY; ALTER TABLE changes FORCE ROW LEVEL SECURITY;
CREATE POLICY changes_select ON changes FOR SELECT USING (snippets_private.is_space_member(space_id));
CREATE POLICY changes_insert ON changes FOR INSERT WITH CHECK (snippets_private.can_write_space(space_id));
ALTER TABLE recovery_envelopes ENABLE ROW LEVEL SECURITY; ALTER TABLE recovery_envelopes FORCE ROW LEVEL SECURITY;
CREATE POLICY recovery_select ON recovery_envelopes FOR SELECT USING (snippets_private.is_space_member(space_id));
CREATE POLICY recovery_write ON recovery_envelopes FOR ALL USING (snippets_private.owns_space(space_id)) WITH CHECK (snippets_private.owns_space(space_id));
ALTER TABLE pairings ENABLE ROW LEVEL SECURITY; ALTER TABLE pairings FORCE ROW LEVEL SECURITY;
CREATE POLICY pairings_select ON pairings FOR SELECT USING (snippets_private.is_space_member(space_id));
CREATE POLICY pairings_write ON pairings FOR ALL USING (snippets_private.can_write_space(space_id)) WITH CHECK (snippets_private.can_write_space(space_id));

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA snippets_private FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA snippets_private FROM PUBLIC;
GRANT USAGE ON SCHEMA public, snippets_private TO snippets_runtime;
GRANT EXECUTE ON FUNCTION snippets_private.current_user_id(), snippets_private.is_space_member(uuid),
  snippets_private.is_personal_space_owner(uuid), snippets_private.can_write_space(uuid), snippets_private.owns_space(uuid),
  snippets_private.resolve_identity(bytea, uuid), snippets_private.lock_storage_quota(uuid),
  snippets_private.record_write_within_quota(uuid, bigint, bigint, bigint),
  snippets_private.compact_change_history_if_needed(uuid, bigint, bigint), snippets_private.is_access_token_revoked(bytea),
  snippets_private.revoke_access_token(bytea, timestamptz) TO snippets_runtime;
GRANT SELECT ON users TO snippets_runtime;
GRANT SELECT ON snippets_private.schema_migrations TO snippets_runtime;
GRANT SELECT ON spaces, space_memberships, space_creation_requests, records, changes, recovery_envelopes, pairings TO snippets_runtime;
GRANT INSERT (id, owner_user_id, dataset_generation, feed_epoch, key_epoch, next_sequence) ON spaces TO snippets_runtime;
GRANT INSERT ON space_memberships, space_creation_requests, records, changes, recovery_envelopes, pairings TO snippets_runtime;
GRANT UPDATE (next_sequence) ON spaces TO snippets_runtime;
GRANT UPDATE (rev, deleted, blob, record_generation, last_sequence, updated_at) ON records TO snippets_runtime;
GRANT UPDATE (version, key_epoch, algorithm, ciphertext, created_at, updated_at) ON recovery_envelopes TO snippets_runtime;
GRANT UPDATE (algorithm, ciphertext, approved_at) ON pairings TO snippets_runtime;
GRANT DELETE ON pairings TO snippets_runtime;

-- Deliberately not granted to snippets_runtime: only the database owner
-- invokes restore rotation after verified restore or accepted data loss.
REVOKE ALL ON FUNCTION snippets_private.rotate_dataset_after_restore(uuid) FROM snippets_runtime;

COMMIT;
