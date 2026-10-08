/**
 * background-agents (OpenCode V2)
 * Unified delegation system for OpenCode
 *
 * Persistent, async-first agent delegation for read-only subagents. All agent
 * outputs are persisted to storage; the orchestrator receives only key references.
 *
 * Based on oh-my-opencode by @code-yeongyu (MIT License)
 * https://github.com/code-yeongyu/oh-my-opencode
 *
 * Ported from the kdco `background-agents` V1 plugin (kdcokenny/opencode-background-agents,
 * retired upstream with no V2 port) to the OpenCode V2 plugin API:
 *
 *   V1 `tool` map (tool.schema)                  -> ctx.tool.transform (JSON Schema input)
 *   V1 `client.session.prompt` (blocking)        -> ctx.session.prompt (admission only) + execution events
 *   V1 `noReply: true` prompt to the parent      -> ctx.session.synthetic({ resume: false })
 *   V1 `tools: { task: false, ... }` per prompt  -> ctx.session.hook("context") deleting tools for delegation sessions
 *   V1 `session.idle` / `message.updated` events -> ctx.event.subscribe: session.execution.* / session.text.ended / session.tool.called
 *   V1 `experimental.chat.system.transform`      -> ctx.session.hook("context") + event.system
 *   V1 `experimental.session.compacting`         -> ctx.session.hook("compaction") + event.system
 *   V1 `tool.execute.before` on native `task`    -> ctx.tool.hook("execute.before") on native `subagent`
 *   V1 small_model metadata session              -> ctx.generate.text (no session)
 *   V1 `client.config.get` agent permissions     -> V2 agent.permissions ruleset (edit / shell)
 */

import * as fs from "node:fs/promises"
import * as os from "node:os"
import * as path from "node:path"
import { adjectives, animals, colors, uniqueNamesGenerator } from "unique-names-generator"
import { getProjectId } from "../lib/kdco-primitives/get-project-id"
import {
	asRecord,
	createServiceLogger,
	resolveRootSessionID,
	startEventLoop,
	text,
	unwrap,
	type V2AgentInfo,
	type V2Event,
	type V2PermissionRule,
	type V2PluginContext,
	type V2PluginDefinition,
	type V2ToolDefinition,
} from "../lib/kdco-primitives/v2"

/** Everything the DelegationManager needs from the plugin context. */
type ManagerContext = Pick<V2PluginContext, "agent" | "generate" | "session">

// ==========================================
// READABLE ID GENERATION
// ==========================================

function generateReadableId(): string {
	return uniqueNamesGenerator({
		dictionaries: [adjectives, colors, animals],
		separator: "-",
		length: 3,
		style: "lowerCase",
	})
}

// ==========================================
// METADATA GENERATION (using small_model)
// ==========================================

interface GeneratedMetadata {
	title: string
	description: string
}

/** Timeout safety net for the metadata generation request. */
const METADATA_TIMEOUT_MS = 30000

/**
 * Generate title and description from result content using the small model.
 * Falls back to truncation if generation is unavailable or fails.
 *
 * V1 created a throw-away child session on `small_model`; V2 has `ctx.generate.text`, which
 * runs a transient generation without creating a session or touching history.
 */
async function generateMetadata(
	ctx: Pick<V2PluginContext, "generate">,
	resultContent: string,
	_parentID: string,
	debugLog: (msg: string) => Promise<void>,
): Promise<GeneratedMetadata> {
	const fallbackMetadata = (): GeneratedMetadata => {
		// Fallback: truncate first line/paragraph
		const firstLine =
			resultContent.split("\n").find((l) => l.trim().length > 0) || "Delegation result"
		const title = firstLine.slice(0, 30).trim() + (firstLine.length > 30 ? "..." : "")
		const description =
			resultContent.slice(0, 150).trim() + (resultContent.length > 150 ? "..." : "")
		return { title, description }
	}

	try {
		const prompt = `Generate a title and description for this research result.

RULES:
- Title: 2-5 words, max 30 characters, sentence case
- Description: 2-3 sentences, max 150 characters, summarize key findings

RESULT CONTENT:
${resultContent.slice(0, 2000)}

Respond with ONLY valid JSON in this exact format:
{"title": "Your Title Here", "description": "Your description here."}`

		// Await generation directly with timeout safety net
		let timer: ReturnType<typeof setTimeout> | undefined
		const result = await Promise.race([
			ctx.generate.text({ prompt }),
			new Promise<never>((_, reject) => {
				timer = setTimeout(
					() => reject(new Error(`Generation timeout after ${METADATA_TIMEOUT_MS / 1000}s`)),
					METADATA_TIMEOUT_MS,
				)
			}),
		]).finally(() => {
			if (timer) clearTimeout(timer)
		})

		const responseText = result?.text
		if (!responseText) {
			await debugLog("generateMetadata: No text in response")
			return fallbackMetadata()
		}

		// Parse JSON response
		const jsonMatch = responseText.match(/\{[\s\S]*\}/)
		if (!jsonMatch) {
			await debugLog(`generateMetadata: No JSON found in response: ${responseText}`)
			return fallbackMetadata()
		}

		const parsed = JSON.parse(jsonMatch[0]) as { title?: string; description?: string }
		if (!parsed.title || !parsed.description) {
			await debugLog("generateMetadata: Invalid JSON structure")
			return fallbackMetadata()
		}

		await debugLog(`generateMetadata: Generated title="${parsed.title}"`)
		return {
			title: parsed.title.slice(0, 30),
			description: parsed.description.slice(0, 150),
		}
	} catch (error) {
		await debugLog(
			`generateMetadata error: ${error instanceof Error ? error.message : "Unknown error"}`,
		)
		return fallbackMetadata()
	}
}

// ==========================================
// TYPE DEFINITIONS
// ==========================================

/** Subset of a V2 session message (ctx.session.context) that result extraction reads. */
interface SessionMessageItem {
	type: string
	content?: Array<{ type: string; text?: string }>
}

type DelegationStatus = "registered" | "running" | "complete" | "error" | "cancelled" | "timeout"

type DelegationTerminalStatus = Extract<
	DelegationStatus,
	"complete" | "error" | "cancelled" | "timeout"
>

interface DelegationProgress {
	toolCalls: number
	lastUpdateAt: Date
	lastHeartbeatAt: Date
	lastMessage?: string
	lastMessageAt?: Date
}

interface DelegationNotificationState {
	terminalNotifiedAt?: Date
	terminalNotificationCount: number
}

interface ParentNotificationState {
	allCompleteNotifiedAt?: Date
	allCompleteNotificationCount: number
	allCompleteCycle: number
	allCompleteCycleToken: string
	allCompleteNotifiedCycle?: number
	allCompleteNotifiedCycleToken?: string
	allCompleteScheduledCycle?: number
	allCompleteScheduledCycleToken?: string
	allCompleteScheduledTimer?: ReturnType<typeof setTimeout>
}

interface DelegationRetrievalState {
	retrievedAt?: Date
	retrievalCount: number
	lastReaderSessionID?: string
}

interface DelegationArtifactState {
	filePath: string
	persistedAt?: Date
	byteLength?: number
	persistError?: string
}

interface DelegationRecord {
	id: string
	rootSessionID: string
	sessionID: string
	parentSessionID: string
	parentMessageID: string
	parentAgent: string
	prompt: string
	agent: string
	notificationCycle: number
	notificationCycleToken: string
	status: DelegationStatus
	createdAt: Date
	startedAt?: Date
	completedAt?: Date
	updatedAt: Date
	timeoutAt: Date
	progress: DelegationProgress
	notification: DelegationNotificationState
	retrieval: DelegationRetrievalState
	artifact: DelegationArtifactState
	error?: string
	title?: string
	description?: string
	result?: string
}

