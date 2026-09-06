package auth

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/smtp"
	"strconv"
	"time"

	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/domain"
)

type CodeSender interface {
	SendCode(context.Context, string, string) error
}
type SMTPSender struct{ Configuration config.NativeAuth }

// Delivery errors are deliberately replaced: SMTP replies may echo a recipient or code.
func (s SMTPSender) SendCode(ctx context.Context, email, code string) error {
	if err := s.send(ctx, email, code); err != nil {
		return domain.NewError(domain.DependencyUnavailable)
	}
	return nil
}
func (s SMTPSender) send(ctx context.Context, email, code string) error {
	c := s.Configuration
	address := net.JoinHostPort(c.SMTPHost, strconv.Itoa(c.SMTPPort))
	dialer := &net.Dialer{Timeout: 8 * time.Second}
	connection, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return err
	}
	defer connection.Close()
	deadline := time.Now().Add(12 * time.Second)
	if value, ok := ctx.Deadline(); ok && value.Before(deadline) {
		deadline = value
	}
	if err := connection.SetDeadline(deadline); err != nil {
		return err
	}
	rawConnection := connection
	cancelClose := context.AfterFunc(ctx, func() { _ = rawConnection.Close() })
	defer cancelClose()
	tlsConfig := &tls.Config{ServerName: c.SMTPHost, MinVersion: tls.VersionTLS12}
	if c.SMTPTLS == "tls" {
		secured := tls.Client(connection, tlsConfig)
		if err := secured.HandshakeContext(ctx); err != nil {
			return err
		}
		connection = secured
	}
	client, err := smtp.NewClient(connection, c.SMTPHost)
	if err != nil {
		return err
	}
	defer client.Close()
	if c.SMTPTLS == "starttls" {
		if err := client.StartTLS(tlsConfig); err != nil {
			return err
		}
	}
	if c.SMTPUsername != "" {
		if err := client.Auth(smtp.PlainAuth("", c.SMTPUsername, c.SMTPPassword, c.SMTPHost)); err != nil {
			return err
		}
	}
	if err := client.Mail(c.SMTPFrom); err != nil {
		return err
	}
	if err := client.Rcpt(email); err != nil {
		return err
	}
	writer, err := client.Data()
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(writer, "From: %s\r\nTo: %s\r\nSubject: %s is your Snippets sign-in code\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nYour Snippets sign-in code is: %s\r\n\r\nThis code expires in 10 minutes. If you did not request it, ignore this email.\r\n", c.SMTPFrom, email, code, code)
	if err != nil {
		_ = writer.Close()
		return err
	}
	if err := writer.Close(); err != nil {
		return err
	}
	_ = client.Quit()
	return nil
}
