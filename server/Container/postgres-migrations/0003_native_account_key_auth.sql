-- First-party account-key authentication is isolated from tenant tables. The application
-- role can invoke only the bounded operations below, never enumerate credentials.
-- Accounts hold no personal identifier: only a peppered digest of the generated key.
CREATE TABLE snippets_private.native_accounts (
 id uuid PRIMARY KEY, key_digest bytea UNIQUE NOT NULL CHECK(octet_length(key_digest)=32),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE snippets_private.native_families (
 id uuid PRIMARY KEY, account_id uuid NOT NULL REFERENCES snippets_private.native_accounts(id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(), expires_at timestamptz NOT NULL,
 revoked boolean NOT NULL DEFAULT false
);
CREATE INDEX native_family_expiry ON snippets_private.native_families(expires_at);
CREATE TABLE snippets_private.native_tokens (
 digest bytea PRIMARY KEY CHECK(octet_length(digest)=32), family_id uuid NOT NULL REFERENCES snippets_private.native_families(id) ON DELETE CASCADE,
 kind text NOT NULL CHECK(kind IN ('access_token','refresh_token')), expires_at timestamptz NOT NULL,
 used boolean NOT NULL DEFAULT false
);
CREATE INDEX native_token_family ON snippets_private.native_tokens(family_id);
CREATE INDEX native_token_expiry ON snippets_private.native_tokens(expires_at);
CREATE TABLE snippets_private.native_rates (
 digest bytea NOT NULL CHECK(octet_length(digest)=32), kind text NOT NULL,
 started_at timestamptz NOT NULL, expires_at timestamptz NOT NULL, count integer NOT NULL,
 PRIMARY KEY(digest,kind)
);
CREATE INDEX native_rate_expiry ON snippets_private.native_rates(expires_at);
-- Device-approved sign-in (ADR 0007). A signed-out device opens a request; an approved
-- device binds it to its account only after approving a pairing for the same recipient
-- key and nonce. Only the requesting device holds the poll token.
CREATE TABLE snippets_private.native_device_requests (
 id uuid PRIMARY KEY, poll_digest bytea NOT NULL CHECK(octet_length(poll_digest)=32),
 recipient_key_hash bytea NOT NULL CHECK(octet_length(recipient_key_hash)=32),
 nonce bytea NOT NULL CHECK(octet_length(nonce)=32), expires_at timestamptz NOT NULL,
 account_id uuid REFERENCES snippets_private.native_accounts(id) ON DELETE CASCADE,
 space_id uuid, pairing_id uuid, approved_at timestamptz,
 family_id uuid REFERENCES snippets_private.native_families(id) ON DELETE SET NULL,
 claims integer NOT NULL DEFAULT 0 CHECK(claims BETWEEN 0 AND 5),
 CHECK((account_id IS NULL AND space_id IS NULL AND pairing_id IS NULL AND approved_at IS NULL)
  OR (account_id IS NOT NULL AND space_id IS NOT NULL AND pairing_id IS NOT NULL AND approved_at IS NOT NULL))
);
CREATE INDEX native_device_request_expiry ON snippets_private.native_device_requests(expires_at);

CREATE FUNCTION snippets_private.native_rate(k bytea, category text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE budget integer; window_seconds integer; value snippets_private.native_rates; now_at timestamptz := clock_timestamp();
BEGIN
 CASE category
 WHEN 'create_global' THEN budget:=1000; window_seconds:=3600;
 WHEN 'create_ip' THEN budget:=10; window_seconds:=3600;
 WHEN 'sign_in_global' THEN budget:=10000; window_seconds:=3600;
 WHEN 'sign_in_ip' THEN budget:=300; window_seconds:=3600;
 WHEN 'device_request_global' THEN budget:=3000; window_seconds:=3600;
 WHEN 'device_request_ip' THEN budget:=30; window_seconds:=3600;
 WHEN 'device_claim_global' THEN budget:=100000; window_seconds:=3600;
 WHEN 'device_claim_ip' THEN budget:=1800; window_seconds:=3600;
 WHEN 'refresh_global' THEN budget:=30000; window_seconds:=3600;
 WHEN 'refresh_ip' THEN budget:=1000; window_seconds:=3600;
 ELSE RAISE EXCEPTION 'invalid rate category' USING ERRCODE='22023';
 END CASE;
 INSERT INTO snippets_private.native_rates VALUES(k,category,now_at,now_at+make_interval(secs=>window_seconds),0)
 ON CONFLICT DO NOTHING;
 SELECT * INTO value FROM snippets_private.native_rates WHERE digest=k AND kind=category FOR UPDATE;
 IF value.expires_at <= now_at THEN
  UPDATE snippets_private.native_rates SET count=1,started_at=now_at,expires_at=now_at+make_interval(secs=>window_seconds) WHERE digest=k AND kind=category;
  RETURN 0;
 END IF;
 IF value.count >= budget THEN RETURN greatest(1,ceil(extract(epoch FROM value.expires_at-now_at))::integer); END IF;
 UPDATE snippets_private.native_rates SET count=count+1 WHERE digest=k AND kind=category;
 RETURN 0;
END $$;

CREATE FUNCTION snippets_private.native_cleanup() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 -- Bounded work per invocation; hourly global admission limits bound creation.
 DELETE FROM snippets_private.native_rates WHERE ctid IN (SELECT ctid FROM snippets_private.native_rates WHERE expires_at<clock_timestamp()-interval '1 day' LIMIT 1000);
 DELETE FROM snippets_private.native_device_requests WHERE ctid IN (SELECT ctid FROM snippets_private.native_device_requests WHERE expires_at<clock_timestamp()-interval '1 hour' LIMIT 1000);
 DELETE FROM snippets_private.native_tokens WHERE ctid IN (SELECT ctid FROM snippets_private.native_tokens WHERE kind='access_token' AND expires_at<clock_timestamp()-interval '10 minutes' LIMIT 1000);
 -- Keep credentials beyond expiry while previously admitted HTTP requests drain.
 -- The maximum request lifetime is 120 seconds; five minutes matches the denylist.
 DELETE FROM snippets_private.native_families WHERE id IN (SELECT id FROM snippets_private.native_families WHERE expires_at<clock_timestamp()-interval '5 minutes' LIMIT 100);
END $$;

-- Issues one session family for an account. Both entry points share it so creation and
-- sign-in cannot diverge in token lifetimes.
CREATE FUNCTION snippets_private.native_open_family(account uuid,family uuid,access_digest bytea,refresh_digest bytea)
RETURNS TABLE(id uuid,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 INSERT INTO snippets_private.native_families(id,account_id,expires_at) VALUES(family,account,clock_timestamp()+interval '30 days');
 INSERT INTO snippets_private.native_tokens VALUES(access_digest,family,'access_token',clock_timestamp()+interval '5 minutes',false),
 (refresh_digest,family,'refresh_token',clock_timestamp()+interval '30 days',false);
 RETURN QUERY SELECT account,t.expires_at FROM snippets_private.native_tokens t WHERE t.digest=access_digest;
END $$;
-- Returns no row on a key-digest collision; the caller generates another key.
CREATE FUNCTION snippets_private.native_create(account uuid,k bytea,family uuid,access_digest bytea,refresh_digest bytea)
RETURNS TABLE(id uuid,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 INSERT INTO snippets_private.native_accounts(id,key_digest) VALUES(account,k) ON CONFLICT DO NOTHING;
 IF NOT FOUND THEN RETURN; END IF;
 RETURN QUERY SELECT * FROM snippets_private.native_open_family(account,family,access_digest,refresh_digest);
END $$;
-- Returns no row for an unknown key.
CREATE FUNCTION snippets_private.native_sign_in(k bytea,family uuid,access_digest bytea,refresh_digest bytea)
RETURNS TABLE(id uuid,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE account uuid;
BEGIN
 SELECT a.id INTO account FROM snippets_private.native_accounts a WHERE a.key_digest=k;
 IF NOT FOUND THEN RETURN; END IF;
 RETURN QUERY SELECT * FROM snippets_private.native_open_family(account,family,access_digest,refresh_digest);
END $$;

-- Caller holds the family row before revoking. Credential locks match data-plane
-- transaction locks, so revocation waits for any already-authorized writes.
CREATE FUNCTION snippets_private.native_revoke_family(f uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE token_value snippets_private.native_tokens;
BEGIN
 PERFORM 1 FROM snippets_private.native_families WHERE id=f FOR UPDATE;
 UPDATE snippets_private.native_families SET revoked=true WHERE id=f;
 FOR token_value IN SELECT * FROM snippets_private.native_tokens WHERE family_id=f AND kind='access_token' ORDER BY digest LOOP
  PERFORM pg_advisory_xact_lock(hashtextextended(encode(token_value.digest,'hex'),11));
  -- Expiry prevents new admission, but an already-admitted principal can still be
  -- waiting for its request body. Retain its denial after this acknowledged revoke.
  -- This extends only denylist retention, never the credential's authorization.
  PERFORM snippets_private.revoke_access_token(token_value.digest,greatest(token_value.expires_at,clock_timestamp()));
 END LOOP;
END $$;

CREATE FUNCTION snippets_private.native_refresh(d bytea,access_digest bytea,refresh_digest bytea)
RETURNS TABLE(id uuid,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE token_value snippets_private.native_tokens; family snippets_private.native_families;
BEGIN
 SELECT * INTO token_value FROM snippets_private.native_tokens WHERE digest=d AND kind='refresh_token';
 IF NOT FOUND THEN RETURN; END IF;
 SELECT * INTO family FROM snippets_private.native_families WHERE native_families.id=token_value.family_id FOR UPDATE;
 IF NOT FOUND OR family.revoked OR family.expires_at<=clock_timestamp() THEN RETURN; END IF;
 -- Re-read after the family lock: concurrent requests cannot reuse a refresh token.
 SELECT * INTO token_value FROM snippets_private.native_tokens WHERE digest=d;
 IF token_value.used THEN PERFORM snippets_private.native_revoke_family(family.id); RETURN; END IF;
 IF token_value.expires_at<=clock_timestamp() THEN RETURN; END IF;
 UPDATE snippets_private.native_tokens SET used=true WHERE digest=d;
 INSERT INTO snippets_private.native_tokens VALUES(access_digest,family.id,'access_token',least(family.expires_at,clock_timestamp()+interval '5 minutes'),false),
 (refresh_digest,family.id,'refresh_token',family.expires_at,false);
 RETURN QUERY SELECT family.account_id,t.expires_at FROM snippets_private.native_tokens t WHERE t.digest=access_digest;
END $$;

CREATE FUNCTION snippets_private.native_validate(d bytea)
RETURNS TABLE(id uuid,expires_at timestamptz,authenticated_at timestamptz)
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT f.account_id,t.expires_at,f.created_at FROM snippets_private.native_tokens t JOIN snippets_private.native_families f ON f.id=t.family_id
 WHERE t.digest=d AND t.kind='access_token' AND NOT t.used AND NOT f.revoked AND t.expires_at>clock_timestamp() AND f.expires_at>clock_timestamp()
 AND NOT snippets_private.is_access_token_revoked(d);
$$;
CREATE FUNCTION snippets_private.native_revoke(d bytea,hint text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE token_value snippets_private.native_tokens;
BEGIN
 SELECT * INTO token_value FROM snippets_private.native_tokens WHERE digest=d AND kind=hint;
 IF NOT FOUND THEN RETURN; END IF;
 IF hint='refresh_token' THEN PERFORM snippets_private.native_revoke_family(token_value.family_id); ELSE
  PERFORM pg_advisory_xact_lock(hashtextextended(encode(d,'hex'),11));
  UPDATE snippets_private.native_tokens SET used=true WHERE digest=d;
  PERFORM snippets_private.revoke_access_token(d,greatest(token_value.expires_at,clock_timestamp()));
 END IF;
END $$;

CREATE FUNCTION snippets_private.native_device_request(request uuid,poll bytea,key_hash bytea,request_nonce bytea)
RETURNS timestamptz
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 INSERT INTO snippets_private.native_device_requests(id,poll_digest,recipient_key_hash,nonce,expires_at)
 VALUES(request,poll,key_hash,request_nonce,clock_timestamp()+interval '10 minutes') RETURNING expires_at;
$$;
-- The caller has already proved under its own RLS identity that it can write the space
-- and that the pairing is approved for exactly this key hash and nonce. The account is
-- resolved from the presented access credential, never supplied by the caller.
CREATE FUNCTION snippets_private.native_approve_device(request uuid,credential bytea,space uuid,pairing uuid,key_hash bytea,request_nonce bytea)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE value snippets_private.native_device_requests; approver uuid;
BEGIN
 SELECT f.account_id INTO approver FROM snippets_private.native_tokens t JOIN snippets_private.native_families f ON f.id=t.family_id
 WHERE t.digest=credential AND t.kind='access_token' AND NOT t.used AND NOT f.revoked AND t.expires_at>clock_timestamp()
 AND f.expires_at>clock_timestamp() AND NOT snippets_private.is_access_token_revoked(credential);
 IF NOT FOUND THEN RETURN 'unauthenticated'; END IF;
 SELECT * INTO value FROM snippets_private.native_device_requests r WHERE r.id=request FOR UPDATE;
 IF NOT FOUND THEN RETURN 'not_found'; END IF;
 IF value.expires_at<=clock_timestamp() THEN RETURN 'expired'; END IF;
 IF value.recipient_key_hash<>key_hash OR value.nonce<>request_nonce THEN RETURN 'conflict'; END IF;
 IF value.approved_at IS NOT NULL THEN
  IF value.account_id=approver AND value.space_id=space AND value.pairing_id=pairing THEN RETURN 'approved'; END IF;
  RETURN 'conflict';
 END IF;
 UPDATE snippets_private.native_device_requests SET account_id=approver,space_id=space,pairing_id=pairing,approved_at=clock_timestamp() WHERE id=request;
 RETURN 'approved';
END $$;
-- No row means an unknown request or a wrong poll token. A repeated approved claim
-- follows a lost response: the undelivered family is revoked before a new one opens.
CREATE FUNCTION snippets_private.native_claim_device(request uuid,poll bytea,family uuid,access_digest bytea,refresh_digest bytea)
RETURNS TABLE(state text,request_expires_at timestamptz,account uuid,space uuid,pairing uuid,token_expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE value snippets_private.native_device_requests; issued timestamptz;
BEGIN
 SELECT * INTO value FROM snippets_private.native_device_requests r WHERE r.id=request FOR UPDATE;
 IF NOT FOUND OR value.poll_digest<>poll THEN RETURN; END IF;
 IF value.expires_at<=clock_timestamp() THEN
  RETURN QUERY SELECT 'expired'::text,value.expires_at,NULL::uuid,NULL::uuid,NULL::uuid,NULL::timestamptz; RETURN;
 END IF;
 IF value.approved_at IS NULL THEN
  RETURN QUERY SELECT 'pending'::text,value.expires_at,NULL::uuid,NULL::uuid,NULL::uuid,NULL::timestamptz; RETURN;
 END IF;
 IF value.claims>=5 THEN
  RETURN QUERY SELECT 'exhausted'::text,value.expires_at,NULL::uuid,NULL::uuid,NULL::uuid,NULL::timestamptz; RETURN;
 END IF;
 IF value.family_id IS NOT NULL THEN PERFORM snippets_private.native_revoke_family(value.family_id); END IF;
 SELECT o.expires_at INTO issued FROM snippets_private.native_open_family(value.account_id,family,access_digest,refresh_digest) o;
 UPDATE snippets_private.native_device_requests r SET family_id=family,claims=r.claims+1 WHERE r.id=request;
 RETURN QUERY SELECT 'approved'::text,value.expires_at,value.account_id,value.space_id,value.pairing_id,issued;
END $$;

DO $$
DECLARE candidate record;
BEGIN
 FOR candidate IN SELECT tablename FROM pg_tables WHERE schemaname='snippets_private' AND tablename LIKE 'native_%' LOOP
  EXECUTE format('ALTER TABLE snippets_private.%I ENABLE ROW LEVEL SECURITY',candidate.tablename);
  EXECUTE format('ALTER TABLE snippets_private.%I FORCE ROW LEVEL SECURITY',candidate.tablename);
  EXECUTE format('REVOKE ALL ON snippets_private.%I FROM PUBLIC, snippets_runtime',candidate.tablename);
  EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON snippets_private.%I TO snippets_function_owner',candidate.tablename);
 END LOOP;
 FOR candidate IN SELECT oid::regprocedure AS signature,proname FROM pg_proc WHERE pronamespace='snippets_private'::regnamespace AND proname LIKE 'native_%' LOOP
  EXECUTE format('ALTER FUNCTION %s OWNER TO snippets_function_owner',candidate.signature);
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC',candidate.signature);
  IF candidate.proname NOT IN ('native_revoke_family','native_open_family') THEN
   EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO snippets_runtime',candidate.signature);
  END IF;
 END LOOP;
END $$;