/**
 * Tools a delegation session must never reach (anti-recursion, no state changes). V1 passed
 * `tools: { task, delegate, todowrite, plan_save: false }` on the delegation prompt. V2 has no
 * per-prompt tool switch, and plugin tools are also reachable through Code Mode
 * (`tools.delegate(...)`), which ignores the model-request tool list, so the block is enforced
 * three ways for the session's lifetime:
 *   1. session-scoped permission deny rules at creation (hides the tools from the Code Mode catalog),
 *   2. the "context" hook (drops them from the model request),
 *   3. the "execute.before" hook (rejects any call that still arrives).
 * Both the V2 (`subagent`) and V1 (`task`) native names are listed.
 */
const NESTED_TOOL_BLOCKLIST = ["subagent", "task", "delegate", "todowrite", "plan_save"] as const

const NESTED_DENY_RULES: readonly V2PermissionRule[] = NESTED_TOOL_BLOCKLIST.map((action) => ({
	action,
	resource: "*",
	effect: "deny" as const,
}))

const DEFAULT_MAX_RUN_TIME_MS = 15 * 60 * 1000 // 15 minutes
const TERMINAL_WAIT_GRACE_MS = 10_000
const READ_POLL_INTERVAL_MS = 250
const ALL_COMPLETE_QUIET_PERIOD_MS = 50

interface DelegateInput {
	parentSessionID: string
	parentMessageID: string
	parentAgent: string
	prompt: string
	agent: string
}

interface DelegationListItem {
	id: string
	status: DelegationStatus
	title?: string
	description?: string
	agent?: string
	unread?: boolean
}

interface DelegationManagerOptions {
	maxRunTimeMs?: number
	readPollIntervalMs?: number
	terminalWaitGraceMs?: number
	allCompleteQuietPeriodMs?: number
	idGenerator?: () => string
	metadataGenerator?: typeof generateMetadata
}

// ==========================================
// LOGGING HELPER
// ==========================================

/**
 * Structured logger (stderr via the shared sink; V2 has no app-log API).
 * Never throws, so it cannot disrupt tool execution.
 */
function createLogger() {
	return createServiceLogger("background-agents")
}

type Logger = ReturnType<typeof createLogger>

// ==========================================
// AGENT CAPABILITY DETECTION
// ==========================================

/**
 * Parse agent mode at boundary.
 * Returns trusted type indicating if agent is a sub-agent.
 */
async function parseAgentMode(
	ctx: Pick<V2PluginContext, "agent">,
	agentName: string,
	log: Logger,
): Promise<{ isSubAgent: boolean }> {
	try {
		const agents = unwrap(await ctx.agent.list()) ?? []
		const agent = agents.find((a) => a.id === agentName)
		return { isSubAgent: agent?.mode === "subagent" }
	} catch (error) {
		// Fail-safe: Agent list errors shouldn't block subagent calls
		// Fail-loud: Log for observability
		log.warn(
			`Agent list fetch failed for "${agentName}", assuming non-sub-agent: ${error instanceof Error ? error.message : String(error)}`,
		)
		return { isSubAgent: false }
	}
}

/** True when a rule's action selector (exact, "*", or "prefix*") covers `action`. */
function ruleCoversAction(ruleAction: string, action: string): boolean {
	if (ruleAction === "*" || ruleAction === action) return true
	return ruleAction.endsWith("*") && action.startsWith(ruleAction.slice(0, -1))
}

/**
 * Check if an agent's ordered V2 ruleset denies an action across the board (Law 4: Fail Fast).
 *
 * V2 permissions are an ordered array where the LAST matching rule wins. V1 asked whether a
 * pattern entry's catch-all `"*"` was `"deny"` while still allowing specific commands
 * (e.g. `bash: { "*": "deny", "git diff*": "allow" }`); the equivalent here is the effect of
 * the last rule that covers the action with the catch-all resource `"*"`.
 */
function isActionDenied(rules: readonly V2PermissionRule[], action: string): boolean {
	let effect: V2PermissionRule["effect"] | undefined
	for (const rule of rules) {
		if (rule.resource === "*" && ruleCoversAction(rule.action, action)) effect = rule.effect
	}
	return effect === "deny"
}

/**
 * Parse agent write capability at boundary.
 * Returns trusted type indicating if agent is read-only.
 *
 * An agent is read-only when BOTH edit and shell are denied. V2 folds the V1
 * `write`/`patch` permissions into `edit`, and renames `bash` to `shell`.
 */
async function parseAgentWriteCapability(
	ctx: Pick<V2PluginContext, "agent">,
	agentName: string,
	log: Logger,
): Promise<{ isReadOnly: boolean }> {
	try {
		const agent = unwrap(await ctx.agent.get({ agentID: agentName })) as V2AgentInfo | undefined
		const rules = agent?.permissions ?? []

		const editDenied = isActionDenied(rules, "edit")
		const shellDenied = isActionDenied(rules, "shell")

		return { isReadOnly: editDenied && shellDenied }
	} catch (error) {
		// Fail-safe: Agent lookup errors shouldn't block subagent calls
		// Fail-loud: Log for observability
		log.warn(
			`Agent lookup failed for "${agentName}", assuming write-capable: ${error instanceof Error ? error.message : String(error)}`,
		)
		return { isReadOnly: false }
	}
}

/**
 * DELEGATION MANAGER
 */
function isTerminalStatus(status: DelegationStatus): status is DelegationTerminalStatus {
	return (
		status === "complete" || status === "error" || status === "cancelled" || status === "timeout"
	)
}

function isActiveStatus(status: DelegationStatus): boolean {
	return status === "registered" || status === "running"
}

function normalizeId(value: string): string {
	return value.trim()
}

function parsePersistedStatus(raw: string | undefined): DelegationStatus {
	if (!raw) return "complete"
	if (raw === "registered") return "registered"
	if (raw === "running") return "running"
	if (raw === "complete") return "complete"
	if (raw === "error") return "error"
	if (raw === "cancelled") return "cancelled"
	if (raw === "timeout") return "timeout"
	return "complete"
}

export class DelegationManager {
	private delegations: Map<string, DelegationRecord> = new Map()
	private delegationsBySession: Map<string, string> = new Map()
	private terminalWaiters: Map<string, { promise: Promise<void>; resolve: () => void }> = new Map()
	private timeoutTimers: Map<string, ReturnType<typeof setTimeout>> = new Map()
	private ctx: ManagerContext
	private baseDir: string
	private log: Logger
	private maxRunTimeMs: number
	private readPollIntervalMs: number
	private terminalWaitGraceMs: number
	private allCompleteQuietPeriodMs: number
	private idGenerator: () => string
	private metadataGenerator: typeof generateMetadata
	private pendingByParent: Map<string, Set<string>> = new Map()
	private parentNotificationState: Map<string, ParentNotificationState> = new Map()

	constructor(
		ctx: ManagerContext,
		baseDir: string,
		log: Logger,
		options: DelegationManagerOptions = {},
	) {
		this.ctx = ctx
		this.baseDir = baseDir
		this.log = log
		this.maxRunTimeMs = options.maxRunTimeMs ?? DEFAULT_MAX_RUN_TIME_MS
		this.readPollIntervalMs = options.readPollIntervalMs ?? READ_POLL_INTERVAL_MS
		this.terminalWaitGraceMs = options.terminalWaitGraceMs ?? TERMINAL_WAIT_GRACE_MS
		this.allCompleteQuietPeriodMs = options.allCompleteQuietPeriodMs ?? ALL_COMPLETE_QUIET_PERIOD_MS
		this.idGenerator = options.idGenerator ?? generateReadableId
		this.metadataGenerator = options.metadataGenerator ?? generateMetadata
	}

	/**
	 * Resolves the root session ID by walking up the parent chain.
	 */
	async getRootSessionID(sessionID: string): Promise<string> {
		// Best effort: if a session cannot be fetched, the last known id is treated as root
		return resolveRootSessionID(this.ctx, sessionID)
	}

	/**
	 * Get the delegations directory for a session scope (root session)
	 */
	private async getDelegationsDir(sessionID: string): Promise<string> {
		const rootID = await this.getRootSessionID(sessionID)
		return path.join(this.baseDir, rootID)
	}

	/**
	 * Ensure the delegations directory exists
	 */
	private async ensureDelegationsDir(sessionID: string): Promise<string> {
		const dir = await this.getDelegationsDir(sessionID)
		await fs.mkdir(dir, { recursive: true })
		return dir
	}

