#!/usr/bin/env node
/**
 * lib/mcp-server.mjs -- the 0.8.0 second delivery form: the same engine over MCP stdio.
 *
 * WHY THIS FILE EXISTS AND NOTHING UNDER src/engine/ CHANGED. The MCP Registry accepts MCP servers
 * only, and DSH can bridge an MCP server through @deepseek-ai/dsh-mcp-client, so one implementation
 * reaches two channels. That is a deliberate reversal of the 2026-11-19 decision (form = A, no MCP),
 * and the reversal is safe precisely because nothing here re-implements anything: the tool object is
 * the one `apply()` already builds for the host half, so `toRequest()`, the gate order, the refusal
 * vocabulary, the audit line and `format()` are shared rather than copied. A second implementation of
 * a permission is a permission that can be reached around by using the other copy -- which is also why
 * the schema below is GENERATED from src/schema/tools.json instead of transcribed (risk R6).
 *
 * FOUR THINGS THIS FILE OWNS, none of which is an action:
 *   1. JSON-RPC 2.0 framing over stdio -- one JSON object per line, replies keyed by `id`, so two
 *      calls in flight may answer in any order (the worker is asynchronous; assuming FIFO would be
 *      inventing a second protocol).
 *   2. stdout is the protocol channel. Anything that is not a protocol line goes to stderr, which is
 *      why the plugin is handed a logger that writes there: `ctx.logger ?? console` in lib/index.js
 *      would otherwise print a warning INTO the JSON stream and break every client reading it.
 *   3. The transport never dies on bad input: a non-JSON line gets a -32700 with a null id, an unknown
 *      method gets -32601, and a notification (no id) gets no reply at all -- answering a notification
 *      makes a client wait for a response it never asked for.
 *   4. Settings come from the ENVIRONMENT, never from the call. A client that could raise its own
 *     `policy` ceiling or add itself to `appLaunchAllow` would make the authorization model decorative;
 *      the process owner configures this server exactly the way a DSH profile configures the plugin.
 */
import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { apply } from './index.js';
import { POLICY_LEVELS } from './policy.js';

const here = dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(readFileSync(join(here, '..', 'package.json'), 'utf8'));

/**
 * Protocol revisions this server is willing to speak, newest first. Verified against the constants of
 * the MCP SDK this machine's DSH install ships (@modelcontextprotocol/core 2.2.0: latest 2025-11-25,
 * supported back through 2025-06-18). The list is ours on purpose -- a zero-dependency server cannot
 * read the client's table at run time -- which is exactly why the negotiation below answers with the
 * newest entry we know rather than echoing anything it is handed.
 */
const PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const SERVER_NAME = 'wpm-mcp';
/** The single tool name. One tool with an action discriminator, in this form too: the token argument
 * from 0.5.0 does not weaken over a transport, and `tools/call` accepts an arbitrary argument object. */
const MCP_TOOL_NAME = 'wpm';

const log = (/** @type {any[]} */ ...a) => process.stderr.write(a.map((x) => String(x)).join(' ') + '\n');

// ---- the contract, read once ------------------------------------------------------------
/**
 * The shape this file reads out of src/schema/tools.json -- and deliberately only the parts it reads.
 * It is not a second description of the contract: nothing here names an action, a parameter or a code.
 * @typedef {Object} ContractAction
 * @property {string} name
 * @property {string} action
 * @property {string} requiresTier
 * @property {Record<string, string>} [requiresTierFor]
 * @property {string} description
 * @property {ContractSchema} inputSchema
 * @property {Array<{code: string}>} [refusals]
 *
 * @typedef {Object} ContractSchema
 * @property {Record<string, any>} [properties]
 * @property {string[]} [required]
 * @property {boolean} [additionalProperties]
 *
 * @typedef {Object} Contract
 * @property {Array<ContractAction>} tools
 * @property {Array<{code: string, layer?: string, summary: string}>} refusals
 * @property {string[]} notes
 * @property {{form?: string, tool?: string, bin?: string, entry?: string, discriminator?: string, schemaSource?: string, implementationSource?: string, settingsSource?: string, imageContent?: string, transportDiscipline?: string, reversal?: string, why?: string}} [mcpProjection]
 * @property {Record<string, Record<string, string>>} [hostProjection]
 */
