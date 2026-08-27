package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"reflect"
	"strings"
	"testing"
)

func TestCLIDispatch(t *testing.T) {
	tests := []struct {
		name            string
		args            []string
		wantCommand     string
		wantCleanupArgs []string
	}{
		{name: "default serves", wantCommand: "serve"},
		{name: "explicit serve", args: []string{"serve"}, wantCommand: "serve"},
		{name: "cleanup", args: []string{"cleanup", "--dry-run"}, wantCommand: "cleanup", wantCleanupArgs: []string{"--dry-run"}},
		{name: "clipboard bridge", args: []string{"clipboard-bridge"}, wantCommand: "clipboard-bridge"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			called := ""
			var cleanupArgs []string
			deps := cliDependencies{
				serve: func() error {
					called = "serve"
					return nil
				},
				cleanup: func(args []string, _ io.Writer) error {
					called = "cleanup"
					cleanupArgs = append([]string(nil), args...)
					return nil
				},
				clipboardBridge: func(context.Context) error {
					called = "clipboard-bridge"
					return nil
				},
			}
			var stdout, stderr bytes.Buffer
			code := runCLIWithDependencies(context.Background(), test.args, &stdout, &stderr, deps)
			if code != 0 {
				t.Fatalf("exit code = %d, stderr = %q", code, stderr.String())
			}
			if called != test.wantCommand {
				t.Fatalf("called %q, want %q", called, test.wantCommand)
			}
			if !reflect.DeepEqual(cleanupArgs, test.wantCleanupArgs) {
				t.Fatalf("cleanup args = %#v, want %#v", cleanupArgs, test.wantCleanupArgs)
			}
		})
	}
}

func TestCLIHelpAndErrors(t *testing.T) {
	deps := cliDependencies{
		serve: func() error { return errors.New("serve failed") },
		cleanup: func([]string, io.Writer) error {
			return errors.New("cleanup failed")
		},
		clipboardBridge: func(context.Context) error { return errors.New("bridge failed") },
	}

	t.Run("help", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		code := runCLIWithDependencies(context.Background(), []string{"help"}, &stdout, &stderr, deps)
		if code != 0 || !strings.Contains(stdout.String(), "clipboard-bridge") || stderr.Len() != 0 {
			t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
		}
	})

	t.Run("unknown command", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		code := runCLIWithDependencies(context.Background(), []string{"explode"}, &stdout, &stderr, deps)
		if code != 2 || !strings.Contains(stderr.String(), "unknown command") {
			t.Fatalf("code=%d stderr=%q", code, stderr.String())
		}
	})

	t.Run("command failure", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		code := runCLIWithDependencies(context.Background(), []string{"cleanup"}, &stdout, &stderr, deps)
		if code != 1 || !strings.Contains(stderr.String(), "cleanup failed") {
			t.Fatalf("code=%d stderr=%q", code, stderr.String())
		}
	})

	t.Run("unexpected arguments", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		code := runCLIWithDependencies(context.Background(), []string{"serve", "extra"}, &stdout, &stderr, deps)
		if code != 2 || !strings.Contains(stderr.String(), "does not accept arguments") {
			t.Fatalf("code=%d stderr=%q", code, stderr.String())
		}
	})
}