	private createTerminalWaiter(id: string): void {
		if (this.terminalWaiters.has(id)) return

		let resolve: (() => void) | undefined
		const promise = new Promise<void>((innerResolve) => {
			resolve = innerResolve
		})

		if (!resolve) {
			throw new Error(`Failed to initialize terminal waiter for delegation ${id}`)
		}

		this.terminalWaiters.set(id, { promise, resolve })
	}

	private resolveTerminalWaiter(id: string): void {
		const waiter = this.terminalWaiters.get(id)
		if (!waiter) return
		waiter.resolve()
	}

	private clearTimeoutTimer(id: string): void {
		const timer = this.timeoutTimers.get(id)
		if (!timer) return
		clearTimeout(timer)
		this.timeoutTimers.delete(id)
	}

	private scheduleTimeout(id: string): void {
		this.clearTimeoutTimer(id)
		const timer = setTimeout(() => {
			void this.handleTimeout(id)
		}, this.maxRunTimeMs + 5_000)
		this.timeoutTimers.set(id, timer)
	}

	private updateDelegation(
		id: string,
		mutate: (delegation: DelegationRecord, now: Date) => void,
	): DelegationRecord | undefined {
		const delegation = this.delegations.get(id)
		if (!delegation) return undefined

		const now = new Date()
		mutate(delegation, now)
		delegation.updatedAt = now
		return delegation
	}

	private registerDelegation(input: {
		id: string
		rootSessionID: string
		sessionID: string
		parentSessionID: string
		parentMessageID: string
		parentAgent: string
		prompt: string
		agent: string
		artifactPath: string
	}): DelegationRecord {
		if (!this.pendingByParent.has(input.parentSessionID)) {
			this.pendingByParent.set(input.parentSessionID, new Set())
			this.resetParentAllCompleteNotificationCycle(input.parentSessionID)
		}

		const parentNotificationState = this.getParentNotificationState(input.parentSessionID)
		const notificationCycle = parentNotificationState.allCompleteCycle
		const notificationCycleToken = parentNotificationState.allCompleteCycleToken

		const now = new Date()
		const delegation: DelegationRecord = {
			id: input.id,
			rootSessionID: input.rootSessionID,
			sessionID: input.sessionID,
			parentSessionID: input.parentSessionID,
			parentMessageID: input.parentMessageID,
			parentAgent: input.parentAgent,
			prompt: input.prompt,
			agent: input.agent,
			notificationCycle,
			notificationCycleToken,
			status: "registered",
			createdAt: now,
			updatedAt: now,
			timeoutAt: new Date(now.getTime() + this.maxRunTimeMs),
			progress: {
				toolCalls: 0,
				lastUpdateAt: now,
				lastHeartbeatAt: now,
			},
			notification: {
				terminalNotificationCount: 0,
			},
			retrieval: {
				retrievalCount: 0,
			},
			artifact: {
				filePath: input.artifactPath,
			},
		}

		this.delegations.set(delegation.id, delegation)
		this.delegationsBySession.set(delegation.sessionID, delegation.id)
		this.createTerminalWaiter(delegation.id)
		this.pendingByParent.get(delegation.parentSessionID)?.add(delegation.id)

		return delegation
	}

	private markStarted(id: string): DelegationRecord | undefined {
		return this.updateDelegation(id, (delegation, now) => {
			if (isTerminalStatus(delegation.status)) return
			delegation.status = "running"
			delegation.startedAt = now
			delegation.progress.lastUpdateAt = now
			delegation.progress.lastHeartbeatAt = now
		})
	}

	private markProgress(id: string, messageText?: string): DelegationRecord | undefined {
		return this.updateDelegation(id, (delegation, now) => {
			if (isTerminalStatus(delegation.status)) return
			if (delegation.status === "registered") {
				delegation.status = "running"
				delegation.startedAt = delegation.startedAt ?? now
			}

			delegation.progress.lastUpdateAt = now
			delegation.progress.lastHeartbeatAt = now

			if (messageText) {
				delegation.progress.lastMessage = messageText
				delegation.progress.lastMessageAt = now
			}
		})
	}

	private markTerminal(
		id: string,
		status: DelegationTerminalStatus,
		error?: string,
	): { transitioned: boolean; delegation?: DelegationRecord } {
		const delegation = this.delegations.get(id)
		if (!delegation) return { transitioned: false }

		if (isTerminalStatus(delegation.status)) {
			return { transitioned: false, delegation }
		}

		const now = new Date()
		delegation.status = status
		delegation.completedAt = now
		delegation.updatedAt = now
		if (error) {
			delegation.error = error
		}

		const pending = this.pendingByParent.get(delegation.parentSessionID)
		if (pending) {
			pending.delete(delegation.id)
			if (pending.size === 0) {
				this.pendingByParent.delete(delegation.parentSessionID)
			}
		}

		this.clearTimeoutTimer(id)
		this.resolveTerminalWaiter(id)

		return { transitioned: true, delegation }
	}

	private markNotified(id: string): DelegationRecord | undefined {
		return this.updateDelegation(id, (delegation, now) => {
			delegation.notification.terminalNotifiedAt = now
			delegation.notification.terminalNotificationCount += 1
		})
	}

	private getParentNotificationState(parentSessionID: string): ParentNotificationState {
		const existing = this.parentNotificationState.get(parentSessionID)
		if (existing) return existing

		const initialized: ParentNotificationState = {
			allCompleteNotificationCount: 0,
			allCompleteCycle: 0,
			allCompleteCycleToken: this.buildAllCompleteCycleToken(parentSessionID, 0),
		}
		this.parentNotificationState.set(parentSessionID, initialized)
		return initialized
	}

	private buildAllCompleteCycleToken(parentSessionID: string, cycle: number): string {
		return `${parentSessionID}:${cycle}`
	}

	private resetParentAllCompleteNotificationCycle(parentSessionID: string): void {
		const state = this.getParentNotificationState(parentSessionID)
		this.cancelScheduledAllComplete(state)
		state.allCompleteCycle += 1
		state.allCompleteCycleToken = this.buildAllCompleteCycleToken(
			parentSessionID,
			state.allCompleteCycle,
		)
		state.allCompleteNotifiedAt = undefined
		state.allCompleteNotifiedCycle = undefined
		state.allCompleteNotifiedCycleToken = undefined
	}

	private cancelScheduledAllComplete(state: ParentNotificationState): void {
		if (state.allCompleteScheduledTimer) {
			clearTimeout(state.allCompleteScheduledTimer)
		}
		state.allCompleteScheduledTimer = undefined
		state.allCompleteScheduledCycle = undefined
		state.allCompleteScheduledCycleToken = undefined
	}

	private areCycleTerminalNotificationsComplete(
		parentSessionID: string,
		cycleToken: string,
	): boolean {
		let cycleDelegationCount = 0

		for (const delegation of this.delegations.values()) {
			if (delegation.parentSessionID !== parentSessionID) continue
			if (delegation.notificationCycleToken !== cycleToken) continue

			cycleDelegationCount += 1
			if (!delegation.notification.terminalNotifiedAt) {
				return false
			}
		}

		return cycleDelegationCount > 0
	}

	private scheduleAllCompleteForParent(parentSessionID: string, parentAgent: string): void {
		const state = this.getParentNotificationState(parentSessionID)
		const cycle = state.allCompleteCycle
		const cycleToken = state.allCompleteCycleToken
		if (!this.areCycleTerminalNotificationsComplete(parentSessionID, cycleToken)) return

		if (state.allCompleteNotifiedCycleToken === cycleToken) return
		if (state.allCompleteScheduledCycleToken === cycleToken) return

		this.cancelScheduledAllComplete(state)

		state.allCompleteScheduledCycle = cycle
		state.allCompleteScheduledCycleToken = cycleToken
		state.allCompleteScheduledTimer = setTimeout(() => {
			void this.dispatchScheduledAllComplete(parentSessionID, parentAgent, cycle, cycleToken)
		}, this.allCompleteQuietPeriodMs)
	}

