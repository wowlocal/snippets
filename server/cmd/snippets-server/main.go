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
	"strings"
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
	configuredMemoryLimit := configuration.HTTP.BodyMemoryBudget + configuration.HTTP.ResponseMemoryBudget + 128*1024*1024
	processMemoryLimit, fitsContainer := boundedProcessMemoryLimit(configuredMemoryLimit)
	if !fitsContainer {
		logger.Error("startup_failed", "error_code", "memory_budget_exceeds_container")
		os.Exit(1)
	}
	debug.SetMemoryLimit(processMemoryLimit)
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
	httpServer := &http.Server{Handler: service.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: configuration.HTTP.BodyTimeout + 5*time.Second, WriteTimeout: configuration.HTTP.RequestTimeout + 5*time.Second, IdleTimeout: configuration.HTTP.IdleTimeout, MaxHeaderBytes: 32 * 1024}
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

func boundedProcessMemoryLimit(configured int64) (int64, bool) {
	values := make([]string, 0, 2)
	for _, path := range []string{"/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"} {
		if data, err := os.ReadFile(path); err == nil {
			values = append(values, strings.TrimSpace(string(data)))
		}
	}
	return boundedProcessMemoryLimitFrom(configured, values)
}

func boundedProcessMemoryLimitFrom(configured int64, cgroupValues []string) (int64, bool) {
	containerLimit := int64(0)
	for _, raw := range cgroupValues {
		value, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || value <= 0 || value >= 1<<60 {
			continue
		}
		if containerLimit == 0 || value < containerLimit {
			containerLimit = value
		}
	}
	if containerLimit == 0 {
		return configured, true
	}
	safeContainerLimit := containerLimit / 100 * 85
	if configured > safeContainerLimit {
		return safeContainerLimit, false
	}
	return configured, true
}

type limitListener struct {
	net.Listener
	slots     chan struct{}
	done      chan struct{}
	closeOnce sync.Once
	closeErr  error
}

func newLimitListener(listener net.Listener, maximum int) *limitListener {
	return &limitListener{Listener: listener, slots: make(chan struct{}, maximum), done: make(chan struct{})}
}
func (l *limitListener) Accept() (net.Conn, error) {
	select {
	case l.slots <- struct{}{}:
	case <-l.done:
		return nil, net.ErrClosed
	}
	connection, err := l.Listener.Accept()
	if err != nil {
		<-l.slots
		return nil, err
	}
	return &limitConnection{Conn: connection, release: func() { <-l.slots }}, nil
}

func (l *limitListener) Close() error {
	l.closeOnce.Do(func() {
		close(l.done)
		l.closeErr = l.Listener.Close()
	})
	return l.closeErr
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
