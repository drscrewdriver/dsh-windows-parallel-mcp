// Type declarations for dsh-windows-parallel-mcp (public API surface).
// Mirrors lib/index.js + lib/host-tools.js + src/schema/tools.json (v0.5.0).

export type WpmAction =
  | 'windows' | 'click' | 'type' | 'focus' | 'status'
  | 'snapshot' | 'screenshot' | 'preview';

export type RefusalCode =
  | 'no_hwnd' | 'paused' | 'elevated_target' | 'unreachable'
  | 'uia_tree_empty' | 'uia_probe_failed' | 'terminal_no_door' | 'needs_facts'
  | 'takeover_unavailable' | 'keyinject_unavailable' | 'action_failed'
  | 'restore_failed' | 'takeover_aborted' | 'stale_ref';

export type KeyInputMode = 'none' | 'inject';

/** Coordinate space of a click's x/y. `image` means image pixels from a `screenshot`. */
export type WpmPointSpace = 'screen' | 'image';

/** Frame source of a captured screenRect. `dwm` is the DWM extended frame; `win32` is the fallback. */
export type WpmFrameSource = 'dwm' | 'win32';

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
}

export interface WpmResult {
  text?: string;
  refusal?: RefusalCode;
  channel?: string;
  tier?: string;
  effect?: string;
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
  dpiAware?: boolean;
  // ---- preview ----
  preview?: { x: number; y: number; name: string; controlType: string; automationId: string };
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