/**
 * Parsed from src/schema/tools.json at start-up. This is the only copy of the action surface in the
 * process: if a field is renamed there, `tools/list` follows it, because nothing below spells out an
 * action name, a parameter name, or a refusal code. scripts/check-mcp-schema.mjs is the gate that
 * keeps that claim true (and has been seen red on a mutated schema).
 */
/** @type {Contract} */
const schema = JSON.parse(readFileSync(join(here, '..', 'src', 'schema', 'tools.json'), 'utf8'));

/** First sentence of a description -- the contract file writes those as one paragraph per action. */
const lead = (/** @type {string} */ s) => String(s).split(/(?<=\.)\s/)[0] || String(s);

/** @returns {Record<string, any>} */
function buildInputSchema() {
  /** @type {Array<Record<string, any>>} */
  const branches = schema.tools.map((t) => ({
    type: 'object',
    description: `${t.name}: ${t.description}`,
    properties: {
      action: { const: t.action, description: `${t.action} -- requires the '${t.requiresTier}' rung of the policy ladder.` },
      ...t.inputSchema.properties,
    },
    required: ['action', ...(t.inputSchema.required ?? [])],
    additionalProperties: t.inputSchema.additionalProperties === true,
  }));
  return {
    type: 'object',
    properties: {
      action: { type: 'string', enum: schema.tools.map((t) => t.action), description: 'Which of the declared actions to run. Each action carries its own required arguments; the branches below are generated from src/schema/tools.json.' },
    },
    required: ['action'],
    oneOf: branches,
  };
}

/** @returns {string} */
function buildDescription() {
  const lines = [
    `Drive one Windows window through ${schema.tools.length} declared actions, choosing the cheapest door that can reach the target and reporting what actually happened rather than what was sent.`,
    'ACTIONS (name | policy rung | what it does):',
    ...schema.tools.map((t) => `  - action=${t.action} | ${t.requiresTier}${t.requiresTierFor ? ` (per op: ${Object.entries(t.requiresTierFor).map(([k, v]) => `${k}=${v}`).join(', ')})` : ''} | ${lead(t.description)}`),
    'REFUSAL CODES (the refusal names which switch or which fact, so the next step is not guesswork):',
    ...schema.refusals.map((r) => `  - ${r.code}: ${r.summary}`),
    `Authorization is one ceiling (\`policy\`: ${POLICY_LEVELS.join('|')}) over the rungs above, and it is set by whoever starts this process, never by a call.`,
    'Every action -- allowed or refused -- appends one JSONL row to the audit log, which records decisions and lengths and never the content of what was typed or copied.',
    ...schema.notes.map((n) => `NOTE: ${n}`),
  ];
  return lines.join('\n');
}

const mcpTool = {
  name: MCP_TOOL_NAME,
  title: 'Windows Parallel',
  description: buildDescription(),
  inputSchema: buildInputSchema(),
};

// ---- the tool, from the same apply() the DSH form uses ----------------------------------
/**
 * `apply(ctx, config)` is the whole host half. It expects `ctx.tools.register`, an optional logger and
 * an optional `on('dispose')`. Under MCP there is no host to dispose us, so the stdin close handler
 * calls the registered disposers itself -- otherwise the resident PowerShell worker outlives the server.
 */
/** @type {Array<{execute: (args: any, exec?: any) => Promise<any>}>} */
const registered = [];
/** @type {Array<() => any>} */
const disposers = [];
apply({
  tools: { register: (t) => registered.push(t) },
  // stderr, always: stdout carries the protocol and one stray console.log would corrupt it.
  logger: { info: (m) => log('[info]', m), warn: (m) => log('[warn]', m) },
  on: (event, fn) => { if (event === 'dispose') disposers.push(fn); },
}, settingsFromEnv());
if (registered.length !== 1) throw new Error(`expected exactly one registered tool, got ${registered.length}`);
const tool = registered[0];

/**
 * Environment to plugin settings, mapping ONLY the keys that are actually present. Defaults live in
 * lib/index.js and are not repeated here: a second copy of a default is a default that drifts.
 * @returns {Record<string, any>}
 */
