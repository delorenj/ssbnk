/**
 * Shared types for kdco registry plugins.
 *
 * @module kdco-primitives/types
 */

/** Severity levels understood by {@link LogSink}. */
export type LogLevel = "debug" | "info" | "warn" | "error"

/**
 * Where plugin diagnostics go.
 *
 * Replaces the V1 `client.app.log({ body: { service, level, message } })` call: the
 * OpenCode V2 plugin context has no app-log API, so the default sink writes to stderr
 * (see `consoleLogSink` in ./v2).
 */
export interface LogSink {
	log(service: string, level: LogLevel, message: string): void
}
