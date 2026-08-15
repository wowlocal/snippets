-- Pairing v2 binds the QR invitation to a fresh 256-bit nonce. Pairings are
-- short-lived, one-use coordination records, so pre-v2 offers are deliberately
-- invalidated instead of being promoted without the missing cryptographic value.
ALTER TABLE pairings ADD COLUMN nonce bytea;
DELETE FROM pairings;
ALTER TABLE pairings ALTER COLUMN nonce SET NOT NULL;
ALTER TABLE pairings ADD CONSTRAINT pairings_nonce_size CHECK (octet_length(nonce) = 32);

ALTER TABLE pairings DROP CONSTRAINT IF EXISTS pairings_recipient_public_key_check;
ALTER TABLE pairings DROP CONSTRAINT IF EXISTS pairings_authentication_tag_check;
ALTER TABLE pairings DROP CONSTRAINT IF EXISTS pairings_algorithm_check;
ALTER TABLE pairings DROP CONSTRAINT IF EXISTS pairings_ciphertext_check;
ALTER TABLE pairings ADD CONSTRAINT pairings_recipient_public_key_check
    CHECK (octet_length(recipient_public_key) = 65 AND get_byte(recipient_public_key, 0) = 4);
ALTER TABLE pairings ADD CONSTRAINT pairings_authentication_tag_check
    CHECK (authentication_tag ~ '^[A-Z2-9]{8}$');
ALTER TABLE pairings ADD CONSTRAINT pairings_algorithm_check
    CHECK (algorithm IS NULL OR algorithm = 'snippets-pairing-p256-hkdf-sha256-aes256gcm-v1');
ALTER TABLE pairings ADD CONSTRAINT pairings_ciphertext_check
    CHECK (ciphertext IS NULL OR octet_length(ciphertext) <= 4096);

-- The only v1 recovery format is deliberately narrow. Mirror the domain and
-- OpenAPI bounds at the database boundary so a compromised runtime role cannot
-- retain oversized or algorithm-confused bootstrap material.
ALTER TABLE key_envelopes DROP CONSTRAINT IF EXISTS key_envelopes_algorithm_check;
ALTER TABLE key_envelopes DROP CONSTRAINT IF EXISTS key_envelopes_ciphertext_check;
ALTER TABLE key_envelopes ADD CONSTRAINT key_envelopes_algorithm_check
    CHECK (algorithm = 'snippets-recovery-hkdf-sha256-aes256gcm-v1');
ALTER TABLE key_envelopes ADD CONSTRAINT key_envelopes_ciphertext_check
    CHECK (octet_length(ciphertext) <= 4096);
