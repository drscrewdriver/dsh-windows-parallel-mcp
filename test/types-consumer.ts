// Type-level consumer smoke test. Compiled with tsc --noEmit by the Phase 2 gate.
import type {
  WpmAction, WpmArgs, WpmResult, WpmExec, WpmTool, RefusalCode, KeyInputMode, WpmWindow,
  WpmSnapshotElement, WpmShot, WpmPointSpace, WpmFrameSource, WpmEffect, WpmCaretPosition,
  WpmCaptureBackend, WpmClipboardOp, WpmWindowOp, WpmPolicy,
} from '../types/index.js';
import { name, ACTIONS, TOOL_NAME } from '../types/index.js';

const allActions: readonly WpmAction[] = ['windows', 'click', 'type', 'focus', 'status', 'snapshot', 'screenshot', 'preview',
  'launch', 'clipboard', 'window'];
const declared: readonly WpmAction[] = ACTIONS;
void allActions; void declared;

const listArgs: WpmArgs = { action: 'windows' };
const clickArgs: WpmArgs = { action: 'click', hwnd: '123', x: 40, y: 20, settleMs: 350 };
const typeArgs: WpmArgs = { action: 'type', hwnd: '123', text: 'hello', elementName: 'Edit', replace: true };
const focusArgs: WpmArgs = { action: 'focus', hwnd: '123', elementName: 'OK' };
const statusArgs: WpmArgs = { action: 'status' };
const takeoverArgs: WpmArgs = { action: 'click', hwnd: '123', x: 1, y: 2, takeover: true, takeoverMaxMs: 8000, keyInput: 'inject' };
// 0.5.0 surface: the read paths and the two ways of naming a target.
const snapshotArgs: WpmArgs = { action: 'snapshot', hwnd: '123', maxElements: 300, interactableOnly: true, sinceSnapId: 'snap-1', intent: 'close the dialog' };
const screenshotArgs: WpmArgs = { action: 'screenshot', hwnd: '123', maxWidth: 960 };
const screenshotAllArgs: WpmArgs = { action: 'screenshot', fullScreen: true, maxWidth: 0 };
const previewArgs: WpmArgs = { action: 'preview', hwnd: '123', x: 700, y: 500 };
const imageClickArgs: WpmArgs = { action: 'click', hwnd: '123', x: 350, y: 250, space: 'image', shotId: 'shot-1' };
const labelClickArgs: WpmArgs = { action: 'click', hwnd: '123', x: 700, y: 500, label: 3, snapId: 'snap-1' };
// 0.6.0's caret request and the fourth `effect`, exercised by name: a declaration that drops either
// compiles the older lines happily, and the shipped contract would quietly be a subset of the real one.
const caretArgs: WpmArgs = { action: 'type', hwnd: '123', text: 'hi', caretPosition: 'end' };
const caret: WpmCaretPosition = 'start';
const effect: WpmEffect = 'readback-verified';
// 0.7.0's desktop surface: three actions, their ops, and the two settings-named refusal codes.
const launchArgs: WpmArgs = { action: 'launch', target: 'notepad', args: '-n', waitMs: 4000 };
const clipReadArgs: WpmArgs = { action: 'clipboard', op: 'read', format: 'text' };
const clipWriteArgs: WpmArgs = { action: 'clipboard', op: 'write', format: 'image', shotId: 'shot-1' };
const windowMoveArgs: WpmArgs = { action: 'window', hwnd: '123', op: 'move', x: 40, y: 60 };
const windowResizeArgs: WpmArgs = { action: 'window', hwnd: '123', op: 'resize', width: 800, height: 600 };
const forced: WpmArgs = { action: 'click', hwnd: '123', x: 1, y: 2, takeover: true, forceUserActive: true };
const clipOp: WpmClipboardOp = 'write';
const winOp: WpmWindowOp = 'topmost';
const policy: WpmPolicy = 'balanced';
const backend: WpmCaptureBackend = 'bitblt';
const code15: RefusalCode = 'app_launch_denied';
const code16: RefusalCode = 'policy_denied';
const code17: RefusalCode = 'user_active';
const desktopResult: WpmResult = { action: 'launch', ok: true, pid: 4242, hwnd: '', effect: 'unverified' };
const shotResult2: WpmResult = { shotId: 'shot-1', captureBackend: 'bitblt', captureNote: 'bitblt-unavailable(x)' };
void [listArgs, clickArgs, typeArgs, focusArgs, statusArgs, takeoverArgs,
  snapshotArgs, screenshotArgs, screenshotAllArgs, previewArgs, imageClickArgs, labelClickArgs,
  caretArgs, clipReadArgs, clipWriteArgs, windowMoveArgs, windowResizeArgs, launchArgs, forced,
  desktopResult, shotResult2];
void caret; void effect; void clipOp; void winOp; void policy; void backend;
void code15; void code16; void code17;

const code: RefusalCode = 'takeover_aborted';
const code2: RefusalCode = 'stale_ref';
const mode: KeyInputMode = 'none';
const space: WpmPointSpace = 'image';
const frame: WpmFrameSource = 'dwm';
const res: WpmResult = { refusal: code, tier: 'takeover', proof: 'pass', takeover: 'on', cursorRestored: true, injectedChars: 3, abortChord: 'Ctrl+Alt+X' };
void res; void mode; void code2; void space; void frame;

const win: WpmWindow = { hwnd: '1', title: 't', class: 'c', pid: 42, rect: { left: 0, top: 0, right: 10, bottom: 10 } };
const el: WpmSnapshotElement = {
  label: 1, controlType: 'Button', name: 'Bravo', automationId: 'bravo',
  rect: { left: 0, top: 0, right: 160, bottom: 40 }, patterns: ['invoke'],
};
const shot: WpmShot = {
  file: 'C:/x.png', shotId: 'shot-1',
  screenRect: { left: 0, top: 0, right: 1920, bottom: 1032 },
  imageSize: { width: 1920, height: 1032 },
  scale: 1, identity: true, frame: 'dwm', captureBackend: 'bitblt', dpiAware: true,
};
const snapResult: WpmResult = { snapId: 'snap-1', elements: [el], count: 1, truncated: false, frameCheck: 'pass', intent: 'x' };
const shotResult: WpmResult = {
  shotId: shot.shotId, file: shot.file, screenRect: shot.screenRect, imageSize: shot.imageSize,
  scale: shot.scale, identity: shot.identity, frame: shot.frame, dpiAware: shot.dpiAware,
};
const pvResult: WpmResult = { preview: { x: 1, y: 2, name: 'Bravo', controlType: 'Button', automationId: 'bravo' } };
void win; void el; void shot; void snapResult; void shotResult; void pvResult;

const exec: WpmExec = { signal: new AbortController().signal };
void exec;

declare const tool: WpmTool;
async function use() {
  const a = await tool.execute(clickArgs);
  const b = await tool.execute(takeoverArgs, exec);
  const c = await tool.execute(snapshotArgs);
  const d = await tool.execute(imageClickArgs);
  return [a, b, c, d];
}
void use; void name; void TOOL_NAME;
