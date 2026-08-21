package postgres

import (
	"testing"
	"time"

	"github.com/wowlocal/snippets/server/internal/config"
)

func TestPoolConfigurationVerifiesDatabaseIdentity(t *testing.T) {
	poolConfig, err := newPoolConfig(config.Database{
		Host: "database.example.test", Port: 5432, Name: "snippets", RuntimeUser: "runtime", RuntimePassword: "secret",
		TLSMode: "verify-full", TLSRootCert: "system", ChannelBinding: "require", RequireAuth: "scram-sha-256",
		ConnectTimeout: 5 * time.Second, StatementTimeout: 20 * time.Second, LockTimeout: 5 * time.Second, MaxConnections: 8,
	})
	if err != nil {
		t.Fatal(err)
	}
	connection := poolConfig.ConnConfig
	if connection.TLSConfig == nil || connection.TLSConfig.InsecureSkipVerify || connection.TLSConfig.ServerName != "database.example.test" {
		t.Fatalf("database certificate identity is not verified: %#v", connection.TLSConfig)
	}
	if connection.ChannelBinding != "require" || connection.RequireAuth != "scram-sha-256" {
		t.Fatalf("database authentication downgrade is possible: channel_binding=%q require_auth=%q", connection.ChannelBinding, connection.RequireAuth)
	}
	if connection.RuntimeParams["statement_timeout"] != "20000" || connection.RuntimeParams["lock_timeout"] != "5000" {
		t.Fatalf("database operation timeouts missing: %#v", connection.RuntimeParams)
	}
}