	private async dispatchScheduledAllComplete(
		parentSessionID: string,
		_parentAgent: string,
		cycle: number,
		cycleToken: string,
	): Promise<void> {
		const state = this.getParentNotificationState(parentSessionID)

		if (state.allCompleteScheduledCycleToken !== cycleToken) return

		this.cancelScheduledAllComplete(state)

		if (state.allCompleteCycleToken !== cycleToken) return
		if (!this.areCycleTerminalNotificationsComplete(parentSessionID, cycleToken)) return
		if (state.allCompleteNotifiedCycleToken === cycleToken) return

		try {
			// V1: noReply=false (the parent model answers). V2: a synthetic message that resumes the parent.
			await this.ctx.session.synthetic({
				sessionID: parentSessionID,
				text: this.buildAllCompleteNotification(parentSessionID, cycle, cycleToken),
				description: `Background agents complete (cycle ${cycle})`,
				resume: true,
			})
		} catch (error) {
			await this.debugLog(
				`all-complete notification failed for ${parentSessionID} cycle=${cycleToken}: ${
					error instanceof Error ? error.message : "Unknown error"
				}`,
			)
			return
		}

		if (state.allCompleteCycleToken !== cycleToken) return
		if (!this.areCycleTerminalNotificationsComplete(parentSessionID, cycleToken)) return

		state.allCompleteNotifiedAt = new Date()
		state.allCompleteNotificationCount += 1
		state.allCompleteNotifiedCycle = cycle
		state.allCompleteNotifiedCycleToken = cycleToken
	}

	private markRetrieved(id: string, readerSessionID: string): DelegationRecord | undefined {
		return this.updateDelegation(id, (delegation, now) => {
			delegation.retrieval.retrievedAt = now
			delegation.retrieval.retrievalCount += 1
			delegation.retrieval.lastReaderSessionID = readerSessionID
		})
	}

	private hasUnreadCompletion(delegation: DelegationRecord): boolean {
		if (!isTerminalStatus(delegation.status)) return false
		if (!delegation.notification.terminalNotifiedAt) return false
		if (!delegation.completedAt) return false

		if (!delegation.retrieval.retrievedAt) return true
		return delegation.retrieval.retrievedAt.getTime() < delegation.completedAt.getTime()
	}

	private async waitForTerminal(id: string, timeoutMs: number): Promise<"terminal" | "timeout"> {
		const delegation = this.delegations.get(id)
		if (!delegation) return "timeout"
		if (isTerminalStatus(delegation.status)) return "terminal"

		const waiter = this.terminalWaiters.get(id)
		if (!waiter) return "timeout"

		let timer: ReturnType<typeof setTimeout> | undefined
		try {
			const result = await Promise.race<"terminal" | "timeout">([
				waiter.promise.then(() => "terminal"),
				new Promise<"timeout">((resolve) => {
					timer = setTimeout(() => resolve("timeout"), timeoutMs)
				}),
			])
			return result
		} finally {
			if (timer) clearTimeout(timer)
		}
	}

	private async generateUniqueDelegationId(artifactDir: string): Promise<string> {
		for (let attempt = 0; attempt < 20; attempt++) {
			const candidate = this.idGenerator()
			if (this.delegations.has(candidate)) continue

			const candidatePath = path.join(artifactDir, `${candidate}.md`)
			try {
				await fs.access(candidatePath)
			} catch {
				return candidate
			}
		}

		throw new Error("Failed to generate unique delegation ID after 20 attempts")
	}

	private getDelegationBySession(sessionID: string): DelegationRecord | undefined {
		const delegationId = this.delegationsBySession.get(sessionID)
		if (!delegationId) return undefined
		return this.delegations.get(delegationId)
	}

	private isVisibleToSession(delegation: DelegationRecord, rootSessionID: string): boolean {
		return delegation.rootSessionID === rootSessionID
	}

	private buildTerminalNotification(delegation: DelegationRecord, remainingCount: number): string {
		const lines = [
			"<task-notification>",
			`<task-id>${delegation.id}</task-id>`,
			`<status>${delegation.status}</status>`,
			`<summary>Background agent ${delegation.status}: ${delegation.title || delegation.id}</summary>`,
			delegation.title ? `<title>${delegation.title}</title>` : "",
			delegation.description ? `<description>${delegation.description}</description>` : "",
			delegation.error ? `<error>${delegation.error}</error>` : "",
			`<artifact>${delegation.artifact.filePath}</artifact>`,
			`<retrieval>Use delegation_read("${delegation.id}") for full output.</retrieval>`,
			remainingCount > 0 ? `<remaining>${remainingCount}</remaining>` : "",
			"</task-notification>",
		]

		return lines.filter((line) => line.length > 0).join("\n")
	}

	private buildAllCompleteNotification(
		parentSessionID: string,
		cycle: number,
		cycleToken: string,
	): string {
		// cycle-token is a boundary watermark.
		// Receivers should ignore all-complete payloads whose token is older than
		// the latest known registration cycle for this parent session.
		return [
			"<task-notification>",
			"<type>all-complete</type>",
			"<status>completed</status>",
			"<summary>All delegations complete.</summary>",
			`<parent-session-id>${parentSessionID}</parent-session-id>`,
			`<cycle>${cycle}</cycle>`,
			`<cycle-token>${cycleToken}</cycle-token>`,
			"</task-notification>",
		].join("\n")
	}

	private buildDeterministicTerminalReadResponse(delegation: DelegationRecord): string {
		const lines = [
			`Delegation ID: ${delegation.id}`,
			`Status: ${delegation.status}`,
			`Agent: ${delegation.agent}`,
			`Started: ${delegation.startedAt?.toISOString() || delegation.createdAt.toISOString()}`,
			`Completed: ${delegation.completedAt?.toISOString() || "N/A"}`,
			`Artifact: ${delegation.artifact.filePath}`,
		]

		if (delegation.title) lines.push(`Title: ${delegation.title}`)
		if (delegation.description) lines.push(`Description: ${delegation.description}`)
		if (delegation.error) lines.push(`Error: ${delegation.error}`)

		lines.push(`\nUse delegation_read("${delegation.id}") again after persistence completes.`)
		return lines.join("\n")
	}

	private async readPersistedArtifact(filePath: string): Promise<string | null> {
		try {
			return await fs.readFile(filePath, "utf8")
		} catch {
			return null
		}
	}

	private async waitForPersistedArtifact(
		filePath: string,
		maxWaitMs: number,
	): Promise<string | null> {
		const start = Date.now()
		while (Date.now() - start < maxWaitMs) {
			const content = await this.readPersistedArtifact(filePath)
			if (content !== null) return content
			await new Promise((resolve) => setTimeout(resolve, this.readPollIntervalMs))
		}

		return null
	}

	private async resolveDelegationResult(delegation: DelegationRecord): Promise<string> {
		if (delegation.status === "error") {
			return `Error: ${delegation.error || "Delegation failed."}`
		}

		if (delegation.status === "cancelled") {
			return "Delegation was cancelled before completion."
		}

		if (delegation.status === "timeout") {
			const partial = await this.getResult(delegation)
			return `${partial}\n\n[TIMEOUT REACHED]`
		}

		return await this.getResult(delegation)
	}

	private async finalizeDelegation(
		delegationId: string,
		status: DelegationTerminalStatus,
		error?: string,
	): Promise<void> {
		const { transitioned, delegation } = this.markTerminal(delegationId, status, error)
		if (!transitioned || !delegation) return

		await this.debugLog(`finalizeDelegation(${delegation.id}, ${status}) started`)

		const resolvedResult = await this.resolveDelegationResult(delegation)
		delegation.result = resolvedResult

		if (resolvedResult.trim().length > 0) {
			const metadata = await this.metadataGenerator(
				this.ctx,
				resolvedResult,
				delegation.sessionID,
				(msg) => this.debugLog(msg),
			)
			delegation.title = metadata.title
			delegation.description = metadata.description
		}

		await this.persistOutput(delegation, resolvedResult)
		await this.notifyParent(delegation.id)
	}

