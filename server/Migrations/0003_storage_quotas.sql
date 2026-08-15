-- Payload-byte quotas are paired with row-count quotas so both large blobs and
-- tiny-row overhead remain bounded. Keep these constants synchronized with
-- SyncLimits in Sources/SyncDomain/Models.swift.
ALTER TABLE users
    ADD COLUMN storage_bytes bigint NOT NULL DEFAULT 0 CHECK (
        storage_bytes BETWEEN 0 AND 2147483648
    );

ALTER TABLE spaces
    ADD COLUMN current_record_bytes bigint NOT NULL DEFAULT 0,
    ADD COLUMN change_history_bytes bigint NOT NULL DEFAULT 0,
    ADD COLUMN record_count bigint NOT NULL DEFAULT 0,
    ADD COLUMN change_count bigint NOT NULL DEFAULT 0;

WITH usage AS (
    SELECT space_id,
           count(*) AS row_count,
           coalesce(sum(octet_length(blob) + octet_length(rev) + octet_length(record_version)), 0) AS payload_bytes
      FROM records
     GROUP BY space_id
)
UPDATE spaces s
   SET current_record_bytes = usage.payload_bytes,
       record_count = usage.row_count
  FROM usage
 WHERE s.id = usage.space_id;

WITH usage AS (
    SELECT space_id,
           count(*) AS row_count,
           coalesce(sum(octet_length(blob) + octet_length(rev) + octet_length(record_version)), 0) AS payload_bytes
      FROM changes
     GROUP BY space_id
)
UPDATE spaces s
   SET change_history_bytes = usage.payload_bytes,
       change_count = usage.row_count
  FROM usage
 WHERE s.id = usage.space_id;

UPDATE users u
   SET storage_bytes = usage.payload_bytes
  FROM (
      SELECT owner_user_id,
             coalesce(sum(current_record_bytes + change_history_bytes), 0) AS payload_bytes
        FROM spaces
       GROUP BY owner_user_id
  ) usage
 WHERE u.id = usage.owner_user_id;

ALTER TABLE spaces
    ADD CONSTRAINT spaces_current_record_bytes_quota CHECK (
        current_record_bytes BETWEEN 0 AND 536870912
    ),
    ADD CONSTRAINT spaces_change_history_bytes_quota CHECK (
        change_history_bytes BETWEEN 0 AND 536870912
    ),
    ADD CONSTRAINT spaces_total_storage_bytes_quota CHECK (
        current_record_bytes + change_history_bytes <= 536870912
    ),
    ADD CONSTRAINT spaces_record_count_quota CHECK (
        record_count BETWEEN 0 AND 100000
    ),
    ADD CONSTRAINT spaces_change_count_quota CHECK (
        change_count BETWEEN 0 AND 250000
    );

