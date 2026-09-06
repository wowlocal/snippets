package config

import (
	"errors"
	"net/mail"
	"strings"
)

func ValidateNativeSMTP(c NativeAuth, env Environment) error {
	if c.SMTPHost == "" || len(c.SMTPHost) > 255 || strings.ContainsAny(c.SMTPHost, "\r\n\x00 /:@") || len(c.SMTPUsername) > 256 || len(c.SMTPPassword) > 4096 {
		return errors.New("invalid SMTP configuration")
	}
	address, err := mail.ParseAddress(c.SMTPFrom)
	if err != nil || address.Address != c.SMTPFrom || len(c.SMTPFrom) > 254 || strings.ContainsAny(c.SMTPFrom, "\r\n") {
		return errors.New("invalid SMTP_FROM")
	}
	if c.SMTPTLS != "starttls" && c.SMTPTLS != "tls" && c.SMTPTLS != "none" {
		return errors.New("invalid SMTP_TLS")
	}
	if env == Production && c.SMTPTLS == "none" {
		return errors.New("production SMTP requires TLS")
	}
	if (c.SMTPUsername == "") != (c.SMTPPassword == "") || (c.SMTPTLS == "none" && c.SMTPUsername != "") {
		return errors.New("invalid SMTP authentication")
	}
	return nil
}