	private async notifyParent(delegationId: string): Promise<void> {
		try {
			const delegation = this.delegations.get(delegationId)
			if (!delegation) return
			if (!isTerminalStatus(delegation.status)) return
			if (delegation.notification.terminalNotifiedAt) {
				await this.debugLog(`notifyParent skipped for ${delegation.id}; already notified`)
				return
			}

			const remainingCount = this.getPendingCount(delegation.parentSessionID)
			const terminalNotification = this.buildTerminalNotification(delegation, remainingCount)

			// V1: noReply=true (record the notification, do not trigger a reply).
			await this.ctx.session.synthetic({
				sessionID: delegation.parentSessionID,
				text: terminalNotification,
				description: `Background agent ${delegation.status}: ${delegation.title || delegation.id}`,
				resume: false,
			})

			this.markNotified(delegation.id)
			this.scheduleAllCompleteForParent(delegation.parentSessionID, delegation.parentAgent)

			await this.debugLog(
				`notifyParent sent for ${delegation.id} (remaining=${remainingCount}, status=${delegation.status})`,
			)
		} catch (error) {
			await this.debugLog(
				`notifyParent failed for ${delegationId}: ${error instanceof Error ? error.message : "Unknown error"}`,
			)
		}
	}

	/**
	 * Delegate a task to an agent
	 */
	async delegate(input: DelegateInput): Promise<DelegationRecord> {
		// Validate agent exists before creating session
		const agents = unwrap(await this.ctx.agent.list()) ?? []
		const validAgent = agents.find((a) => a.id === input.agent)

		if (!validAgent) {
			const available = agents
				.filter((a) => !a.hidden && (a.mode === "subagent" || a.mode === "all" || !a.mode))
				.map((a) => `• ${a.id}${a.description ? ` - ${a.description}` : ""}`)
				.join("\n")

			throw new Error(
				`Agent "${input.agent}" not found.\n\nAvailable agents:\n${available || "(none)"}`,
			)
		}

		// Check if agent is read-only (Early Exit + Fail Fast)
		const { isReadOnly } = await parseAgentWriteCapability(this.ctx, input.agent, this.log)
		if (!isReadOnly) {
			throw new Error(
				`Agent "${input.agent}" is write-capable and requires the native \`subagent\` tool for proper undo/branching support.\n\n` +
					`Use \`subagent\` instead of \`delegate\` for write-capable agents.\n\n` +
					`Read-only sub-agents (edit/shell denied) use \`delegate\`.\n` +
					`Write-capable sub-agents (any write permission) use \`subagent\`.`,
			)
		}

		const artifactDir = await this.ensureDelegationsDir(input.parentSessionID)
		const rootSessionID = await this.getRootSessionID(input.parentSessionID)
		const stableId = await this.generateUniqueDelegationId(artifactDir)
		const artifactPath = path.join(artifactDir, `${stableId}.md`)

		await this.debugLog(`delegate() called, generated stable ID: ${stableId}`)

		// Create isolated session for delegation, bound to the target agent.
		// (V1 passed the agent on each prompt; V2 sessions own their agent.)
		const delegationSession = await this.ctx.session.create({
			title: `Delegation: ${stableId}`,
			parentID: input.parentSessionID,
			agent: input.agent,
			permissions: NESTED_DENY_RULES,
		})

		await this.debugLog(`session.create result: ${JSON.stringify(delegationSession)}`)

		if (!delegationSession?.id) {
			throw new Error("Failed to create delegation session")
		}

		const delegation = this.registerDelegation({
			id: stableId,
			rootSessionID,
			sessionID: delegationSession.id,
			parentSessionID: input.parentSessionID,
			parentMessageID: input.parentMessageID,
			parentAgent: input.parentAgent,
			prompt: input.prompt,
			agent: input.agent,
			artifactPath,
		})

		await this.debugLog(`Registered delegation ${delegation.id} before execution`)
		this.scheduleTimeout(delegation.id)
		this.markStarted(delegation.id)

		// Admit the prompt; the run proceeds asynchronously and its outcome arrives as
		// session.execution.* events (V1 awaited the whole run in a fire-and-forget promise).
		// Anti-recursion: nested delegation and state-modifying tools are denied for this session
		// (see NESTED_TOOL_BLOCKLIST).
		this.ctx.session
			.prompt({
				sessionID: delegation.sessionID,
				text: input.prompt,
			})
			.catch((error: Error) => {
				void this.finalizeDelegation(delegation.id, "error", error.message)
			})

		return delegation
	}

	/**
	 * Handle delegation timeout
	 */
	private async handleTimeout(delegationId: string): Promise<void> {
		const delegation = this.delegations.get(delegationId)
		if (!delegation || isTerminalStatus(delegation.status)) return

		await this.debugLog(`handleTimeout for delegation ${delegation.id}`)

		// Finalize first: the terminal transition happens synchronously, so the
		// session.execution.interrupted event our own interrupt provokes cannot win the race.
		const finalizing = this.finalizeDelegation(
			delegation.id,
			"timeout",
			`Delegation timed out after ${this.maxRunTimeMs / 1000}s`,
		)

		// Try to cancel the session (V1 deleted it; interrupting keeps the partial output readable)
		try {
			await this.ctx.session.interrupt({ sessionID: delegation.sessionID, resume: false })
		} catch {
			// Ignore
		}

		await finalizing
	}

	/**
	 * Handle a session finishing its run successfully (V1: session.idle,
	 * V2: session.execution.succeeded).
	 */
	async handleSessionIdle(sessionID: string): Promise<void> {
		const delegation = this.findBySession(sessionID)
		if (!delegation || isTerminalStatus(delegation.status)) return

		await this.debugLog(`handleSessionIdle for delegation ${delegation.id}`)
		await this.finalizeDelegation(delegation.id, "complete")
	}

	/**
	 * Handle a delegated session whose run failed (V1 surfaced this as a rejected prompt()).
	 */
	async handleSessionFailed(sessionID: string, error?: string): Promise<void> {
		const delegation = this.findBySession(sessionID)
		if (!delegation || isTerminalStatus(delegation.status)) return

		await this.debugLog(`handleSessionFailed for delegation ${delegation.id}: ${error ?? "unknown"}`)
		await this.finalizeDelegation(delegation.id, "error", error ?? "Delegated session failed")
	}

	/**
	 * Handle a delegated session whose run was interrupted (user, shutdown, ...).
	 */
	async handleSessionInterrupted(sessionID: string, reason?: string): Promise<void> {
		const delegation = this.findBySession(sessionID)
		if (!delegation || isTerminalStatus(delegation.status)) return

		await this.debugLog(`handleSessionInterrupted for delegation ${delegation.id}: ${reason ?? "unknown"}`)
		await this.finalizeDelegation(
			delegation.id,
			"cancelled",
			`Delegation interrupted${reason ? ` (${reason})` : ""}`,
		)
	}

	/**
	 * Get the result from a delegation's session
	 */
	private async getResult(delegation: DelegationRecord): Promise<string> {
		try {
			const messageData = (await this.ctx.session.context({
				sessionID: delegation.sessionID,
			})) as SessionMessageItem[] | undefined

			if (!messageData || messageData.length === 0) {
				await this.debugLog(`getResult: No messages found for session ${delegation.sessionID}`)
				return `Delegation "${delegation.description}" completed but produced no output.`
			}

			await this.debugLog(
				`getResult: Found ${messageData.length} messages. Types: ${messageData.map((m) => m.type).join(", ")}`,
			)

			// Find the last message from the assistant/model
			const assistantMessages = messageData.filter((m) => m.type === "assistant")

			if (assistantMessages.length === 0) {
				await this.debugLog(
					`getResult: No assistant messages found in ${JSON.stringify(messageData.map((m) => ({ type: m.type, keys: Object.keys(m) })))}`,
				)
				return `Delegation "${delegation.description}" completed but produced no assistant response.`
			}

			const lastMessage = assistantMessages[assistantMessages.length - 1]

			// Extract text parts from the message
			const textParts = (lastMessage.content ?? []).filter(
				(p): p is { type: "text"; text: string } => p.type === "text" && typeof p.text === "string",
			)

			if (textParts.length === 0) {
				await this.debugLog(
					`getResult: No text parts found in message: ${JSON.stringify(lastMessage)}`,
				)
				return `Delegation "${delegation.description}" completed but produced no text content.`
			}

			return textParts.map((p) => p.text).join("\n")
		} catch (error) {
			await this.debugLog(
				`getResult error: ${error instanceof Error ? error.message : "Unknown error"}`,
			)
			return `Delegation "${delegation.description}" completed but result could not be retrieved: ${
				error instanceof Error ? error.message : "Unknown error"
			}`
		}
	}

