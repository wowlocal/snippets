package main

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime/debug"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/wowlocal/snippets/server/internal/auth"
	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/httpapi"
	"github.com/wowlocal/snippets/server/internal/postgres"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)
	configuration, err := config.Load()
	if err != nil {
		logger.Error("startup_failed", "error_code", "invalid_configuration")
		os.Exit(1)
	}
	debug.SetMemoryLimit(configuration.HTTP.BodyMemoryBudget + 128*1024*1024)
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	pool, err := postgres.NewPool(ctx, configuration.Database)
	if err != nil {
		logger.Error("startup_failed", "error_code", "database_unavailable")
		os.Exit(1)
	}
	defer pool.Close()
	store, err := postgres.NewStore(pool, configuration.ServerInstanceID, configuration.TokenSecret)
	if err != nil {
		logger.Error("startup_failed", "error_code", "invalid_store_configuration")
		os.Exit(1)
	}
	validator, err := auth.NewOIDCValidator(ctx, configuration.OIDC, nil)
	if err != nil {
		logger.Error("startup_failed", "error_code", "oidc_jwks_unavailable")
		os.Exit(1)
	}
	service := httpapi.NewServer(configuration, store, validator, logger)
	listener, err := net.Listen("tcp", net.JoinHostPort(configuration.BindHost, strconv.Itoa(configuration.Port)))
	if err != nil {
		logger.Error("startup_failed", "error_code", "listen_failed")
		os.Exit(1)
	}
	limited := newLimitListener(listener, configuration.HTTP.MaximumConnections)
	httpServer := &http.Server{Handler: service.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: configuration.HTTP.BodyTimeout + 5*time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: configuration.HTTP.IdleTimeout, MaxHeaderBytes: 32 * 1024}
	serveDone := make(chan error, 1)
	go func() { serveDone <- httpServer.Serve(limited) }()
	logger.Info("server_started", "port", configuration.Port)
	select {
	case <-ctx.Done():
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer shutdownCancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			logger.Error("shutdown_failed", "error_code", "shutdown_timeout")
			os.Exit(1)
		}
		logger.Info("server_stopped")
	case err := <-serveDone:
		if err != nil && err != http.ErrServerClosed {
			logger.Error("server_failed", "error_code", "serve_failed")
			os.Exit(1)
		}
	}
}

type limitListener struct {
	net.Listener
	slots chan struct{}
}

func newLimitListener(listener net.Listener, maximum int) *limitListener {
	return &limitListener{Listener: listener, slots: make(chan struct{}, maximum)}
}
func (l *limitListener) Accept() (net.Conn, error) {
	l.slots <- struct{}{}
	connection, err := l.Listener.Accept()
	if err != nil {
		<-l.slots
		return nil, err
	}
	return &limitConnection{Conn: connection, release: func() { <-l.slots }}, nil
}

type limitConnection struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *limitConnection) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.release)
	return err
}
