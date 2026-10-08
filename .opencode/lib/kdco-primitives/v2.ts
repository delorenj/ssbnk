/**
 * OpenCode V2 plugin plumbing shared by the kdco-derived plugins in this repo.
 *
 * V2 plugins `export default { id, setup(ctx) }` (Plugin.define is the identity
 * function, so no import and no node_modules are needed). This module holds the
 * structural subset of the V2 context the plugins use, plus the small adapters
 * that replace V1 idioms:
 *
 *   V1 `client.app.log`                    -> consoleLogSink (stderr; V2 drops stdout)
 *   V1 `event` hook                        -> startEventLoop (ctx.event.subscribe)
 *   V1 `output.output += ...`              -> appendToolResultText (ctx.tool.hook "execute.after")
 *   V1 tool({ args: tool.schema... })      -> V2ToolDefinition with JSON Schema input
 *
 * Authoritative contract: https://opencode.ai/v2/docs/build/plugins and
 * https://opencode.ai/v2/docs/build/plugins/migrate-v1
 *
 * @module kdco-primitives/v2
 */

import type { LogSink } from "./types"

// ==========================================
// CONTEXT SUBSET
// ==========================================

export interface V2Registration {
	dispose(): Promise<void>
}

/** A system prompt part as accepted by the `context` / `compaction` session hooks. */
export interface V2SystemPart {
	type: "text"
	text: string
}

export interface V2PermissionRule {
	action: string
	resource: string
	effect: "allow" | "deny" | "ask"
}

export interface V2AgentInfo {
	id: string
	name: string
	description?: string
	mode: "subagent" | "primary" | "all"
	hidden: boolean
	permissions: readonly V2PermissionRule[]
}

export interface V2SessionInfo {
	id: string
	parentID?: string
	title?: string
	agent?: string
	location?: { directory: string }
}

/** `{ location, data }` envelope returned by list/get style reads. */
export interface V2Envelope<T> {
	location?: unknown
	data: T
}

export interface V2Event {
	id: string
	type: string
	created: number
	data: Record<string, any>
	location?: { directory: string; workspaceID?: string }
	metadata?: Record<string, unknown>
}

export interface V2ToolContext {
	readonly sessionID: string
	readonly agent: string
	readonly messageID: string
	readonly id: string
	readonly signal: AbortSignal
	readonly progress: (update: Record<string, unknown>) => Promise<void>
}

export interface V2ToolResult {
	content?: string | ReadonlyArray<{ type: "text"; text: string } | { type: "file"; uri: string; mime: string }>
	output?: unknown
	metadata?: Record<string, unknown>
}

export interface V2ToolDefinition {
	name: string
	description: string
	/** JSON Schema describing the tool input. */
	input: Record<string, unknown>
	execute(input: any, context: V2ToolContext): Promise<V2ToolResult>
	options?: { namespace?: string; permission?: string; codemode?: boolean; pinned?: boolean }
}

export interface V2ToolEditor {
	add(tool: V2ToolDefinition): void
	update(id: string, update: (tool: any) => void): void
	remove(id: string): void
	list(): readonly { id: string }[]
}

export interface V2ToolBefore {
	tool: string
	readonly sessionID: string
	readonly agent: string
	readonly messageID: string
	readonly id: string
	input: any
}

export type V2ToolAfter = {
	readonly tool: string
	readonly sessionID: string
	readonly agent: string
	readonly messageID: string
	readonly id: string
	readonly input: any
} & (
	| { readonly status: "completed"; result: V2ToolResult }
	| { readonly status: "error"; readonly error: { message: string } }
)

export interface V2SessionContextHook {
	readonly sessionID: string
	readonly agent: string
	readonly model: { providerID: string; id: string; variant?: string }
	system: V2SystemPart[]
	messages: any[]
	options: Record<string, unknown>
	tools: Record<string, { description: string; input: unknown }>
}

export interface V2PluginContext {
	readonly app: { name: string; version: string; channel: string }
	readonly location: {
		directory: string
		workspaceID?: string
		project: { id: string; directory: string; canonical: string }
	}
	readonly options: Record<string, unknown>
	readonly agent: {
		list(): Promise<V2Envelope<V2AgentInfo[]>>
		get(input: { agentID: string }): Promise<V2Envelope<V2AgentInfo>>
	}
	readonly event: {
		subscribe(options?: { signal?: AbortSignal }): AsyncIterable<V2Event>
	}
	readonly generate: {
		text(input: { prompt: string; model?: { providerID: string; id: string; variant?: string } }): Promise<{ text: string }>
	}
	readonly session: {
		create(input?: {
			id?: string
			parentID?: string
			title?: string
			agent?: string
			location?: { directory: string }
			metadata?: Record<string, unknown>
			permissions?: readonly V2PermissionRule[]
		}): Promise<V2SessionInfo>
		get(input: { sessionID: string }): Promise<V2SessionInfo>
		remove(input: { sessionID: string }): Promise<void>
		context(input: { sessionID: string }): Promise<any[]>
		prompt(input: {
			sessionID: string
			text: string
			delivery?: "steer" | "queue"
			resume?: boolean
		}): Promise<unknown>
		synthetic(input: {
			sessionID: string
			text: string
			description?: string
			delivery?: "steer" | "queue"
			resume?: boolean
		}): Promise<unknown>
		wait(input: { sessionID: string }): Promise<void>
		hook(
			name: "context" | "compaction" | "generate" | "title" | "prompt" | "model.request",
			callback: (event: any) => Promise<void> | void,
			options?: { providerID?: string },
		): Promise<V2Registration>
	}
	readonly tool: {
		transform(callback: (editor: V2ToolEditor) => void): Promise<V2Registration>
		reload(): Promise<void>
		hook(name: "execute.before", callback: (event: V2ToolBefore) => Promise<void> | void): Promise<V2Registration>
		hook(name: "execute.after", callback: (event: V2ToolAfter) => Promise<void> | void): Promise<V2Registration>
	}
}

