-- Additive upgrade: no library, ciphertext, identity or protocol cursor is reset.
CREATE TABLE library_key_authorities (
    space_id uuid PRIMARY KEY REFERENCES spaces(id) ON DELETE CASCADE,
    public_key bytea NOT NULL CHECK (octet_length(public_key) = 32),
    key_epoch integer NOT NULL CHECK (key_epoch > 0)
);
ALTER TABLE library_key_authorities ENABLE ROW LEVEL SECURITY;
ALTER TABLE library_key_authorities FORCE ROW LEVEL SECURITY;
CREATE POLICY authority_select ON library_key_authorities FOR SELECT USING (snippets_private.is_space_member(space_id));
CREATE POLICY authority_insert ON library_key_authorities FOR INSERT WITH CHECK (snippets_private.owns_space(space_id));
GRANT SELECT, INSERT ON library_key_authorities TO snippets_runtime;

CREATE TABLE library_action_challenges (
    space_id uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    challenge_id uuid NOT NULL,
    identity_digest bytea NOT NULL CHECK (octet_length(identity_digest) = 32),
    scope_binding text NOT NULL,
    dataset_generation uuid NOT NULL,
    feed_epoch uuid NOT NULL,
    action text NOT NULL CHECK (action IN ('replace_recovery', 'approve_pairing')),
    key_epoch integer NOT NULL CHECK (key_epoch > 0),
    request_hash bytea NOT NULL CHECK (octet_length(request_hash) = 32),
    nonce bytea NOT NULL CHECK (octet_length(nonce) = 32),
    expires_at timestamptz NOT NULL,
    receipt bytea CHECK (octet_length(receipt) <= 16384),
    PRIMARY KEY (space_id, challenge_id)
);
CREATE INDEX library_action_challenges_expiry ON library_action_challenges(expires_at);
ALTER TABLE library_action_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE library_action_challenges FORCE ROW LEVEL SECURITY;
CREATE POLICY challenges_write ON library_action_challenges FOR ALL
    USING (snippets_private.can_write_space(space_id)) WITH CHECK (snippets_private.can_write_space(space_id));
GRANT SELECT, INSERT, DELETE ON library_action_challenges TO snippets_runtime;
GRANT UPDATE (receipt) ON library_action_challenges TO snippets_runtime;
REVOKE ALL ON library_key_authorities, library_action_challenges FROM PUBLIC;
