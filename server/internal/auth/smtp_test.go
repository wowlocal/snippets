package auth

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/domain"
)

func smtpFixture(t *testing.T, rejectRecipient bool) (config.NativeAuth, <-chan string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	messages := make(chan string, 1)
	go func() {
		defer close(messages)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
		reader := bufio.NewReader(conn)
		_, _ = fmt.Fprint(conn, "220 mail.example.test ESMTP\r\n")
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				return
			}
			switch {
			case strings.HasPrefix(line, "EHLO"), strings.HasPrefix(line, "HELO"):
				_, _ = fmt.Fprint(conn, "250 mail.example.test\r\n")
			case strings.HasPrefix(line, "MAIL FROM"):
				_, _ = fmt.Fprint(conn, "250 OK\r\n")
			case strings.HasPrefix(line, "RCPT TO"):
				if rejectRecipient {
					_, _ = fmt.Fprint(conn, "550 private recipient rejected\r\n")
				} else {
					_, _ = fmt.Fprint(conn, "250 OK\r\n")
				}
			case strings.HasPrefix(line, "DATA"):
				_, _ = fmt.Fprint(conn, "354 Continue\r\n")
				var body strings.Builder
				for {
					part, err := reader.ReadString('\n')
					if err != nil {
						return
					}
					if part == ".\r\n" {
						break
					}
					body.WriteString(part)
				}
				messages <- body.String()
				_, _ = fmt.Fprint(conn, "250 queued\r\n")
			case strings.HasPrefix(line, "QUIT"):
				_, _ = fmt.Fprint(conn, "221 Bye\r\n")
				return
			default:
				return
			}
		}
	}()
	_, portText, _ := net.SplitHostPort(listener.Addr().String())
	port, _ := strconv.Atoi(portText)
	return config.NativeAuth{SMTPHost: "127.0.0.1", SMTPPort: port, SMTPFrom: "snippets@example.test", SMTPTLS: "none"}, messages
}
func TestSMTPSenderDeliversCodeAndRejectsTLSStripping(t *testing.T) {
	c, messages := smtpFixture(t, false)
	if err := (SMTPSender{Configuration: c}).SendCode(context.Background(), "user@example.test", "123456"); err != nil {
		t.Fatal(err)
	}
	body := <-messages
	if !strings.Contains(body, "Your Snippets sign-in code is: 123456") || !strings.Contains(body, "To: user@example.test\r\n") {
		t.Fatal("SMTP message missing expected code")
	}
	c, messages = smtpFixture(t, false)
	c.SMTPTLS = "starttls"
	if err := (SMTPSender{Configuration: c}).SendCode(context.Background(), "user@example.test", "123456"); domain.AsServiceError(err).Code != domain.DependencyUnavailable {
		t.Fatal("TLS stripping was accepted")
	}
	if message := <-messages; message != "" {
		t.Fatal("code sent without required TLS")
	}
	c, _ = smtpFixture(t, true)
	if err := (SMTPSender{Configuration: c}).SendCode(context.Background(), "user@example.test", "123456"); err == nil || err.Error() != "dependency_unavailable" {
		t.Fatal("SMTP failure not sanitized")
	}
}
