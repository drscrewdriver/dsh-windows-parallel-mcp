// Type declarations for dsh-windows-parallel-mcp (public API surface).
// Mirrors lib/index.js + lib/host-tools.js + src/schema/tools.json (v0.2.0).

export type WpmAction = 'windows' | 'click' | 'type' | 'focus' | 'status';

export type RefusalCode =
  | 'no_hwnd' | 'paused' | 'elevated_target' | 'unreachable'
  | 'uia_tree_empty' | 'uia_probe_failed' | 'terminal_no_door' | 'needs_facts'
  | 'takeover_unavailable' | 'keyinject_unavailable' | 'action_failed'
  | 'restore_failed' | 'takeover_aborted';

export type KeyInputMode = 'none' | 'inject';

export interface WpmWindow {
  hwnd: string; title: string; class: string; pid: number;
  rect: { left: number; top: number; right: number; bottom: number };
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
