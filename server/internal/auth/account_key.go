package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"strings"
)

// Account keys are the only native sign-in secret. The server generates 26 uniformly
// random Crockford Base32 symbols (130 bits) and appends two symbols holding the first
// ten bits of a domain-separated SHA-256, so clients reject typing errors before any
// network request. Canonical form is the 28 uppercase symbols; display groups them by four.
const (
	accountKeyAlphabet    = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
	accountKeyBodyLength  = 26
	accountKeyLength      = accountKeyBodyLength + 2
	accountKeyCheckDomain = "snippets-account-key-check-v1\n"
)

func accountKeyCheck(body string) string {
	sum := sha256.Sum256([]byte(accountKeyCheckDomain + body))
	value := int(sum[0])<<2 | int(sum[1])>>6
	return string([]byte{accountKeyAlphabet[value>>5], accountKeyAlphabet[value&31]})
}

func newAccountKey() (string, error) {
	var random [accountKeyBodyLength]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", err
	}
	body := make([]byte, accountKeyBodyLength)
	for i, value := range random {
		// 256 is a multiple of 32, so masking keeps each symbol uniform.
		body[i] = accountKeyAlphabet[value&31]
	}
	return string(body) + accountKeyCheck(string(body)), nil
}

// validAccountKey accepts only the canonical wire form. Clients normalize user input
// (separators, case, O/I/L) before sending it.
func validAccountKey(value string) bool {
	if len(value) != accountKeyLength {
		return false
	}
	for i := 0; i < len(value); i++ {
		if strings.IndexByte(accountKeyAlphabet, value[i]) < 0 {
			return false
		}
	}
	return accountKeyCheck(value[:accountKeyBodyLength]) == value[accountKeyBodyLength:]
}
