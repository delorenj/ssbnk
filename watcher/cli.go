package main

import (
	"context"
	"fmt"
	"io"
	"os"
)

const usageText = `ssbnk stores and serves screenshots and screencasts.

Usage:
  ssbnk [serve]
  ssbnk cleanup [--dry-run]
  ssbnk clipboard-bridge
  ssbnk help

Commands:
  serve              Watch media directories and serve the API and frontend (default)
  cleanup            Apply hosted and archive retention policies
  clipboard-bridge   Copy published URLs to the Wayland clipboard
  help               Show this help
`

type cliDependencies struct {
	serve           func() error
	cleanup         func([]string, io.Writer) error
	clipboardBridge func(context.Context) error
}

func main() {
	os.Exit(runCLI(os.Args[1:], os.Stdout, os.Stderr))
}

func defaultConfig() Config {
	return Config{
		ScreenshotDir: getEnv("SSBNK_SCREENSHOT_DIR", "/media/screenshots"),
		ScreencastDir: getEnv("SSBNK_SCREENCAST_DIR", "/media/screencasts"),
		DataDir:       getEnv("SSBNK_DATA_DIR", "/data"),
		StateDir:      getEnv("SSBNK_STATE_DIR", "/data/state"),
		BaseURL:       getEnv("SSBNK_URL", "https://ss.yourdomain.com"),
	}
}

func productionCLIDependencies() cliDependencies {
	return cliDependencies{
		serve: func() error {
			return serve(defaultConfig())
		},
		cleanup: runCleanupCommand,
		clipboardBridge: func(ctx context.Context) error {
			return runClipboardBridge(ctx, clipboardBridgeOptionsFromEnv())
		},
	}
}

func runCLI(args []string, stdout, stderr io.Writer) int {
	return runCLIWithDependencies(context.Background(), args, stdout, stderr, productionCLIDependencies())
}

func runCLIWithDependencies(
	ctx context.Context,
	args []string,
	stdout io.Writer,
	stderr io.Writer,
	deps cliDependencies,
) int {
	command := "serve"
	commandArgs := []string(nil)
	if len(args) > 0 {
		command = args[0]
		commandArgs = args[1:]
	}

	var err error
	switch command {
	case "help", "-h", "--help":
		if len(commandArgs) != 0 {
			fmt.Fprintf(stderr, "ssbnk: help does not accept arguments\n")
			return 2
		}
		fmt.Fprint(stdout, usageText)
		return 0
	case "serve":
		if len(commandArgs) != 0 {
			fmt.Fprintf(stderr, "ssbnk: serve does not accept arguments\n")
			return 2
		}
		err = deps.serve()
	case "cleanup":
		err = deps.cleanup(commandArgs, stdout)
	case "clipboard-bridge":
		if len(commandArgs) != 0 {
			fmt.Fprintf(stderr, "ssbnk: clipboard-bridge does not accept arguments\n")
			return 2
		}
		err = deps.clipboardBridge(ctx)
	default:
		fmt.Fprintf(stderr, "ssbnk: unknown command %q\n\n%s", command, usageText)
		return 2
	}

	if err != nil {
		fmt.Fprintf(stderr, "ssbnk: %s: %v\n", command, err)
		return 1
	}
	return 0
}