function settingsFromEnv() {
  /** @type {Record<string, [name: string, kind: 'bool'|'int'|'str'|'list']>} */
  const MAP = {
    WPM_ENABLED: ['enabled', 'bool'],
    WPM_SETTLE_MS: ['settleMs', 'int'],
    WPM_REQUEST_TIMEOUT_MS: ['requestTimeoutMs', 'int'],
    WPM_POWERSHELL_PATH: ['powershellPath', 'str'],
    WPM_OVERLAY: ['overlay', 'bool'],
    WPM_LOG_WORKER_STDERR: ['logWorkerStderr', 'bool'],
    WPM_TAKEOVER_ALLOWED: ['takeoverAllowed', 'bool'],
    WPM_KEY_INJECT_ALLOWED: ['keyInjectAllowed', 'bool'],
    WPM_TAKEOVER_MAX_MS: ['takeoverMaxMs', 'int'],
    WPM_TAKEOVER_ARM_MS: ['takeoverArmMs', 'int'],
    WPM_SNAPSHOT_MAX_ELEMENTS: ['snapshotMaxElements', 'int'],
    WPM_SCREENSHOT_MAX_WIDTH: ['screenshotMaxWidth', 'int'],
    WPM_SHOTS_KEEP: ['shotsKeep', 'int'],
    WPM_POLICY: ['policy', 'str'],
    WPM_POLICY_IDLE_MS: ['policyIdleMs', 'int'],
    WPM_AUDIT_KEEP: ['auditKeep', 'int'],
    WPM_APP_LAUNCH_ALLOWED: ['appLaunchAllowed', 'bool'],
    WPM_APP_LAUNCH_ALLOW: ['appLaunchAllow', 'list'],
  };
  /** @type {Record<string, any>} */
  const out = {};
  for (const [envName, [key, kind]] of Object.entries(MAP)) {
    const raw = process.env[envName];
    if (raw === undefined) continue;
    if (kind === 'bool') out[key] = /^(1|true|yes|on)$/i.test(raw.trim());
    else if (kind === 'int') out[key] = Number.parseInt(raw, 10);
    else if (kind === 'list') out[key] = raw.split(',').map((s) => s.trim()).filter(Boolean);
    else out[key] = raw;
  }
  return out;
}

// ---- JSON-RPC 2.0 over stdio ------------------------------------------------------------
/** @type {Map<string, AbortController>} */
const aborts = new Map();
let callSeq = 0;

/** @param {Record<string, any>} msg @returns {void} */
function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}
/** @param {string|number|null} id @param {any} result @returns {void} */
const reply = (id, result) => send({ jsonrpc: '2.0', id, result });
/** @param {string|number|null} id @param {number} code @param {string} message @param {string} [data] @returns {void} */
const fail = (id, code, message, data) => send({ jsonrpc: '2.0', id, error: { code, message, ...(data ? { data } : {}) } });

/** @param {string|number} id @param {Record<string, any>|undefined} params @returns {void} */
function onInitialize(id, params) {
  const asked = String(params?.protocolVersion ?? '');
  // Echo what the client asked for when we speak it; otherwise answer with the newest version we do
  // speak. Declining to echo an unknown version is how a client learns to negotiate instead of
  // assuming the server silently understood it.
  reply(id, {
    protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
    capabilities: { tools: { listChanged: false } },
    serverInfo: { name: SERVER_NAME, title: 'Windows Parallel (wpm)', version: pkg.version },
    instructions: 'Start with action=windows to enumerate targets, action=snapshot to read an element frame, or action=status to see what currently holds the foreground. Refusals are data: read the code, then change the setting or the facts it names -- do not retry the same call.',
  });
}

/** @param {string|number} id @returns {void} */
function onToolsList(id) {
  reply(id, { tools: [mcpTool] });
}

/** A picture is a file path here because the DSH form renders that file. Over stdio a path means
 * nothing to the caller, so the PNG is attached as base64 as well -- WPM_MCP_NO_IMAGE=1 opts out for
 * a client that only reads the numbers. */
/** @param {any} r @returns {Array<Record<string, any>>} */
function contentBlocks(r) {
  /** @type {Array<Record<string, any>>} */
  const blocks = [{ type: 'text', text: String(r?.text ?? '') }];
  if (process.env.WPM_MCP_NO_IMAGE === '1') return blocks;
  const file = r?.file;
  if (typeof file === 'string' && /\.(png|jpe?g)$/i.test(file) && r?.refusal !== 'stale_ref') {
    try {
      const buf = readFileSync(file);
      blocks.push({ type: 'image', data: buf.toString('base64'), mimeType: /\.jpe?g$/i.test(file) ? 'image/jpeg' : 'image/png' });
    } catch (err) {
      // The text already told the caller the file was produced; a read failure is the transport's
      // problem, so it is said on stderr and never dressed up as an engine refusal.
      log('[warn] the picture could not be attached:', String(err));
      blocks.push({ type: 'text', text: `image-note=the engine wrote ${file} but this server could not read it back` });
    }
  }
  return blocks;
}

