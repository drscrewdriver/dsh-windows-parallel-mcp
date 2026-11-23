// Type declarations for dsh-windows-parallel-mcp (public API surface).
// Mirrors lib/index.js + lib/host-tools.js + src/schema/tools.json (v0.7.0).

export type WpmAction =
  | 'windows' | 'click' | 'type' | 'focus' | 'status'
  | 'snapshot' | 'screenshot' | 'preview'
  // 0.7.0: three desktop actions. They are gated by SETTINGS, not by the target's doors -- which is why
  // they take no channel, cost no tier of their own, and produce no proof window.
  | 'launch' | 'clipboard' | 'window';

/** clipboard's `op`. */
export type WpmClipboardOp = 'read' | 'write';
/** window's `op`. There is no 'all windows' value, and that is the contract, not an omission. */
export type WpmWindowOp = 'minimize' | 'restore' | 'move' | 'resize' | 'topmost';

/** The single authorization ceiling in settings; lib/policy.js holds the ladder it is read against. */
export type WpmPolicy = 'readonly' | 'quiet' | 'balanced' | 'full';

/**
 * WHO REPORTED THE SUCCESS. The first three name a messenger, not a degree of confidence (see the
 * `effect` block in lib/index.js). `readback-verified` is the fourth and the only one that is about the
 * application rather than about the call: the value was read back after the settle window and equals
 * what the control's own measurements predicted. A masked field never reaches it (readback=unavailable)
 * and a reformatted value never reaches it (readbackMismatch=true) -- the engine does not upgrade on
 * "the call came back".
 */
export type WpmEffect =
  | 'unverified' | 'reported-by-send' | 'reported-by-pattern' | 'readback-verified';

/** Where the caret sits before the message door types. `idle` touches nothing. */
export type WpmCaretPosition = 'idle' | 'start' | 'end';

export type RefusalCode =
  | 'no_hwnd' | 'paused' | 'elevated_target' | 'unreachable'
  | 'uia_tree_empty' | 'uia_probe_failed' | 'terminal_no_door' | 'needs_facts'
  | 'takeover_unavailable' | 'keyinject_unavailable' | 'action_failed'
  | 'restore_failed' | 'takeover_aborted' | 'stale_ref'
  // 0.7.0. What separates these three from the fourteen above is the NEXT STEP: each names a SETTING,
  // so retrying the same call is the wrong response and changing the setting is the right one.
  | 'app_launch_denied' | 'policy_denied' | 'user_active';

export type KeyInputMode = 'none' | 'inject';

/** Coordinate space of a click's x/y. `image` means image pixels from a `screenshot`. */
export type WpmPointSpace = 'screen' | 'image';

/** Frame source of a captured screenRect. `dwm` is the DWM extended frame; `win32` is the fallback. */
export type WpmFrameSource = 'dwm' | 'win32';

/**
 * WHICH CAPTURE PATH produced a screenshot. `bitblt` is the cheap GDI path (measured 16-21ms against
 * 22-33ms for the other); `gdiplus` is `Graphics.CopyFromScreen`, either the explicit choice or the
 * fallback after BitBlt was refused. The two are measured equivalent on a still scene, but they are not
 * the same call and the field is never omitted -- a path that changed silently is the failure mode this
 * repo has already been caught by once with `frame`.
 */
export type WpmCaptureBackend = 'bitblt' | 'gdiplus';

export interface WpmWindow {
  hwnd: string; title: string; class: string; pid: number;
  rect: { left: number; top: number; right: number; bottom: number };
}

/** One numbered element in a `snapshot` frame. */
export interface WpmSnapshotElement {
  label: number;
  controlType: string;
  name: string;
  automationId: string;
  rect: { left: number; top: number; right: number; bottom: number };
  patterns: string[];
}

