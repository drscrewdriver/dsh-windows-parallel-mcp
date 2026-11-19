// worker-smoke.mjs — drive the real PowerShell worker over the real protocol.
//
// WHY A PROCESS TEST AND NOT A MOCK. Three of the four things that can break the sidecar are
// invisible to a mock: whether the worker starts at all on this host, whether its JSON survives the
// trip unchanged (a stray Write-Output from Add-Type or an assembly load breaks the line protocol),
// whether a non-ASCII string survives GBK-configured stdio, and whether a malformed request still
// gets an answer instead of wedging the reader. Each has already cost a run somewhere in this
// ecosystem, and every one of them is one spawn away from being checked.
//
// It asserts BEHAVIOUR, never timing: the first call pays the PowerShell start, so a latency bound
// here would be measuring this machine's cold-start, not the product.
//
// Exit code 1 on any failed assertion.
import { WorkerClient, resolvePowerShell, workerScript } from '../lib/engine.js';

let pass = 0;
const failures = [];
function ok(name, condition, detail = '') {
  if (condition) { pass += 1; console.log(`  PASS  ${name}`); }
  else { failures.push(name); console.log(`  FAIL  ${name}${detail ? ` :: ${detail}` : ''}`); }
}

const script = workerScript();
console.log(`worker: ${script}`);
console.log(`powershell: ${resolvePowerShell()}`);

const client = new WorkerClient({ requestTimeoutMs: 60000 });
const startedAt = Date.now();

try {
  // ---- 1. the process comes up and answers ------------------------------------------------
  const ping = await client.request({ action: 'ping', text: '中文测试 ✓ 混合 ASCII' });
  ok('worker answers ping', ping.ok === true, JSON.stringify(ping).slice(0, 200));
  ok('ping carries a pid', typeof ping.result?.pid === 'number', String(ping.result?.pid));

  // ---- 2. non-ASCII survives the pipe in both directions -----------------------------------
  // The host's ANSI codepage is GBK; without explicit UTF-8 on both ends this comes back mojibake
  // and every window-title match silently fails. Comparing the exact string is the whole point.
  const sent = '中文测试 ✓ 混合 ASCII';
  ok('non-ASCII round-trips byte-identically', ping.result?.text === sent, `got=${JSON.stringify(ping.result?.text)}`);
  ok('length matches the .NET string length', ping.result?.len === sent.length, `len=${ping.result?.len} want=${sent.length}`);

  // ---- 3. a real query, not just an echo ---------------------------------------------------
  const st = await client.request({ action: 'status' });
  ok('status returns ok', st.ok === true, JSON.stringify(st).slice(0, 200));
  ok('status reports the pause flag', st.result?.paused === false, String(st.result?.paused));
  ok('status reports a stance', typeof st.result?.stance === 'string' && st.result.stance.length > 0, String(st.result?.stance));
  // foreground may legitimately be '0' (no window holds it), so the assertion is on presence, not value.
  ok('status carries a foreground field', 'foreground' in (st.result ?? {}), JSON.stringify(st.result ?? {}).slice(0, 160));

  const wins = await client.request({ action: 'windows' });
  ok('windows returns ok', wins.ok === true, JSON.stringify(wins).slice(0, 200));
  ok('windows returns an array', Array.isArray(wins.result?.windows), typeof wins.result?.windows);
  ok('windows count matches the array', wins.result?.count === wins.result?.windows?.length,
    `count=${wins.result?.count} len=${wins.result?.windows?.length}`);

  // ---- 4. a refusal is a normal answer, not a transport failure ----------------------------
  // Refusals come back as ok:true results carrying a code -- that separation is what lets the
  // tool layer distinguish "the engine said no" from "the engine is gone".
  const bad = await client.request({ action: 'click', hwnd: '1', x: 1, y: 1, settleMs: 0 });
  ok('dead hwnd is answered, not thrown', bad.ok === true, JSON.stringify(bad).slice(0, 200));
  ok('dead hwnd yields the no_hwnd code', bad.result?.refusal === 'no_hwnd', String(bad.result?.refusal));

  // ---- 5. unknown action is reported, and the worker stays alive ---------------------------
  const unknown = await client.request({ action: 'definitely-not-an-action' });
  ok('unknown action is refused by the worker', unknown.ok === false, JSON.stringify(unknown).slice(0, 160));
  const afterUnknown = await client.request({ action: 'ping' });
  ok('worker still answers after an unknown action', afterUnknown.ok === true);

  // ---- 6. the process is shared, not respawned per request --------------------------------
  ok('one worker served every request', afterUnknown.result?.pid === ping.result?.pid,
    `first=${ping.result?.pid} last=${afterUnknown.result?.pid}`);
  ok('no restart happened', client.restarts === 0, `restarts=${client.restarts}`);
} catch (err) {
  failures.push('uncaught');
  console.error(`  FAIL  uncaught: ${err?.stack ?? err}`);
} finally {
  await client.dispose();
}

console.log(`\nworker-smoke: ${pass} passed, ${failures.length} failed (${Date.now() - startedAt}ms)`);
if (failures.length) {
  console.log(`failed: ${failures.join(', ')}`);
  process.exit(1);
}