CREATE OR REPLACE FUNCTION snippets_private.lock_storage_quota(target_space uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    owner_id uuid;
BEGIN
    IF NOT snippets_private.can_write_space(target_space) THEN RETURN false; END IF;
    SELECT owner_user_id INTO owner_id
      FROM public.spaces
     WHERE id = target_space
     FOR UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;
    PERFORM 1 FROM public.users WHERE id = owner_id FOR UPDATE;
    RETURN FOUND;
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.record_write_within_quota(
    target_space uuid,
    current_byte_delta bigint,
    new_change_bytes bigint,
    record_count_delta bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    owner_id uuid;
    space_current_bytes bigint;
    space_history_bytes bigint;
    space_records bigint;
    space_changes bigint;
    owner_bytes bigint;
BEGIN
    IF current_byte_delta NOT BETWEEN -1000000 AND 1000000
       OR new_change_bytes NOT BETWEEN 1 AND 1000000
       OR record_count_delta NOT IN (0, 1)
       OR NOT snippets_private.can_write_space(target_space) THEN
        RETURN false;
    END IF;

    SELECT owner_user_id, current_record_bytes, change_history_bytes, record_count, change_count
      INTO owner_id, space_current_bytes, space_history_bytes, space_records, space_changes
      FROM public.spaces
     WHERE id = target_space
     FOR UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;

    SELECT storage_bytes INTO owner_bytes
      FROM public.users
     WHERE id = owner_id
     FOR UPDATE;
    IF NOT FOUND THEN RETURN false; END IF;

    RETURN space_current_bytes + current_byte_delta >= 0
       AND space_current_bytes + current_byte_delta + space_history_bytes + new_change_bytes <= 536870912
       AND space_records + record_count_delta <= 100000
       AND space_changes + 1 <= 250000
       AND owner_bytes + current_byte_delta + new_change_bytes BETWEEN 0 AND 2147483648;
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.account_record_storage()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    byte_delta bigint;
    count_delta bigint;
    owner_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        byte_delta := octet_length(NEW.blob) + octet_length(NEW.rev) + octet_length(NEW.record_version);
        count_delta := 1;
    ELSIF TG_OP = 'UPDATE' THEN
        byte_delta := octet_length(NEW.blob) + octet_length(NEW.rev) + octet_length(NEW.record_version)
                    - octet_length(OLD.blob) - octet_length(OLD.rev) - octet_length(OLD.record_version);
        count_delta := 0;
    ELSE
        byte_delta := -octet_length(OLD.blob) - octet_length(OLD.rev) - octet_length(OLD.record_version);
        count_delta := -1;
    END IF;

    UPDATE public.spaces
       SET current_record_bytes = current_record_bytes + byte_delta,
           record_count = record_count + count_delta
     WHERE id = coalesce(NEW.space_id, OLD.space_id)
     RETURNING owner_user_id INTO owner_id;
    IF FOUND THEN
        UPDATE public.users SET storage_bytes = storage_bytes + byte_delta WHERE id = owner_id;
    END IF;
    RETURN coalesce(NEW, OLD);
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.account_change_storage()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    byte_delta bigint;
    count_delta bigint;
    owner_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        byte_delta := octet_length(NEW.blob) + octet_length(NEW.rev) + octet_length(NEW.record_version);
        count_delta := 1;
    ELSE
        byte_delta := -octet_length(OLD.blob) - octet_length(OLD.rev) - octet_length(OLD.record_version);
        count_delta := -1;
    END IF;

    UPDATE public.spaces
       SET change_history_bytes = change_history_bytes + byte_delta,
           change_count = change_count + count_delta
     WHERE id = coalesce(NEW.space_id, OLD.space_id)
     RETURNING owner_user_id INTO owner_id;
    IF FOUND THEN
        UPDATE public.users SET storage_bytes = storage_bytes + byte_delta WHERE id = owner_id;
    END IF;
    RETURN coalesce(NEW, OLD);
END
$$;

CREATE OR REPLACE FUNCTION snippets_private.account_deleted_space_storage()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    UPDATE public.users
       SET storage_bytes = storage_bytes - OLD.current_record_bytes - OLD.change_history_bytes
     WHERE id = OLD.owner_user_id;
    RETURN OLD;
END
$$;

CREATE TRIGGER records_storage_accounting
AFTER INSERT OR UPDATE OR DELETE ON records
FOR EACH ROW EXECUTE FUNCTION snippets_private.account_record_storage();

CREATE TRIGGER changes_storage_accounting
AFTER INSERT OR DELETE ON changes
FOR EACH ROW EXECUTE FUNCTION snippets_private.account_change_storage();

CREATE TRIGGER spaces_storage_accounting
BEFORE DELETE ON spaces
FOR EACH ROW EXECUTE FUNCTION snippets_private.account_deleted_space_storage();

REVOKE ALL ON FUNCTION snippets_private.record_write_within_quota(uuid, bigint, bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.lock_storage_quota(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.account_record_storage() FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.account_change_storage() FROM PUBLIC;
REVOKE ALL ON FUNCTION snippets_private.account_deleted_space_storage() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION snippets_private.record_write_within_quota(uuid, bigint, bigint, bigint) TO snippets_runtime;
GRANT EXECUTE ON FUNCTION snippets_private.lock_storage_quota(uuid) TO snippets_runtime;

-- Earlier table-level grants predate the accounting columns. Narrow them so
-- the runtime role cannot forge counters or move rows between spaces while
-- still permitting the exact statements issued by PostgresSyncStore.
REVOKE INSERT ON spaces FROM snippets_runtime;
GRANT INSERT (id, owner_user_id, dataset_generation, feed_epoch, key_epoch, next_sequence)
    ON spaces TO snippets_runtime;
REVOKE UPDATE ON records FROM snippets_runtime;
GRANT UPDATE (
    rev, deleted, blob, record_generation, record_version, last_sequence, updated_at
) ON records TO snippets_runtime;
REVOKE UPDATE ON key_envelopes FROM snippets_runtime;
GRANT UPDATE (version, key_epoch, algorithm, ciphertext, created_at, updated_at)
    ON key_envelopes TO snippets_runtime;
REVOKE UPDATE ON pairings FROM snippets_runtime;
GRANT UPDATE (algorithm, ciphertext, approved_at) ON pairings TO snippets_runtime;