/** One delivered screenshot, with the mapping that makes its pixels addressable. */
export interface WpmShot {
  file: string;
  shotId: string;
  screenRect: { left: number; top: number; right: number; bottom: number };
  imageSize: { width: number; height: number };
  /** image pixels per screen pixel; 1 when identity. screen = rect + round(image / scale). */
  scale: number;
  identity: boolean;
  frame: WpmFrameSource;
  captureBackend?: WpmCaptureBackend;
  dpiAware: boolean;
}

export interface WpmArgs {
  action: WpmAction;
  hwnd?: string;
  x?: number;
  y?: number;
  text?: string;
  elementName?: string;
  replace?: boolean;
  caretPosition?: WpmCaretPosition;
  settleMs?: number;
  takeover?: boolean;
  takeoverMaxMs?: number;
  keyInput?: KeyInputMode;
  // ---- 0.5.0: snapshot / screenshot / preview / label addressing ----
  space?: WpmPointSpace;
  shotId?: string;
  label?: number;
  snapId?: string;
  maxElements?: number;
  interactableOnly?: boolean;
  sinceSnapId?: string;
  intent?: string;
  fullScreen?: boolean;
  maxWidth?: number;
  // ---- 0.7.0: launch / clipboard / window ----
  target?: string;
  args?: string;
  waitMs?: number;
  op?: WpmClipboardOp | WpmWindowOp;
  /** clipboard only: which format to read or write. */
  format?: 'text' | 'image';
  width?: number;
  height?: number;
  /** The caller's explicit override of the idle check; recorded in the audit log as `forced`. */
  forceUserActive?: boolean;
}

export interface WpmResult {
  text?: string;
  refusal?: RefusalCode;
  channel?: string;
  tier?: string;
  effect?: WpmEffect;
  proof?: 'pass' | 'fail' | 'inconclusive';
  focusTaken?: boolean;
  takeover?: 'on' | 'off';
  cursorMoved?: boolean;
  cursorRestored?: boolean;
  takeoverMs?: number;
  abortChord?: string;
  keysInjected?: boolean;
  injectedChars?: number;
  // ---- snapshot ----
  snapId?: string;
  elements?: WpmSnapshotElement[];
  count?: number;
  truncated?: boolean;
  frameCheck?: 'pass' | 'fail';
  intent?: string;
  // ---- screenshot ----
  shotId?: string;
  file?: string;
  screenRect?: { left: number; top: number; right: number; bottom: number };
  imageSize?: { width: number; height: number };
  scale?: number;
  identity?: boolean;
  frame?: WpmFrameSource;
  captureBackend?: WpmCaptureBackend;
  captureNote?: string;
  dpiAware?: boolean;
  // ---- preview ----
  preview?: { x: number; y: number; name: string; controlType: string; automationId: string };
  // ---- 0.7.0 desktop results ----
  pid?: number;
  processName?: string;
  waitedMs?: number;
  clipFormat?: 'text' | 'image';
  clipId?: string;
  resultChars?: number;
  [key: string]: unknown;
}

export interface WpmExec { signal?: AbortSignal; [key: string]: unknown; }

export interface WpmTool { execute(args: WpmArgs, exec?: WpmExec): Promise<WpmResult>; }

export const name: 'windows-parallel';
export const inject: readonly ['tools'];
export const Config: unknown;
export const configSource: string;
export const toolHelperSource: string;
export function apply(ctx: Record<string, unknown>, config?: Record<string, unknown>): void;

export const TOOL_NAME: 'wpm';
export const ACTIONS: readonly WpmAction[];
export const PARAMETERS: Record<string, { type: string; enum?: readonly string[]; required?: boolean; description: string }>;
export function parametersToJsonSchema(spec?: Record<string, unknown>): Record<string, unknown>;
export function validateArguments(schema: Record<string, unknown>, args: WpmArgs): boolean | string;
export function localDefineTool(options: Record<string, unknown>): WpmTool;
export function resolveDefineTool(): Promise<{ defineTool: (o: Record<string, unknown>) => WpmTool; source: string }>;