export type V2Cleanup = () => Promise<void> | void

export interface V2PluginDefinition {
	id: string
	setup(ctx: V2PluginContext): Promise<V2Cleanup | void> | V2Cleanup | void
}

// ==========================================
// RESULT HELPERS
// ==========================================

/** Unwrap a `{ location, data }` envelope if present; pass plain values through. */
export function unwrap<T>(value: T | V2Envelope<T>): T {
	if (value && typeof value === "object" && "data" in (value as object) && "location" in (value as object)) {
		return (value as V2Envelope<T>).data
	}
	return value as T
}

/** Plain-text tool result. */
export function text(content: string): V2ToolResult {
	return { content }
}

/** Append text to a completed tool result (V1: `output.output += ...`). */
export function appendToolResultText(result: V2ToolResult, extra: string): void {
	const current = result.content
	if (current === undefined) {
		result.content = extra
	} else if (typeof current === "string") {
		result.content = current + extra
	} else {
		result.content = [...current, { type: "text", text: extra }]
	}
}

/** Narrow a V2 tool `input` (unknown) to a record without trusting its shape. */
export function asRecord(value: unknown): Record<string, unknown> {
	return value && typeof value === "object" ? (value as Record<string, unknown>) : {}
}

// ==========================================
// LOGGING
// ==========================================

/**
 * V2 plugin stdout is not surfaced; stderr is. warn/error go to stderr, debug/info
 * are dropped unless KDCO_PLUGIN_DEBUG=1 (then they go to stderr too).
 */
export const consoleLogSink: LogSink = {
	log(service, level, message) {
		const line = `[${service}] ${message}`
		if (level === "error") console.error(line)
		else if (level === "warn") console.warn(line)
		else if (process.env.KDCO_PLUGIN_DEBUG === "1") console.error(line)
	},
}

export function createServiceLogger(service: string, sink: LogSink = consoleLogSink) {
	return {
		debug: (msg: string) => sink.log(service, "debug", msg),
		info: (msg: string) => sink.log(service, "info", msg),
		warn: (msg: string) => sink.log(service, "warn", msg),
		error: (msg: string) => sink.log(service, "error", msg),
	}
}

// ==========================================
// EVENTS
// ==========================================

/**
 * Subscribe to the public event stream and dispatch each event to `onEvent`.
 * Handler failures are logged and never end the loop. Returns the cleanup
 * function to hand back from `setup`.
 */
export function startEventLoop(
	ctx: Pick<V2PluginContext, "event">,
	onEvent: (event: V2Event) => Promise<void> | void,
	onError: (error: unknown, event?: V2Event) => void,
): () => void {
	const controller = new AbortController()
	void (async () => {
		try {
			for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
				try {
					await onEvent(event)
				} catch (error) {
					onError(error, event)
				}
			}
		} catch (error) {
			if (!controller.signal.aborted) onError(error)
		}
	})()
	return () => controller.abort()
}

// ==========================================
// SESSION TREE
// ==========================================

/** Maximum depth when walking a session's parent chain. */
export const MAX_SESSION_CHAIN_DEPTH = 10

/**
 * Resolve the root session by walking `parentID`. `strict` rethrows lookup failures;
 * otherwise the last known id is returned (best effort).
 */
export async function resolveRootSessionID(
	ctx: Pick<V2PluginContext, "session">,
	sessionID: string,
	options: { strict?: boolean } = {},
): Promise<string> {
	let currentID = sessionID
	for (let depth = 0; depth < MAX_SESSION_CHAIN_DEPTH; depth++) {
		let parentID: string | undefined
		try {
			parentID = unwrap(await ctx.session.get({ sessionID: currentID })).parentID
		} catch (error) {
			if (options.strict) throw error
			return currentID
		}
		if (!parentID) return currentID
		currentID = parentID
	}
	if (options.strict) {
		throw new Error("Failed to resolve root session: maximum traversal depth exceeded")
	}
	return currentID
}
