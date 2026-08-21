package main

import (
	"errors"
	"net"
	"testing"
	"time"
)

func TestLimitListenerCloseUnblocksAcceptWaitingForSlot(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	limited := newLimitListener(listener, 1)
	limited.slots <- struct{}{}

	accepted := make(chan error, 1)
	go func() {
		_, err := limited.Accept()
		accepted <- err
	}()

	if err := limited.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-accepted:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("Accept returned %v, want net.ErrClosed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Accept remained blocked after listener close")
	}
}

func TestConfiguredMemoryBudgetMustFitCgroupHeadroom(t *testing.T) {
	const gibibyte = int64(1024 * 1024 * 1024)
	limit, fits := boundedProcessMemoryLimitFrom(700*1024*1024, []string{"max", "1073741824"})
	if !fits || limit != 700*1024*1024 {
		t.Fatalf("valid budget rejected: limit=%d fits=%t", limit, fits)
	}
	limit, fits = boundedProcessMemoryLimitFrom(gibibyte, []string{"1073741824"})
	if fits || limit != gibibyte/100*85 {
		t.Fatalf("oversized budget accepted: limit=%d fits=%t", limit, fits)
	}
}
