/**
 * Warning logger for kdco registry plugins.
 *
 * Provides a unified interface for logging warnings that works with
 * a plugin log sink (when available) and console fallback.
 *
 * @module kdco-primitives/log-warn
 */

import type { LogSink } from "./types"

/**
 * Log a warning message via a log sink or console fallback.
 *
 * Falls back to console.warn (stderr, which OpenCode V2 surfaces) when no sink
 * is provided.
 *
 * @param sink - Optional log sink for proper logging integration
 * @param service - Service name for log categorization (e.g., "worktree", "delegation")
 * @param message - Warning message to log
 *
 * @example
 * ```ts
 * // With a sink
 * logWarn(sink, "delegation", "Task timed out after 30s")
 *
 * // Without a sink - logs to console
 * logWarn(undefined, "delegation", "Task timed out after 30s")
 * ```
 */
export function logWarn(sink: LogSink | undefined, service: string, message: string): void {
	// Guard: No sink available, use console fallback (Law 1: Early Exit)
	if (!sink) {
		console.warn(`[${service}] ${message}`)
		return
	}

	// Happy path: Use the sink
	try {
		sink.log(service, "warn", message)
	} catch {
		// Silently ignore logging failures - don't disrupt caller
	}
}
