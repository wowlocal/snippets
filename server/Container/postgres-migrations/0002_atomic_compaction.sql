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

ALTER TABLE pairings
  ADD COLUMN IF NOT EXISTS claimed_by_user_id uuid REFERENCES users(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS claimed_at timestamptz;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint
        WHERE conrelid = 'public.pairings'::regclass AND conname = 'pairings_claim_consistency'
    ) THEN
        ALTER TABLE public.pairings ADD CONSTRAINT pairings_claim_consistency
          CHECK ((claimed_by_user_id IS NULL AND claimed_at IS NULL)
              OR (claimed_by_user_id IS NOT NULL AND claimed_at IS NOT NULL
                  AND approved_at IS NOT NULL));
    END IF;
END
$$;

DROP FUNCTION IF EXISTS snippets_private.compact_change_history_if_needed(uuid, bigint, bigint);
CREATE OR REPLACE FUNCTION snippets_private.compact_change_history_if_needed(
    target_space uuid, current_byte_delta bigint, new_change_bytes bigint,
    record_count_delta bigint, force_for_capacity boolean
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
    owner_id uuid; current_bytes bigint; history_bytes bigint; records_count bigint;
    changes_count bigint; owner_bytes bigint; write_fits boolean;
BEGIN
    IF current_byte_delta NOT BETWEEN -900256 AND 900256
       OR new_change_bytes NOT BETWEEN 0 AND 900256 OR record_count_delta NOT IN (0, 1)
       OR NOT snippets_private.can_write_space(target_space) THEN RETURN false; END IF;
    SELECT owner_user_id, current_record_bytes, change_history_bytes, record_count, change_count
      INTO owner_id, current_bytes, history_bytes, records_count, changes_count
      FROM public.spaces WHERE id = target_space FOR UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;
    SELECT storage_bytes INTO owner_bytes FROM public.users WHERE id = owner_id FOR UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;

    write_fits := current_bytes + current_byte_delta >= 0
      AND current_bytes + current_byte_delta + history_bytes + new_change_bytes <= 536870912
      AND records_count + record_count_delta <= 100000 AND changes_count + 1 <= 250000
      AND owner_bytes + current_byte_delta + new_change_bytes BETWEEN 0 AND 2147483648;

    IF force_for_capacity THEN
        IF write_fits OR (history_bytes <= current_bytes AND changes_count <= records_count)
           OR current_bytes * 2 + current_byte_delta + new_change_bytes > 536870912
           OR records_count + record_count_delta > 100000
           OR records_count + 1 > 250000
           OR owner_bytes - history_bytes + current_bytes + current_byte_delta + new_change_bytes
                NOT BETWEEN 0 AND 2147483648 THEN
            RETURN false;
        END IF;
    ELSE
        IF current_byte_delta <> 0 OR new_change_bytes <> 0 OR record_count_delta <> 0 THEN RETURN false; END IF;
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

REVOKE ALL ON FUNCTION snippets_private.compact_change_history_if_needed(uuid, bigint, bigint, bigint, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION snippets_private.compact_change_history_if_needed(uuid, bigint, bigint, bigint, boolean) TO snippets_runtime;
GRANT UPDATE (claimed_by_user_id, claimed_at) ON pairings TO snippets_runtime;

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
ALTER FUNCTION snippets_private.record_write_within_quota(uuid, bigint, bigint, bigint) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.compact_change_history_if_needed(uuid, bigint, bigint, bigint, boolean) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_record_storage() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_change_storage() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_deleted_space_storage() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.rotate_dataset_after_restore(uuid) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.is_access_token_revoked(bytea) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.revoke_access_token(bytea, timestamptz) OWNER TO snippets_function_owner;

DO $$
BEGIN
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION snippets_private.rotate_dataset_after_restore(uuid) TO %I',
        current_user
    );
END
$$;

INSERT INTO snippets_private.schema_migrations(version) VALUES (2)
ON CONFLICT (version) DO NOTHING;