	/**
	 * Persist delegation output to storage
	 */
	private async persistOutput(delegation: DelegationRecord, content: string): Promise<void> {
		try {
			// Use title/description if available (generated by small model), otherwise fallback
			const title = delegation.title || delegation.id
			const description = delegation.description || "(No description generated)"

			const header = `# ${title}

${description}

**ID:** ${delegation.id}
**Agent:** ${delegation.agent}
**Status:** ${delegation.status}
**Session:** ${delegation.sessionID}
**Started:** ${(delegation.startedAt || delegation.createdAt).toISOString()}
**Completed:** ${delegation.completedAt?.toISOString() || "N/A"}

---

`
			await fs.writeFile(delegation.artifact.filePath, header + content, "utf8")

			const stats = await fs.stat(delegation.artifact.filePath)
			this.updateDelegation(delegation.id, (record, now) => {
				record.artifact.persistedAt = now
				record.artifact.byteLength = stats.size
				record.artifact.persistError = undefined
			})

			await this.debugLog(`Persisted output to ${delegation.artifact.filePath}`)
		} catch (error) {
			this.updateDelegation(delegation.id, (record) => {
				record.artifact.persistError =
					error instanceof Error ? error.message : "Unknown persistence error"
			})
			await this.debugLog(
				`Failed to persist output: ${error instanceof Error ? error.message : "Unknown error"}`,
			)
		}
	}

	/**
	 * Read a delegation's output by ID. Blocks if the delegation is still running.
	 */
	async readOutput(sessionID: string, id: string): Promise<string> {
		const normalizedId = normalizeId(id)
		if (!normalizedId) {
			throw new Error("Delegation ID is required")
		}

		const rootSessionID = await this.getRootSessionID(sessionID)
		let delegation = this.delegations.get(normalizedId)
		if (delegation && !this.isVisibleToSession(delegation, rootSessionID)) {
			delegation = undefined
		}

		const fallbackFilePath = path.join(
			await this.getDelegationsDir(sessionID),
			`${normalizedId}.md`,
		)

		const immediateArtifactPath = delegation?.artifact.filePath || fallbackFilePath
		const immediateRead = await this.readPersistedArtifact(immediateArtifactPath)
		if (immediateRead !== null) {
			if (delegation) this.markRetrieved(delegation.id, sessionID)
			return immediateRead
		}

		if (!delegation) {
			throw new Error(
				`Delegation "${normalizedId}" not found.\n\nUse delegation_list() to see available delegations.`,
			)
		}

		if (isActiveStatus(delegation.status)) {
			const remainingMs = Math.max(
				delegation.timeoutAt.getTime() - Date.now() + this.terminalWaitGraceMs,
				this.readPollIntervalMs,
			)

			await this.debugLog(
				`readOutput: waiting up to ${remainingMs}ms for delegation ${delegation.id} to reach terminal state`,
			)

			const waitResult = await this.waitForTerminal(delegation.id, remainingMs)
			if (waitResult === "timeout" && isActiveStatus(delegation.status)) {
				await this.handleTimeout(delegation.id)
			}
		}

		if (isTerminalStatus(delegation.status)) {
			// Persistence follows metadata generation (an LLM round trip bounded by
			// METADATA_TIMEOUT_MS), so the wait must outlast it or a read racing the
			// terminal transition gets the "persistence pending" stub instead of the output.
			const delayedPersisted = await this.waitForPersistedArtifact(
				delegation.artifact.filePath,
				Math.max(this.readPollIntervalMs * 8, 500, METADATA_TIMEOUT_MS + this.terminalWaitGraceMs),
			)
			if (delayedPersisted !== null) {
				this.markRetrieved(delegation.id, sessionID)
				return delayedPersisted
			}
		}

		const persisted = await this.readPersistedArtifact(delegation.artifact.filePath)
		if (persisted !== null) {
			this.markRetrieved(delegation.id, sessionID)
			return persisted
		}

		if (isTerminalStatus(delegation.status)) {
			return this.buildDeterministicTerminalReadResponse(delegation)
		}

		return `Delegation "${delegation.id}" is still running. You will receive a <task-notification> when it reaches a terminal state.`
	}

