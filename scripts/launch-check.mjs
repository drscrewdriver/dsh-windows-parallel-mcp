#!/usr/bin/env node
// launch-check.mjs — one-shot diagnostic for why a background sampler produces no record.
// Prints the exact PowerShell command the probe builds, runs it with output captured,
// and reports the resulting pid, whether the pid is in the process list, and whether the
// record file appeared. Kept separate from proof-probe.mjs because the failure mode here
// (launcher exits, nothing written, no stderr) gives no evidence on its own.
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const ROOT = join(homedir(), '.dsh', 'windows-parallel-mcp');
const WORKER = process.env.WPM_WORKER || join(process.cwd(), 'scripts', 'probe-worker.ps1');
const out = join(ROOT, 'proof', 'diag.jsonl');
const STOP = join(ROOT, 'stop');

function q(s) { return "'" + String(s).replace(/'/g, "''") + "'"; }

const args = ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
  '-File', WORKER, '-Hz', '20', '-DurationMs', '3000', '-Out', out, '-StopFile', STOP];
const list = args.map(q).join(', ');
const cmd = `$p = Start-Process -FilePath powershell.exe -ArgumentList ${list}`
  + ` -WindowStyle Hidden -RedirectStandardOutput ${q(out + '.sout')} -RedirectStandardError ${q(out + '.err')} -PassThru;`
  + ` Write-Output ("PID=" + $p.Id); Start-Sleep -Seconds 4; Write-Output ("ALIVE=" + [bool](Get-Process -Id $p.Id -ErrorAction SilentlyContinue));`
  + ` Write-Output ("EXISTS=" + [bool](Test-Path -LiteralPath ${q(out)}));`
  + ` if (Test-Path -LiteralPath ${q(out)}) { Write-Output ("BYTES=" + (Get-Item -LiteralPath ${q(out)}).Length) }`;

console.log('CMD: ' + cmd.slice(0, 400) + (cmd.length > 400 ? ' ...' : ''));
const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', cmd], { encoding: 'utf8', windowsHide: true, timeout: 45000 });
console.log('launcher exit=', r.status);
console.log('launcher stdout=', (r.stdout || '').trim());
console.log('launcher stderr=', (r.stderr || '').trim().slice(0, 600));
if (existsSync(out)) console.log('record bytes=', statSync(out).size, 'first line=', readFileSync(out, 'utf8').split('\n')[0]);
if (existsSync(out + '.err')) console.log('sampler stderr=', readFileSync(out + '.err', 'utf8').trim().slice(0, 600));
