CREATE OR REPLACE FUNCTION snippets_private.rotate_dataset_after_restore(target_space uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    new_dataset uuid := gen_random_uuid();
    new_feed uuid := gen_random_uuid();
BEGIN
    UPDATE public.spaces
       SET dataset_generation = new_dataset,
           feed_epoch = new_feed,
           next_sequence = 0
     WHERE id = target_space;
    IF NOT FOUND THEN RAISE EXCEPTION 'space not found' USING ERRCODE = 'P0002'; END IF;
    DELETE FROM public.changes WHERE space_id = target_space;
    -- Invalidate every pre-restore CAS token. A reset version is high-entropy,
    -- unique in the space, and intentionally opaque; the next accepted write
    -- replaces it with the service's normal HMAC-bound version token.
    UPDATE public.records
       SET record_generation = record_generation + 1,
           record_version = 'reset.' || new_dataset::text || '.' || gen_random_uuid()::text,
           last_sequence = 0,
           updated_at = clock_timestamp()
     WHERE space_id = target_space;
END
$$;

REVOKE ALL ON FUNCTION snippets_private.rotate_dataset_after_restore(uuid) FROM PUBLIC;
-- Deliberately not granted to snippets_runtime. Only the migration/operator
-- owner may invoke this after a verified restore or accepted-data loss.
