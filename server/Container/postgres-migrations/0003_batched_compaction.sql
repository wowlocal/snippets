DROP TRIGGER IF EXISTS records_storage_accounting ON records;
DROP TRIGGER IF EXISTS changes_storage_accounting ON changes;
DROP FUNCTION IF EXISTS snippets_private.account_record_storage();
DROP FUNCTION IF EXISTS snippets_private.account_change_storage();
DROP FUNCTION IF EXISTS snippets_private.record_write_within_quota(uuid, bigint, bigint, bigint);
DROP FUNCTION IF EXISTS snippets_private.compact_change_history_if_needed(uuid, bigint, bigint, bigint, boolean);

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

REVOKE UPDATE (claimed_by_user_id, claimed_at) ON pairings FROM snippets_runtime;
REVOKE ALL ON FUNCTION snippets_private.batch_write_within_quota(uuid, bigint, bigint, bigint, bigint, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.compact_change_history_if_needed(uuid, bigint, bigint, bigint, bigint, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.claim_pairing_for_current_user(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.account_record_storage_inserted() FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.account_record_storage_deleted() FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.account_record_storage_updated() FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.account_change_storage_inserted() FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.account_change_storage_deleted() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION snippets_private.batch_write_within_quota(uuid, bigint, bigint, bigint, bigint, boolean) TO snippets_runtime;
GRANT EXECUTE ON FUNCTION snippets_private.compact_change_history_if_needed(uuid, bigint, bigint, bigint, bigint, boolean) TO snippets_runtime;
GRANT EXECUTE ON FUNCTION snippets_private.claim_pairing_for_current_user(uuid, uuid) TO snippets_runtime;

ALTER FUNCTION snippets_private.batch_write_within_quota(uuid, bigint, bigint, bigint, bigint, boolean) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.compact_change_history_if_needed(uuid, bigint, bigint, bigint, bigint, boolean) OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_record_storage_inserted() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_record_storage_deleted() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_record_storage_updated() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_change_storage_inserted() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.account_change_storage_deleted() OWNER TO snippets_function_owner;
ALTER FUNCTION snippets_private.claim_pairing_for_current_user(uuid, uuid) OWNER TO snippets_function_owner;

INSERT INTO snippets_private.schema_migrations(version) VALUES (3)
ON CONFLICT (version) DO NOTHING;
