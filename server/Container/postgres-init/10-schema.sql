BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'snippets_function_owner') THEN
        EXECUTE 'CREATE ROLE snippets_function_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles
        WHERE rolname = 'snippets_function_owner' AND rolbypassrls AND NOT rolcanlogin
    ) THEN
        RAISE EXCEPTION 'snippets_function_owner must be NOLOGIN BYPASSRLS';
    END IF;
END
$$;

CREATE SCHEMA snippets_private;
REVOKE ALL ON SCHEMA snippets_private FROM PUBLIC;

CREATE TABLE snippets_private.schema_migrations (
    version bigint PRIMARY KEY CHECK (version > 0),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
-- This is the first deployable Snippets Cloud schema. Pre-launch candidate
-- histories were squashed, so production migration numbering starts here.
INSERT INTO snippets_private.schema_migrations(version) VALUES (1);

CREATE TABLE snippets_private.schema_migration_checksums (
    version bigint PRIMARY KEY REFERENCES snippets_private.schema_migrations(version),
    checksum text NOT NULL CHECK (checksum ~ '^[0-9a-f]{64}$')
);

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
    claimed_by_user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    claimed_at timestamptz,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (space_id, pairing_id),
    CHECK ((approved_at IS NULL AND algorithm IS NULL AND ciphertext IS NULL)
        OR (approved_at IS NOT NULL AND algorithm IS NOT NULL AND ciphertext IS NOT NULL)),
    CONSTRAINT pairings_claim_consistency CHECK ((claimed_by_user_id IS NULL AND claimed_at IS NULL)
        OR (claimed_by_user_id IS NOT NULL AND claimed_at IS NOT NULL AND approved_at IS NOT NULL))
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

CREATE OR REPLACE FUNCTION snippets_private.batch_write_within_quota(
    target_space uuid, current_byte_delta bigint, new_change_bytes bigint,
    record_count_delta bigint, change_count_delta bigint, after_compaction boolean
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE owner_id uuid; current_bytes bigint; history_bytes bigint; records_count bigint; changes_count bigint; owner_bytes bigint;
BEGIN
    IF current_byte_delta NOT BETWEEN -45012800 AND 45012800
       OR new_change_bytes NOT BETWEEN 0 AND 45012800
       OR record_count_delta NOT BETWEEN 0 AND 50 OR change_count_delta NOT BETWEEN 0 AND 50
       OR NOT snippets_private.can_write_space(target_space) THEN RETURN false; END IF;
    SELECT owner_user_id, current_record_bytes, change_history_bytes, record_count, change_count
      INTO owner_id, current_bytes, history_bytes, records_count, changes_count
      FROM public.spaces WHERE id = target_space;
    IF NOT FOUND THEN RETURN false; END IF;
    SELECT storage_bytes INTO owner_bytes FROM public.users WHERE id = owner_id;
    IF NOT FOUND THEN RETURN false; END IF;
    IF after_compaction THEN
        IF history_bytes <= current_bytes AND changes_count <= records_count THEN RETURN false; END IF;
        owner_bytes := owner_bytes - history_bytes + current_bytes;
        history_bytes := current_bytes;
        changes_count := records_count;
    END IF;
    RETURN current_bytes + current_byte_delta >= 0
       AND current_bytes + current_byte_delta + history_bytes + new_change_bytes <= 536870912
       AND records_count + record_count_delta <= 100000
       AND changes_count + change_count_delta <= 250000
       AND owner_bytes + current_byte_delta + new_change_bytes BETWEEN 0 AND 2147483648;
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.compact_change_history_if_needed(
    target_space uuid, current_byte_delta bigint, new_change_bytes bigint,
    record_count_delta bigint, change_count_delta bigint, force_for_capacity boolean
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
    owner_id uuid; current_bytes bigint; history_bytes bigint; records_count bigint;
    changes_count bigint; owner_bytes bigint; write_fits boolean;
BEGIN
    IF current_byte_delta NOT BETWEEN -45012800 AND 45012800
       OR new_change_bytes NOT BETWEEN 0 AND 45012800
       OR record_count_delta NOT BETWEEN 0 AND 50 OR change_count_delta NOT BETWEEN 0 AND 50
       OR NOT snippets_private.can_write_space(target_space) THEN RETURN false; END IF;
    SELECT owner_user_id, current_record_bytes, change_history_bytes, record_count, change_count
      INTO owner_id, current_bytes, history_bytes, records_count, changes_count
      FROM public.spaces WHERE id = target_space FOR UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;
    SELECT storage_bytes INTO owner_bytes FROM public.users WHERE id = owner_id FOR UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;

    IF force_for_capacity THEN
        -- Preflight selected the complete deterministic subset. Rebuild at most
        -- once, and only when the whole subset fits after reclaiming history.
        write_fits := current_bytes + current_byte_delta >= 0
          AND current_bytes * 2 + current_byte_delta + new_change_bytes <= 536870912
          AND records_count + record_count_delta <= 100000
          AND records_count + change_count_delta <= 250000
          AND owner_bytes - history_bytes + current_bytes + current_byte_delta + new_change_bytes
                BETWEEN 0 AND 2147483648;
        IF NOT write_fits OR (history_bytes <= current_bytes AND changes_count <= records_count)
           OR records_count + record_count_delta > 100000
           OR records_count + change_count_delta > 250000 THEN
            RETURN false;
        END IF;
    ELSE
        IF current_byte_delta <> 0 OR new_change_bytes <> 0 OR record_count_delta <> 0
           OR change_count_delta <> 0 THEN RETURN false; END IF;
        -- High-water plus a minimum reclaimable delta provides hysteresis. A
        -- baseline by itself can never trigger another identical compaction.
        IF (changes_count <= 200000 AND current_bytes + history_bytes <= 503316480)
           OR (history_bytes - current_bytes < 33554432
               AND changes_count - records_count < 25000)
           OR current_bytes * 2 > 536870912 OR records_count > 250000
           OR owner_bytes - history_bytes + current_bytes NOT BETWEEN 0 AND 2147483648 THEN
            RETURN false;
        END IF;
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

CREATE OR REPLACE FUNCTION snippets_private.account_record_storage_inserted() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
    WITH deltas AS (
        SELECT space_id, sum(octet_length(blob) + octet_length(rev))::bigint AS byte_delta,
          count(*)::bigint AS count_delta FROM new_records GROUP BY space_id
    ), updated_spaces AS (
        UPDATE public.spaces AS spaces SET
          current_record_bytes = spaces.current_record_bytes + deltas.byte_delta,
          record_count = spaces.record_count + deltas.count_delta
        FROM deltas WHERE spaces.id = deltas.space_id
        RETURNING spaces.owner_user_id, deltas.byte_delta
    ), owner_deltas AS (
        SELECT owner_user_id, sum(byte_delta)::bigint AS byte_delta FROM updated_spaces GROUP BY owner_user_id
    )
    UPDATE public.users AS users SET storage_bytes = users.storage_bytes + owner_deltas.byte_delta
      FROM owner_deltas WHERE users.id = owner_deltas.owner_user_id;
    RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.account_record_storage_deleted() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
    WITH deltas AS (
        SELECT space_id, -sum(octet_length(blob) + octet_length(rev))::bigint AS byte_delta,
          -count(*)::bigint AS count_delta FROM old_records GROUP BY space_id
    ), updated_spaces AS (
        UPDATE public.spaces AS spaces SET
          current_record_bytes = spaces.current_record_bytes + deltas.byte_delta,
          record_count = spaces.record_count + deltas.count_delta
        FROM deltas WHERE spaces.id = deltas.space_id
        RETURNING spaces.owner_user_id, deltas.byte_delta
    ), owner_deltas AS (
        SELECT owner_user_id, sum(byte_delta)::bigint AS byte_delta FROM updated_spaces GROUP BY owner_user_id
    )
    UPDATE public.users AS users SET storage_bytes = users.storage_bytes + owner_deltas.byte_delta
      FROM owner_deltas WHERE users.id = owner_deltas.owner_user_id;
    RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.account_record_storage_updated() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE byte_delta bigint; owner_id uuid;
BEGIN
    byte_delta := octet_length(NEW.blob) + octet_length(NEW.rev)
      - octet_length(OLD.blob) - octet_length(OLD.rev);
    IF byte_delta = 0 THEN RETURN NEW; END IF;
    UPDATE public.spaces SET current_record_bytes = current_record_bytes + byte_delta
      WHERE id = NEW.space_id RETURNING owner_user_id INTO owner_id;
    IF FOUND THEN
        UPDATE public.users SET storage_bytes = storage_bytes + byte_delta WHERE id = owner_id;
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.account_change_storage_inserted() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
    WITH deltas AS (
        SELECT space_id, sum(octet_length(blob) + octet_length(rev))::bigint AS byte_delta,
          count(*)::bigint AS count_delta FROM new_changes GROUP BY space_id
    ), updated_spaces AS (
        UPDATE public.spaces AS spaces SET
          change_history_bytes = spaces.change_history_bytes + deltas.byte_delta,
          change_count = spaces.change_count + deltas.count_delta
        FROM deltas WHERE spaces.id = deltas.space_id
        RETURNING spaces.owner_user_id, deltas.byte_delta
    ), owner_deltas AS (
        SELECT owner_user_id, sum(byte_delta)::bigint AS byte_delta FROM updated_spaces GROUP BY owner_user_id
    )
    UPDATE public.users AS users SET storage_bytes = users.storage_bytes + owner_deltas.byte_delta
      FROM owner_deltas WHERE users.id = owner_deltas.owner_user_id;
    RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.account_change_storage_deleted() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
    WITH deltas AS (
        SELECT space_id, -sum(octet_length(blob) + octet_length(rev))::bigint AS byte_delta,
          -count(*)::bigint AS count_delta FROM old_changes GROUP BY space_id
    ), updated_spaces AS (
        UPDATE public.spaces AS spaces SET
          change_history_bytes = spaces.change_history_bytes + deltas.byte_delta,
          change_count = spaces.change_count + deltas.count_delta
        FROM deltas WHERE spaces.id = deltas.space_id
        RETURNING spaces.owner_user_id, deltas.byte_delta
    ), owner_deltas AS (
        SELECT owner_user_id, sum(byte_delta)::bigint AS byte_delta FROM updated_spaces GROUP BY owner_user_id
    )
    UPDATE public.users AS users SET storage_bytes = users.storage_bytes + owner_deltas.byte_delta
      FROM owner_deltas WHERE users.id = owner_deltas.owner_user_id;
    RETURN NULL;
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

CREATE OR REPLACE FUNCTION snippets_private.claim_pairing_for_current_user(
    target_space uuid, target_pairing uuid
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE claimant uuid;
BEGIN
    claimant := snippets_private.current_user_id();
    IF claimant IS NULL OR NOT snippets_private.is_space_member(target_space) THEN RETURN false; END IF;
    UPDATE public.pairings SET claimed_by_user_id = claimant, claimed_at = clock_timestamp()
      WHERE space_id = target_space AND pairing_id = target_pairing
        AND approved_at IS NOT NULL AND expires_at > clock_timestamp()
        AND (claimed_by_user_id IS NULL OR claimed_by_user_id = claimant);
    RETURN FOUND;
END
$$;

CREATE TRIGGER records_storage_accounting_insert AFTER INSERT ON records
REFERENCING NEW TABLE AS new_records FOR EACH STATEMENT
EXECUTE FUNCTION snippets_private.account_record_storage_inserted();
CREATE TRIGGER records_storage_accounting_update AFTER UPDATE OF rev, blob ON records
FOR EACH ROW
EXECUTE FUNCTION snippets_private.account_record_storage_updated();
CREATE TRIGGER records_storage_accounting_delete AFTER DELETE ON records
REFERENCING OLD TABLE AS old_records FOR EACH STATEMENT
EXECUTE FUNCTION snippets_private.account_record_storage_deleted();
CREATE TRIGGER changes_storage_accounting_insert AFTER INSERT ON changes
REFERENCING NEW TABLE AS new_changes FOR EACH STATEMENT
EXECUTE FUNCTION snippets_private.account_change_storage_inserted();
CREATE TRIGGER changes_storage_accounting_delete AFTER DELETE ON changes
REFERENCING OLD TABLE AS old_changes FOR EACH STATEMENT
EXECUTE FUNCTION snippets_private.account_change_storage_deleted();
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

GRANT USAGE ON SCHEMA public TO snippets_function_owner;
GRANT USAGE, CREATE ON SCHEMA snippets_private TO snippets_function_owner;
GRANT SELECT, INSERT, UPDATE, DELETE ON users, identities, spaces, space_memberships,
  space_creation_requests, records, changes, recovery_envelopes, pairings TO snippets_function_owner;
GRANT SELECT, INSERT, UPDATE, DELETE ON snippets_private.revoked_access_tokens TO snippets_function_owner;
ALTER FUNCTION snippets_private.current_user_id() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.is_space_member(uuid) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.is_personal_space_owner(uuid) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.can_write_space(uuid) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.owns_space(uuid) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.resolve_identity(bytea, uuid) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.lock_storage_quota(uuid) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.batch_write_within_quota(uuid, bigint, bigint, bigint, bigint, boolean) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.compact_change_history_if_needed(uuid, bigint, bigint, bigint, bigint, boolean) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_record_storage_inserted() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_record_storage_deleted() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_record_storage_updated() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_change_storage_inserted() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_change_storage_deleted() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_deleted_space_storage() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.rotate_dataset_after_restore(uuid) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.is_access_token_revoked(bytea) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.revoke_access_token(bytea, timestamptz) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.claim_pairing_for_current_user(uuid, uuid) OWNER TO snippets_function_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA snippets_private FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA snippets_private FROM PUBLIC;
GRANT USAGE ON SCHEMA public, snippets_private TO snippets_runtime;
GRANT EXECUTE ON FUNCTION snippets_private.current_user_id(), snippets_private.is_space_member(uuid),
  snippets_private.is_personal_space_owner(uuid), snippets_private.can_write_space(uuid), snippets_private.owns_space(uuid),
  snippets_private.resolve_identity(bytea, uuid), snippets_private.lock_storage_quota(uuid),
  snippets_private.batch_write_within_quota(uuid, bigint, bigint, bigint, bigint, boolean),
  snippets_private.compact_change_history_if_needed(uuid, bigint, bigint, bigint, bigint, boolean), snippets_private.is_access_token_revoked(bytea),
  snippets_private.revoke_access_token(bytea, timestamptz),
  snippets_private.claim_pairing_for_current_user(uuid, uuid) TO snippets_runtime;
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
DO $$
BEGIN
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION snippets_private.rotate_dataset_after_restore(uuid) TO %I',
        current_user
    );
END
$$;

COMMIT;
