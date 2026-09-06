-- First-party email authentication is isolated from tenant tables. The application
-- role can invoke only the bounded operations below, never enumerate credentials.
CREATE TABLE snippets_private.native_accounts (
 id uuid PRIMARY KEY, email_digest bytea UNIQUE NOT NULL CHECK(octet_length(email_digest)=32),
 email text NOT NULL CHECK(octet_length(email)<=254), created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE snippets_private.native_challenges (
 digest bytea PRIMARY KEY CHECK(octet_length(digest)=32), email_digest bytea NOT NULL CHECK(octet_length(email_digest)=32),
 email text NOT NULL CHECK(octet_length(email)<=254), code_digest bytea NOT NULL CHECK(octet_length(code_digest)=32),
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),
 expires_at timestamptz NOT NULL, consumed boolean NOT NULL DEFAULT false
);
CREATE INDEX native_challenge_email ON snippets_private.native_challenges(email_digest);
CREATE INDEX native_challenge_expiry ON snippets_private.native_challenges(expires_at);
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

CREATE FUNCTION snippets_private.native_rate(k bytea, category text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE budget integer; window_seconds integer; value snippets_private.native_rates; now_at timestamptz := clock_timestamp();
BEGIN
 CASE category
 WHEN 'start_global' THEN budget:=1000; window_seconds:=3600;
 WHEN 'start_ip' THEN budget:=30; window_seconds:=3600;
 WHEN 'start_email_hour' THEN budget:=5; window_seconds:=3600;
 WHEN 'start_email_day' THEN budget:=10; window_seconds:=86400;
 WHEN 'start_email_cooldown' THEN budget:=1; window_seconds:=60;
 WHEN 'verify_global' THEN budget:=10000; window_seconds:=3600;
 WHEN 'verify_ip' THEN budget:=300; window_seconds:=3600;
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
 DELETE FROM snippets_private.native_challenges WHERE ctid IN (SELECT ctid FROM snippets_private.native_challenges WHERE expires_at<clock_timestamp()-interval '1 hour' LIMIT 1000);
 DELETE FROM snippets_private.native_tokens WHERE ctid IN (SELECT ctid FROM snippets_private.native_tokens WHERE kind='access_token' AND expires_at<clock_timestamp()-interval '10 minutes' LIMIT 1000);
 -- Keep credentials beyond expiry while previously admitted HTTP requests drain.
 -- The maximum request lifetime is 120 seconds; five minutes matches the denylist.
 DELETE FROM snippets_private.native_families WHERE id IN (SELECT id FROM snippets_private.native_families WHERE expires_at<clock_timestamp()-interval '5 minutes' LIMIT 100);
END $$;

CREATE FUNCTION snippets_private.native_start(d bytea,e bytea,address text,c bytea) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 DELETE FROM snippets_private.native_challenges WHERE email_digest=e;
 INSERT INTO snippets_private.native_challenges(digest,email_digest,email,code_digest,expires_at)
 VALUES(d,e,address,c,clock_timestamp()+interval '10 minutes');
END $$;
CREATE FUNCTION snippets_private.native_drop_challenge(d bytea) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 DELETE FROM snippets_private.native_challenges WHERE digest=d;
$$;
CREATE FUNCTION snippets_private.native_lock_challenge(d bytea) RETURNS SETOF snippets_private.native_challenges
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT * FROM snippets_private.native_challenges WHERE digest=d FOR UPDATE;
$$;
CREATE FUNCTION snippets_private.native_fail_challenge(d bytea) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 UPDATE snippets_private.native_challenges SET attempts=least(5,attempts+1) WHERE digest=d;
$$;
CREATE FUNCTION snippets_private.native_issue(d bytea,account uuid,family uuid,access_digest bytea,refresh_digest bytea)
RETURNS TABLE(id uuid,email text,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE challenge snippets_private.native_challenges; account_value snippets_private.native_accounts;
BEGIN
 SELECT * INTO challenge FROM snippets_private.native_challenges WHERE digest=d FOR UPDATE;
 IF NOT FOUND OR challenge.consumed OR challenge.attempts>=5 OR challenge.expires_at<=clock_timestamp() THEN RETURN; END IF;
 UPDATE snippets_private.native_challenges SET consumed=true WHERE digest=d;
 INSERT INTO snippets_private.native_accounts(id,email_digest,email) VALUES(account,challenge.email_digest,challenge.email)
 ON CONFLICT(email_digest) DO UPDATE SET email=EXCLUDED.email RETURNING * INTO account_value;
 INSERT INTO snippets_private.native_families(id,account_id,expires_at) VALUES(family,account_value.id,clock_timestamp()+interval '30 days');
 INSERT INTO snippets_private.native_tokens VALUES(access_digest,family,'access_token',clock_timestamp()+interval '5 minutes',false),
 (refresh_digest,family,'refresh_token',clock_timestamp()+interval '30 days',false);
 RETURN QUERY SELECT account_value.id,account_value.email,t.expires_at FROM snippets_private.native_tokens t WHERE t.digest=access_digest;
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
RETURNS TABLE(id uuid,email text,expires_at timestamptz)
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
 RETURN QUERY SELECT a.id,a.email,t.expires_at FROM snippets_private.native_accounts a, snippets_private.native_tokens t WHERE a.id=family.account_id AND t.digest=access_digest;
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
  IF candidate.proname <> 'native_revoke_family' THEN
   EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO snippets_runtime',candidate.signature);
  END IF;
 END LOOP;
END $$;