	/**
	 * List all delegations for a session
	 */
	async listDelegations(sessionID: string): Promise<DelegationListItem[]> {
		const rootSessionID = await this.getRootSessionID(sessionID)
		const results: DelegationListItem[] = []

		// Add in-memory delegations in this root session scope
		for (const delegation of this.delegations.values()) {
			if (!this.isVisibleToSession(delegation, rootSessionID)) continue

			results.push({
				id: delegation.id,
				status: delegation.status,
				title: delegation.title || delegation.id,
				description:
					delegation.description ||
					(delegation.status === "running" || delegation.status === "registered"
						? "(running)"
						: "(no description)"),
				agent: delegation.agent,
				unread: this.hasUnreadCompletion(delegation),
			})
		}

		// Check filesystem for persisted delegations
		try {
			const dir = await this.getDelegationsDir(rootSessionID)
			const files = await fs.readdir(dir)

			for (const file of files) {
				if (file.endsWith(".md")) {
					const id = file.replace(".md", "")
					// Deduplicate: prioritize in-memory status
					if (!results.find((r) => r.id === id)) {
						// Try to read title, agent, description from file
						let title = "(loaded from storage)"
						let description = ""
						let agent: string | undefined
						let status: DelegationStatus = "complete"
						try {
							const filePath = path.join(dir, file)
							const content = await fs.readFile(filePath, "utf8")
							const titleMatch = content.match(/^# (.+)$/m)
							if (titleMatch) title = titleMatch[1]
							const agentMatch = content.match(/^\*\*Agent:\*\* (.+)$/m)
							if (agentMatch) agent = agentMatch[1]
							const statusMatch = content.match(/^\*\*Status:\*\* (.+)$/m)
							status = parsePersistedStatus(statusMatch?.[1]?.trim())
							// Get first paragraph after title as description
							const lines = content.split("\n")
							if (lines.length > 2 && lines[2]) {
								description = lines[2].slice(0, 150)
							}
						} catch {
							// Ignore read errors
						}
						results.push({
							id,
							status,
							title,
							description,
							agent,
							unread: false,
						})
					}
				}
			}
		} catch {
			// Directory may not exist yet
		}

		results.sort((a, b) => a.id.localeCompare(b.id))
		return results
	}

	/**
	 * Delete a delegation by id (cancels if running, removes from storage)
	 * Used internally for cleanup (timeout, etc.)
	 */
	async deleteDelegation(sessionID: string, id: string): Promise<boolean> {
		const normalizedId = normalizeId(id)
		const delegation = this.delegations.get(normalizedId)

		if (delegation) {
			if (isActiveStatus(delegation.status)) {
				try {
					await this.ctx.session.remove({ sessionID: delegation.sessionID })
				} catch {
					// Session may already be deleted
				}
				this.markTerminal(delegation.id, "cancelled", "Delegation deleted by cleanup")
			}

			this.clearTimeoutTimer(delegation.id)
			this.terminalWaiters.delete(delegation.id)
			this.delegationsBySession.delete(delegation.sessionID)
			this.delegations.delete(delegation.id)
		}

		// Remove from filesystem
		try {
			const dir = await this.getDelegationsDir(sessionID)
			const filePath = path.join(dir, `${normalizedId}.md`)
			await fs.unlink(filePath)
			return true
		} catch {
			return false
		}
	}

	/**
	 * Find a delegation by its session ID
	 */
	findBySession(sessionID: string): DelegationRecord | undefined {
		return this.getDelegationBySession(sessionID)
	}

	/**
	 * Handle message events for progress tracking
	 */
	handleMessageEvent(sessionID: string, messageText?: string): void {
		const delegation = this.findBySession(sessionID)
		if (!delegation) return
		this.markProgress(delegation.id, messageText)
	}

	/**
	 * Get count of pending delegations for a parent session
	 */
	getPendingCount(parentSessionID: string): number {
		const pendingSet = this.pendingByParent.get(parentSessionID)
		if (!pendingSet) return 0
		return Array.from(pendingSet).filter((id) => {
			const delegation = this.delegations.get(id)
			return delegation ? isActiveStatus(delegation.status) : false
		}).length
	}

	/**
	 * Get all currently running delegations (in-memory only)
	 */
	getRunningDelegations(rootSessionID?: string): DelegationRecord[] {
		return Array.from(this.delegations.values()).filter((delegation) => {
			if (rootSessionID && delegation.rootSessionID !== rootSessionID) return false
			return isActiveStatus(delegation.status)
		})
	}

	getUnreadCompletedDelegations(rootSessionID: string, limit = 10): DelegationRecord[] {
		return Array.from(this.delegations.values())
			.filter((delegation) => delegation.rootSessionID === rootSessionID)
			.filter((delegation) => this.hasUnreadCompletion(delegation))
			.sort((a, b) => {
				const aTime = a.completedAt?.getTime() || 0
				const bTime = b.completedAt?.getTime() || 0
				return bTime - aTime
			})
			.slice(0, limit)
	}

	/**
	 * Get recent completed delegations for compaction injection
	 */
	async getRecentCompletedDelegations(
		sessionID: string,
		limit: number = 10,
	): Promise<DelegationListItem[]> {
		const all = await this.listDelegations(sessionID)
		return all.filter((d) => isTerminalStatus(d.status)).slice(-limit)
	}

	/**
	 * Log debug messages
	 */
	async debugLog(msg: string): Promise<void> {
		// Only log if debug is enabled (could be env var or static const)
		// For now, mirroring previous behavior but writing to the new baseDir/debug.log
		const timestamp = new Date().toISOString()
		const line = `${timestamp}: ${msg}\n`
		const debugFile = path.join(this.baseDir, "background-agents-debug.log")

		try {
			await fs.appendFile(debugFile, line, "utf8")
		} catch {
			// Ignore errors, try to ensure dir once if it fails?
			// Simpler to just ignore for debug logs
		}
	}
}

// ==========================================
// TOOL CREATORS
// ==========================================

function createDelegate(manager: DelegationManager): V2ToolDefinition {
	return {
		name: "delegate",
		description: `Delegate a task to an agent. Returns immediately with a readable ID.

Use this for:
- Research tasks (will be auto-saved)
- Parallel work that can run in background
- Any task where you want persistent, retrievable output

On completion, a notification will arrive with the ID and terminal summary.
Use \`delegation_read\` with the ID to retrieve full persisted output (including after compaction).`,
		input: {
			type: "object",
			properties: {
				prompt: {
					type: "string",
					description: "The full detailed prompt for the agent. Must be in English.",
				},
				agent: {
					type: "string",
					description:
						'Agent to delegate to. Must be a read-only sub-agent (edit/shell denied), such as "researcher" or "explore".',
				},
			},
			required: ["prompt", "agent"],
			additionalProperties: false,
		},
		async execute(input, toolCtx) {
			const args = input as { prompt: string; agent: string }
			if (!toolCtx?.sessionID) {
				return text("❌ delegate requires sessionID. This is a system error.")
			}
			if (!toolCtx?.messageID) {
				return text("❌ delegate requires messageID. This is a system error.")
			}

			try {
				const delegation = await manager.delegate({
					parentSessionID: toolCtx.sessionID,
					parentMessageID: toolCtx.messageID,
					parentAgent: toolCtx.agent,
					prompt: args.prompt,
					agent: args.agent,
				})

				// Get total active count for this parent session
				const pendingSet = manager.getPendingCount(toolCtx.sessionID)
				const totalActive = pendingSet

				let response = `Delegation started: ${delegation.id}\nAgent: ${args.agent}`
				if (totalActive > 1) {
					response += `\n\n${totalActive} delegations now active.`
				}
				response += `\nYou WILL be notified when ${totalActive > 1 ? "ALL complete" : "complete"}. Do NOT poll.`

				return text(response)
			} catch (error) {
				// Return validation errors as guidance, not exceptions
				return text(
					`❌ Delegation failed:\n\n${error instanceof Error ? error.message : "Unknown error"}`,
				)
			}
		},
	}
}

function createDelegationRead(manager: DelegationManager): V2ToolDefinition {
	return {
		name: "delegation_read",
		description: `Read the output of a delegation by its ID.
Use this to retrieve results from delegated tasks if the inline notification was lost during compaction.`,
		input: {
			type: "object",
			properties: {
				id: { type: "string", description: "The delegation ID (e.g., 'elegant-blue-tiger')" },
			},
			required: ["id"],
			additionalProperties: false,
		},
		async execute(input, toolCtx) {
			if (!toolCtx?.sessionID) {
				return text("❌ delegation_read requires sessionID. This is a system error.")
			}

			return text(await manager.readOutput(toolCtx.sessionID, (input as { id: string }).id))
		},
	}
}

function createDelegationList(manager: DelegationManager): V2ToolDefinition {
	return {
		name: "delegation_list",
		description: `List all delegations for the current session.
Shows both running and completed delegations.`,
		input: { type: "object", properties: {}, additionalProperties: false },
		async execute(_input, toolCtx) {
			if (!toolCtx?.sessionID) {
				return text("❌ delegation_list requires sessionID. This is a system error.")
			}

			const delegations = await manager.listDelegations(toolCtx.sessionID)

			if (delegations.length === 0) {
				return text("No delegations found for this session.")
			}

			const lines = delegations.map((d) => {
				const titlePart = d.title ? ` | ${d.title}` : ""
				const unreadPart = d.unread ? " [unread]" : ""
				const descPart = d.description ? `\n  → ${d.description}` : ""
				return `- **${d.id}**${titlePart} [${d.status}]${unreadPart}${descPart}`
			})

			return text(`## Delegations\n\n${lines.join("\n")}`)
		},
	}
}

// ==========================================
// DELEGATION RULES (injected into system prompt)
// ==========================================

const DELEGATION_RULES = `<task-notification>
<delegation-system>

## Async Delegation

You have tools for parallel background work:
- \`delegate(prompt, agent)\` - Launch task, returns ID immediately
- \`delegation_read(id)\` - Retrieve completed result
- \`delegation_list()\` - List delegations (use sparingly)

## Delegation Routing

Agents route based on their permissions:

| Agent Type | Tool | Why |
|------------|------|-----|
| Read-only sub-agents (edit/shell denied) | \`delegate\` | Background session, async |
| Write-capable sub-agents (any write permission) | \`subagent\` | Native subagent, preserves undo/branching |

**Read-only sub-agents** have edit="deny" and shell="deny" (bash is called shell in OpenCode 2).
**Write-capable sub-agents** have any write tool enabled.

## How It Works

1. For read-only sub-agents: Call \`delegate\` with detailed prompt
2. For write-capable sub-agents: Call \`subagent\` with detailed prompt
3. Continue productive work while it runs
4. Receive notification when complete
5. Call \`delegation_read(id)\` to retrieve results

## Critical Constraints

**NEVER poll \`delegation_list\` to check completion.**
You WILL be notified via \`<task-notification>\`. Polling wastes tokens.

**NEVER wait idle.** Always have productive work while delegations run.

**Using wrong tool will fail fast with guidance.**

</delegation-system>
</task-notification>`

// ==========================================
// COMPACTION CONTEXT FORMATTING
// ==========================================

interface DelegationForContext {
	id: string
	agent?: string
	title?: string
	description?: string
	status: DelegationStatus
	startedAt?: Date
	completedAt?: Date
	lastHeartbeatAt?: Date
	prompt?: string
}

/**
 * Format delegation context for injection during compaction.
 * Includes running delegations with notification reminder (only when running exist),
 * and recent completed delegations with full descriptions.
 */
export function formatDelegationContext(
	running: DelegationForContext[],
	unreadCompleted: DelegationForContext[],
): string {
	const sections: string[] = ["<delegation-context>"]

	// Running delegations (if any)
	if (running.length > 0) {
		sections.push("## Running Delegations")
		sections.push("")
		for (const d of running) {
			sections.push(`### \`${d.id}\`${d.agent ? ` (${d.agent})` : ""}`)
			if (d.startedAt) {
				sections.push(`**Started:** ${d.startedAt.toISOString()}`)
			}
			if (d.lastHeartbeatAt) {
				sections.push(`**Last heartbeat:** ${d.lastHeartbeatAt.toISOString()}`)
			}
			if (d.prompt) {
				const truncatedPrompt = d.prompt.length > 200 ? `${d.prompt.slice(0, 200)}...` : d.prompt
				sections.push(`**Prompt:** ${truncatedPrompt}`)
			}
			sections.push("")
		}

		// Only include reminder when there ARE running delegations
		sections.push(
			"> **Note:** You WILL be notified via `<task-notification>` when delegations complete.",
		)
		sections.push("> Do NOT poll `delegation_list` - continue productive work.")
		sections.push("")
	}

	// Unread completed delegations (recent)
	if (unreadCompleted.length > 0) {
		sections.push("## Unread Completed Delegations")
		sections.push("")
		for (const d of unreadCompleted) {
			const statusEmoji =
				d.status === "complete"
					? "✅"
					: d.status === "error"
						? "❌"
						: d.status === "timeout"
							? "⏱️"
							: "🚫"
			sections.push(`### ${statusEmoji} \`${d.id}\``)
			sections.push(`**Title:** ${d.title || "(no title)"}`)
			sections.push(`**Status:** ${d.status}`)
			sections.push(`**Description:** ${d.description || "(no description)"}`)
			if (d.completedAt) {
				sections.push(`**Completed:** ${d.completedAt.toISOString()}`)
			}
			sections.push(`**Retrieve:** \`delegation_read("${d.id}")\``)
			sections.push("")
		}
		sections.push("> These are unread terminal delegations carried forward through compaction.")
		sections.push("")
	}

	sections.push("## Retrieval")
	sections.push('Use `delegation_read("id")` to access full delegation output.')
	sections.push("Do not poll delegation_list for completion; rely on task notifications.")
	sections.push("</delegation-context>")

	return sections.join("\n")
}

// ==========================================
// PLUGIN EXPORT
// ==========================================

/** Names of the native subagent-spawning tool: `subagent` in V2, `task` in V1. */
const NATIVE_SUBAGENT_TOOLS = new Set(["subagent", "task"])

const BackgroundAgentsPlugin: V2PluginDefinition = {
	id: "kdco.background-agents",
	async setup(rawCtx) {
		const ctx = rawCtx as V2PluginContext
		const directory = ctx.location.directory

		// Create logger early for all components
		const log = createLogger()

		// Project-level storage directory (shared across sessions)
		// Uses git root commit hash for cross-worktree consistency
		const projectId = await getProjectId(directory)
		const baseDir = path.join(os.homedir(), ".local", "share", "opencode", "delegations", projectId)

		// Ensure base directory exists (for debug logs etc)
		await fs.mkdir(baseDir, { recursive: true })

		const manager = new DelegationManager(ctx, baseDir, log)

		await manager.debugLog("BackgroundAgentsPlugin initialized with delegation system")

		await ctx.tool.transform((editor) => {
			editor.add(createDelegate(manager))
			editor.add(createDelegationRead(manager))
			editor.add(createDelegationList(manager))
		})

		// Prevent read-only agents from using the native subagent tool (symmetric to delegate enforcement)
		await ctx.tool.hook("execute.before", async (event) => {
			// Guard: delegation sessions may not reach nested-delegation / state-modifying tools,
			// whichever route the call took (direct or through Code Mode)
			if (
				(NESTED_TOOL_BLOCKLIST as readonly string[]).includes(event.tool) &&
				manager.findBySession(event.sessionID)
			) {
				throw new Error(`❌ ${event.tool} is not available inside a delegation session.`)
			}

			// Guard: Only intercept the native subagent tool
			if (!NATIVE_SUBAGENT_TOOLS.has(event.tool)) return

			// Guard: Require agent name (V2 `agent`; V1 `subagent_type`)
			const input = asRecord(event.input)
			const agentName = (input.agent ?? input.subagent_type) as string | undefined
			if (!agentName || typeof agentName !== "string") return

			// Parse boundary 1: Check agent mode
			const { isSubAgent } = await parseAgentMode(ctx, agentName, log)

			// Guard: Allow non-sub-agents (main/built-in)
			if (!isSubAgent) return

			// Parse boundary 2: Check write capability (only for sub-agents)
			const { isReadOnly } = await parseAgentWriteCapability(ctx, agentName, log)

			// Guard: Allow write-capable agents
			if (!isReadOnly) return

			// Fail fast: Read-only sub-agent via the native tool is invalid
			throw new Error(
				`❌ Agent '${agentName}' is read-only and should use the delegate tool for async background execution.\n\n` +
					`Read-only agents have: edit="deny", shell="deny"\n` +
					`Use delegate for read-only sub-agents.\n` +
					`Use subagent for write-capable sub-agents.`,
			)
		})

		// Inject delegation rules into the system prompt; strip nested-delegation tools from delegation sessions
		await ctx.session.hook("context", (event) => {
			event.system.push({ type: "text", text: DELEGATION_RULES })

			if (manager.findBySession(event.sessionID)) {
				for (const name of NESTED_TOOL_BLOCKLIST) delete event.tools[name]
			}
		})

		// Compaction hook - inject delegation context for context recovery
		await ctx.session.hook("compaction", async (event) => {
			const rootSessionID = await manager.getRootSessionID(event.sessionID)

			// Running delegations in this root session tree
			const running = manager.getRunningDelegations(rootSessionID).map((d) => ({
				id: d.id,
				agent: d.agent,
				title: d.title,
				description: d.description,
				status: d.status,
				startedAt: d.startedAt,
				lastHeartbeatAt: d.progress.lastHeartbeatAt,
				prompt: d.prompt,
			}))

			// Unread completed delegations to carry forward through compaction
			const unreadCompleted = manager.getUnreadCompletedDelegations(rootSessionID, 10).map((d) => ({
				id: d.id,
				agent: d.agent,
				title: d.title,
				description: d.description,
				status: d.status,
				completedAt: d.completedAt,
			}))

			// Early exit if nothing to inject
			if (running.length === 0 && unreadCompleted.length === 0) return

			event.system.push({ type: "text", text: formatDelegationContext(running, unreadCompleted) })
		})

		// Event stream: delegated-session lifecycle + progress tracking
		const stopEvents = startEventLoop(
			ctx,
			async (event: V2Event) => {
				const sessionID = typeof event.data?.sessionID === "string" ? event.data.sessionID : undefined
				if (!sessionID) return

				switch (event.type) {
					case "session.execution.succeeded":
						await manager.handleSessionIdle(sessionID)
						break
					case "session.execution.failed": {
						const error = asRecord(event.data.error)
						await manager.handleSessionFailed(
							sessionID,
							typeof error.message === "string" ? error.message : undefined,
						)
						break
					}
					case "session.execution.interrupted":
						await manager.handleSessionInterrupted(
							sessionID,
							typeof event.data.reason === "string" ? event.data.reason : undefined,
						)
						break
					case "session.text.ended":
						manager.handleMessageEvent(
							sessionID,
							typeof event.data.text === "string" ? event.data.text : undefined,
						)
						break
					case "session.tool.called":
						manager.handleMessageEvent(sessionID)
						break
				}
			},
			(error, event) =>
				log.warn(`event handler failed${event ? ` (${event.type})` : ""}: ${error instanceof Error ? error.message : String(error)}`),
		)

		return stopEvents
	},
}

export default BackgroundAgentsPlugin
