// Type-level consumer smoke test. Compiled with tsc --noEmit by the Phase 2 gate.
import type {
  WpmAction, WpmArgs, WpmResult, WpmExec, WpmTool, RefusalCode, KeyInputMode, WpmWindow,
} from '../types/index.js';
import { name, ACTIONS, TOOL_NAME } from '../types/index.js';

const allActions: readonly WpmAction[] = ['windows', 'click', 'type', 'focus', 'status'];
const declared: readonly WpmAction[] = ACTIONS;
void allActions; void declared;

const listArgs: WpmArgs = { action: 'windows' };
const clickArgs: WpmArgs = { action: 'click', hwnd: '123', x: 40, y: 20, settleMs: 350 };
const typeArgs: WpmArgs = { action: 'type', hwnd: '123', text: 'hello', elementName: 'Edit', replace: true };
const focusArgs: WpmArgs = { action: 'focus', hwnd: '123', elementName: 'OK' };
const statusArgs: WpmArgs = { action: 'status' };
const takeoverArgs: WpmArgs = { action: 'click', hwnd: '123', x: 1, y: 2, takeover: true, takeoverMaxMs: 8000, keyInput: 'inject' };
void [listArgs, clickArgs, typeArgs, focusArgs, statusArgs, takeoverArgs];

const code: RefusalCode = 'takeover_aborted';
const mode: KeyInputMode = 'none';
const res: WpmResult = { refusal: code, tier: 'takeover', proof: 'pass', takeover: 'on', cursorRestored: true, injectedChars: 3, abortChord: 'Ctrl+Alt+X' };
void res; void mode;

const win: WpmWindow = { hwnd: '1', title: 't', class: 'c', pid: 42, rect: { left: 0, top: 0, right: 10, bottom: 10 } };
const exec: WpmExec = { signal: new AbortController().signal };
void win; void exec;

declare const tool: WpmTool;
async function use() {
  const a = await tool.execute(clickArgs);
  const b = await tool.execute(takeoverArgs, exec);
  return [a, b];
}
void use; void name; void TOOL_NAME;