/** @param {string|number} id @param {Record<string, any>|undefined} params @returns {Promise<void>} */
async function onToolsCall(id, params) {
  const name = params?.name;
  if (name !== MCP_TOOL_NAME) {
    return fail(id, -32602, `unknown tool '${String(name)}' -- this server exposes exactly one tool: ${MCP_TOOL_NAME}`);
  }
  const args = params?.arguments ?? {};
  const callId = `${++callSeq}`;
  const ac = new AbortController();
  aborts.set(callId, ac);
  try {
    const r = await tool.execute(args, { signal: ac.signal });
    // isError mirrors the engine's own answer. A refusal is NOT a transport failure and the code
    // stays verbatim in the text block: this file must not soften, renumber or re-explain a refusal,
    // because the whole vocabulary was built so the caller can branch on the code.
    reply(id, {
      content: contentBlocks(r),
      structuredContent: r,
      isError: r?.ok !== true,
    });
  } catch (err) {
    /** @type {any} */
    const e = err;
    // Two kinds of thrown answer reach here, and neither is an internal error:
    //   * `refusal(code, reason)` -- the vocabulary the engine uses when the CALL is not executable;
    //   * `ToolArgsError` -- argument validation from the tool definition (`action` outside the declared
    //     set, a missing required argument). Both are the caller's, so they come back as a tool-level
    //     error whose text starts with the code or names the argument. Answering -32603 instead would
    //     tell a client its own request was a server fault, which is the kind of misattribution this
    //     project refuses on every other surface.
    const code = typeof e?.code === 'string' ? e.code : '';
    const argsError = e?.name === 'ToolArgsError';
    if (code || argsError) {
      const head = code ? `${code}: ` : '';
      reply(id, { content: [{ type: 'text', text: `${head}${String(e.message ?? e)}` }], isError: true });
      return;
    }
    fail(id, -32603, `wpm-mcp internal error: ${String(e?.message ?? e)}`);
  } finally {
    aborts.delete(callId);
  }
}

/** @param {any} msg @returns {Promise<void>} */
async function handle(msg) {
  if (msg === null || typeof msg !== 'object' || msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') {
    // A line that is JSON but not a request. Answering with -32600 keeps the client from timing out on
    // a message it believed was sent; a notification never gets here because `method` exists.
    if (msg && msg.id !== undefined) { fail(msg.id, -32600, 'not a JSON-RPC 2.0 request'); return; }
    log('[warn] ignored a non-request line:', JSON.stringify(msg).slice(0, 120));
    return;
  }
  const { id, method, params } = msg;
  const isNotification = id === undefined || id === null;
  if (method === 'notifications/cancelled') {
    const target = String(params?.requestId ?? '');
    const ac = aborts.get(target);
    if (ac) ac.abort();
    return;
  }
  if (isNotification) return; // initialized, cancelled-progress, roots/list_changed ...: silent by protocol
  switch (method) {
    case 'initialize': return onInitialize(id, params);
    case 'ping': return reply(id, {});
    case 'tools/list': return onToolsList(id);
    case 'tools/call': return await onToolsCall(id, params);
    default:
      return fail(id, -32601, `Method not found: ${method} (this server implements initialize, ping, tools/list, tools/call)`);
  }
}

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let msg;
  try {
    msg = JSON.parse(trimmed);
  } catch {
    // The one case where a reply is sent with id null: JSON-RPC cannot know whom to answer, and the
    // alternative -- killing the transport over a stray keystroke on stdin -- would let a single
    // malformed line end the whole server.
    fail(null, -32700, 'Parse error: the line was not JSON');
    return;
  }
  handle(msg).catch((err) => log('[error] handler threw:', String((/** @type {any} */ (err))?.stack ?? err)));
});

/** @param {string} reason @returns {Promise<void>} */
const shutdown = async (reason) => {
  log(`[info] shutting down (${reason})`);
  for (const ac of aborts.values()) ac.abort();
  aborts.clear();
  for (const fn of disposers) {
    try { await fn(); } catch (err) { log('[warn] a disposer threw:', String(err)); }
  }
  process.exit(0);
};
rl.on('close', () => { void shutdown('stdin closed'); });
process.stdin.on('error', () => { void shutdown('stdin error'); });
