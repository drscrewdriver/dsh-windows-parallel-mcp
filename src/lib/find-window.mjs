// find-window.mjs — locate a top-level window by title, through find-window.ps1.
//
// Why not Get-Process MainWindowTitle: for a process started with its console hidden,
// MainWindowHandle can resolve to the console (title reads empty) instead of the form.
// Enumerating real top-level windows is the only lookup that agrees with what the
// reachability matrix calls "the target window", so baseline and matrix share it.
//
// THE TRAP THAT COST A DEBUG CYCLE: a GUI process started with STARTUPINFO showing
// SW_HIDE -- which is what node's `windowsHide: true` and PowerShell's
// `-WindowStyle Hidden` both do -- starts its first form HIDDEN, so the window exists
// but never appears in EnumWindows. A launcher that then "waits for the window" times
// out and reports a launch failure, while the real cause is the launch flag. Targets
// must be spawned without windowsHide; use spawnHiddenTarget.mjs's helper if a console
// must stay out of the way.
import { spawnSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const FIND_WINDOW_PS = join(HERE, '..', '..', 'scripts', 'find-window.ps1');

export function findWindow(titlePart, { timeoutSec = 0 } = {}) {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', FIND_WINDOW_PS, '-TitlePart', titlePart, '-TimeoutSec', String(timeoutSec)],
    { encoding: 'utf8', windowsHide: true });
  const t = (r.stdout || '').trim().split('\n').pop();
  if (!t) return null;
  try { return JSON.parse(t); } catch { return null; }
}

export async function waitForWindow(titlePart, { timeoutMs = 20000, everyMs = 400 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const w = findWindow(titlePart);
    if (w) return w;
    await new Promise((r) => setTimeout(r, everyMs));
  }
  return null;
}

