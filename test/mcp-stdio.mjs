// test/mcp-stdio.mjs -- the 0.8.0 form, driven over the WIRE.
//
// Why a wire test and not a unit test: the thing 0.8.0 adds is a transport, and every failure mode of
// a transport is about bytes coming out of the process -- a stray console.log landing in the JSON
// stream, a notification answered with a reply the client never asked for, a malformed line killing
// the loop, a response that cannot be matched to its request. None of that is visible when the server
// is imported as a module.
//
// The criteria are the four from task_3's probe (initialize / tools/list / tools/call / -32601) plus
// the two that decide whether the shape is honest: the schema must be GENERATED (asserted against
// src/schema/tools.json field by field, from the transport side), and a refusal code must arrive
// verbatim in the text -- this file does not soften vocabulary.
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const schema = JSON.parse(readFileSync(join(root, 'src', 'schema', 'tools.json'), 'utf8'));
const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));

let pass = 0, fail = 0;
const problems = [];
const ok = (name, cond, detail = '') => {
  if (cond) pass++;
  else { fail++; problems.push(`${name} :: ${detail}`); }
  console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${name}${detail ? '  :: ' + detail : ''}`);
};

const child = spawn(process.execPath, [join(root, 'lib', 'mcp-server.mjs')], {
  stdio: ['pipe', 'pipe', 'pipe'],
  cwd: root,
});
let stderr = '';
child.stderr.on('data', (d) => { stderr += d.toString(); });

/** Every stdout line must be one JSON-RPC message. Anything else is transport corruption. */
let nonJsonLines = 0;
/** Messages whose id nobody was waiting on -- the parse-error reply (id null) lands here. */
const unkeyed = [];
const pending = new Map();
let buf = '';
child.stdout.on('data', (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const raw = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!raw) continue;
    let msg;
    try { msg = JSON.parse(raw); } catch { nonJsonLines++; continue; }
    const res = pending.get(msg.id);
    if (res) { pending.delete(msg.id); res(msg); }
    else unkeyed.push(msg);
  }
});

let seq = 0;
function request(method, params, { expectReply = true, timeoutMs = 30000 } = {}) {
  const id = `r${++seq}`;
  const line = JSON.stringify({ jsonrpc: '2.0', id: expectReply ? id : undefined, method, params });
  return new Promise((resolve, reject) => {
    if (!expectReply) { child.stdin.write(line + '\n'); return resolve(null); }
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`no reply to ${method} within ${timeoutMs}ms`)); }, timeoutMs);
    pending.set(id, (msg) => { clearTimeout(timer); resolve(msg); });
    child.stdin.write(line + '\n');
  });
}
/** The next raw line, whatever it is -- used to prove a notification produced NO reply. */
function nextLine(timeoutMs = 700) {
  return new Promise((resolve) => {
    const at = setTimeout(() => resolve(null), timeoutMs);
    const on = (d) => {
      const s = d.toString();
      const i = s.indexOf('\n');
      if (i < 0) return;
      clearTimeout(at); child.stdout.off('data', on);
      resolve(s.slice(0, i).trim());
    };
    child.stdout.on('data', on);
  });
}

try {
  // ---- 1. initialize ------------------------------------------------------------------
  const init = await request('initialize', {
    protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'wpm-wire-test', version: '0' },
  });
  ok('initialize replies', !!init.result, JSON.stringify(init).slice(0, 120));
  ok('it echoes a protocol version we both speak', init.result?.protocolVersion === '2025-06-18', String(init.result?.protocolVersion));
  ok('capabilities.tools exists', !!init.result?.capabilities?.tools);
  ok('serverInfo carries the package version', init.result?.serverInfo?.version === pkg.version,
    `serverInfo=${init.result?.serverInfo?.version} package.json=${pkg.version}`);
  const odd = await request('initialize', { protocolVersion: '1999-01-01', capabilities: {}, clientInfo: { name: 'x', version: '0' } });
  ok('an unknown protocol revision is answered with ours, not echoed', odd.result?.protocolVersion !== '1999-01-01',
    String(odd.result?.protocolVersion));

  await request('notifications/initialized', {}, { expectReply: false });

  // ---- 2. tools/list, and the claim that it is GENERATED ------------------------------
  const list = await request('tools/list', {});
  const tools = list.result?.tools;
  ok('tools/list result.tools is an array', Array.isArray(tools), `count=${tools?.length}`);
  ok('exactly ONE tool is exposed (the discriminator shape survives the transport)', tools?.length === 1, `count=${tools?.length}`);
  const t = tools?.[0] ?? {};
  ok('the tool is named wpm', t.name === 'wpm', t.name);
  ok('it has an inputSchema object', t.inputSchema && typeof t.inputSchema === 'object');
  const actions = schema.tools.map((x) => x.action).sort();
  ok('the action enum IS the contract file', JSON.stringify(t.inputSchema?.properties?.action?.enum?.slice().sort()) === JSON.stringify(actions),
    `wire=${JSON.stringify(t.inputSchema?.properties?.action?.enum?.slice().sort())} file=${JSON.stringify(actions)}`);
  const branches = t.inputSchema?.oneOf ?? [];
  ok('one branch per declared action', branches.length === schema.tools.length,
    `wire=${branches.length} file=${schema.tools.length}`);
  // Field-by-field: each branch must carry exactly the properties its tools.json entry declares.
  const mismatches = [];
  for (const entry of schema.tools) {
    const br = branches.find((b) => b.properties?.action?.const === entry.action);
    if (!br) { mismatches.push(`${entry.action}: no branch`); continue; }
    const want = Object.keys(entry.inputSchema.properties ?? {}).sort();
    const got = Object.keys(br.properties ?? {}).filter((k) => k !== 'action').sort();
    if (JSON.stringify(want) !== JSON.stringify(got)) mismatches.push(`${entry.action}: wire=${JSON.stringify(got)} file=${JSON.stringify(want)}`);
    const wr = [...(entry.inputSchema.required ?? [])].sort();
    const gr = (br.required ?? []).filter((k) => k !== 'action').sort();
    if (JSON.stringify(wr) !== JSON.stringify(gr)) mismatches.push(`${entry.action}: required wire=${JSON.stringify(gr)} file=${JSON.stringify(wr)}`);
    if (br.additionalProperties !== (entry.inputSchema.additionalProperties === true))
      mismatches.push(`${entry.action}: additionalProperties wire=${br.additionalProperties} file=${entry.inputSchema.additionalProperties === true}`);
  }
  ok('every branch matches its tools.json entry field by field', mismatches.length === 0, mismatches.join(' | '));
  const desc = String(t.description ?? '');
  const missingCodes = schema.refusals.map((r) => r.code).filter((c) => !desc.includes(c));
  ok('the description lists every refusal code in the contract', missingCodes.length === 0, `missing=${missingCodes.join(',')}`);
  const missingActions = schema.tools.map((x) => x.action).filter((a) => !desc.includes(`action=${a}`));
  ok('the description lists every action with its rung', missingActions.length === 0, `missing=${missingActions.join(',')}`);
  const missingTiers = schema.tools.filter((x) => !desc.includes(`| ${x.requiresTier}`));
  ok('no action is described without the tier it declares', missingTiers.length === 0,
    missingTiers.map((x) => x.action).join(','));

  // ---- 3. tools/call ------------------------------------------------------------------
  const st = await request('tools/call', { name: 'wpm', arguments: { action: 'status' } });
  ok('tools/call result.content is an array of blocks', Array.isArray(st.result?.content), JSON.stringify(st).slice(0, 100));
  ok('content[0] is a text block', st.result?.content?.[0]?.type === 'text' && typeof st.result.content[0].text === 'string',
    String(st.result?.content?.[0]?.text ?? '').split('\n')[0].slice(0, 80));
  ok('structuredContent mirrors the same object the DSH form returns', st.result?.structuredContent?.action === 'status',
    JSON.stringify(st.result?.structuredContent ?? {}).slice(0, 90));
  ok('a successful call is not marked isError', st.result?.isError === false, String(st.result?.isError));

  const win = await request('tools/call', { name: 'wpm', arguments: { action: 'windows' } });
  ok('action=windows answers over the transport', win.result?.isError === false,
    String(win.result?.content?.[0]?.text ?? '').split('\n')[0].slice(0, 80));

  // A refusal arrives as itself: the code is the first token of the text, unsoftened.
  const pol = await request('tools/call', { name: 'wpm', arguments: { action: 'click', hwnd: '1', x: 1, y: 1, takeover: true } });
  const polText = String(pol.result?.content?.[0]?.text ?? '');
  ok('a policy refusal keeps its code verbatim in the text', polText.startsWith('policy_denied'), polText.split('\n')[0].slice(0, 90));
  ok('a refused call says isError', pol.result?.isError === true, String(pol.result?.isError));
  const bad = await request('tools/call', { name: 'wpm', arguments: { action: 'not-an-action' } });
  const badText = String(bad.result?.content?.[0]?.text ?? '');
  ok('an invalid argument is the caller\'s error, not a -32603 server fault',
    !bad.error && bad.result?.isError === true && badText.includes('action'), JSON.stringify(bad).slice(0, 130));
  // And an action that passes validation but cannot be performed: the engine's own code has to arrive
  // unchanged, so a client can branch on it. Which code depends on the desktop, that it is a CONTRACT
  // code does not -- so the assertion is membership, not a guess about what is on screen.
  const eng = await request('tools/call', { name: 'wpm', arguments: { action: 'focus', hwnd: '1' } });
  const engText = String(eng.result?.content?.[0]?.text ?? '');
  const codes = schema.refusals.map((r) => r.code);
  const said = (engText.match(/^([a-z_]+):/) ?? [])[1];
  ok('an impossible action returns a refusal code from the contract, verbatim',
    !!said && codes.includes(said), `said=${said} text=${engText.split('\n')[0].slice(0, 70)}`);

  // The picture: the only thing the stdio form can do that the host form does not need to.
  const shot = await request('tools/call', { name: 'wpm', arguments: { action: 'screenshot', fullScreen: true } });
  const blocks = shot.result?.content ?? [];
  const img = blocks.find((b) => b.type === 'image');
  ok('a screenshot carries a text block AND an image block', blocks.length >= 2 && !!img,
    `blocks=${blocks.map((b) => b.type).join('+')} first=${String(blocks[0]?.text ?? '').split('\n')[0].slice(0, 70)}`);
  ok('the image block is base64 PNG', typeof img?.data === 'string'
    && Buffer.from(img.data.slice(0, 24), 'base64').subarray(0, 8)[1] === 0x50 /* 'P' */
    && img.mimeType === 'image/png', `mime=${img?.mimeType} bytes=${Math.ceil((img?.data?.length ?? 0) * 3 / 4)}`);

  const noName = await request('tools/call', { arguments: { action: 'status' } });
  ok('tools/call without a tool name is -32602', noName.error?.code === -32602, JSON.stringify(noName).slice(0, 110));
  const wrongName = await request('tools/call', { name: 'windows-mcp', arguments: { action: 'status' } });
  ok('an unknown tool name is -32602 and names the one tool', wrongName.error?.code === -32602
    && String(wrongName.error?.message).includes('wpm'), JSON.stringify(wrongName).slice(0, 120));

  // ---- 4. unknown method: an error, and the process survives -------------------------
  const um = await request('tools/nope', {});
  ok('an unknown method yields error not result', !!um.error && !um.result, JSON.stringify(um).slice(0, 110));
  ok('the code is -32601', um.error?.code === -32601, String(um.error?.code));
  const afterUm = await request('ping', {});
  ok('the server is alive after -32601', !!afterUm.result, JSON.stringify(afterUm));

  // ---- transport discipline -----------------------------------------------------------
  await request('notifications/initialized', {}, { expectReply: false });
  const silent = await nextLine();
  ok('a notification produces no reply line', silent === null, String(silent).slice(0, 80));

  child.stdin.write('the user typed this into the wrong terminal\n');
  const perr = await request('ping', {});
  ok('the server is alive after a non-JSON line', !!perr.result, JSON.stringify(perr).slice(0, 80));
  const parseErr = unkeyed.find((m) => m.error?.code === -32700);
  ok('a malformed line is answered with -32700 and a null id', !!parseErr && parseErr.id === null,
    JSON.stringify(parseErr ?? unkeyed).slice(0, 120));

  // ---- concurrency: two calls in flight, matched by id, not by order ------------------
  const [a, b] = await Promise.all([
    request('tools/call', { name: 'wpm', arguments: { action: 'windows' } }),
    request('tools/call', { name: 'wpm', arguments: { action: 'status' } }),
  ]);
  ok('two concurrent calls answer separately by id', a.id !== b.id && !!a.result && !!b.result, `${a.id}/${b.id}`);
  ok('the answers are not swapped', a.result.structuredContent.action === 'windows' && b.result.structuredContent.action === 'status',
    `${a.result.structuredContent.action}/${b.result.structuredContent.action}`);

  ok('NOT ONE stdout line was non-JSON (the protocol channel stayed clean)', nonJsonLines === 0, `nonJson=${nonJsonLines}`);
} catch (err) {
  ok('the wire test completed without throwing', false, err.message);
} finally {
  child.stdin.end();
  const code = await new Promise((r) => child.once('exit', r));
  ok('stdin close exits 0 (the worker is disposed, not orphaned)', code === 0, `code=${code}`);
}

console.log(`\nrefusal-code passthrough: see the two assertions above; generation proof: the field-by-field branch match.`);
console.log(`stderr tail: ${stderr.trim().split('\n').slice(-2).join(' / ').slice(0, 160)}`);
console.log(`\nmcp-stdio: ${pass} passed, ${fail} failed`);
if (problems.length) console.log(problems.map((p) => '  - ' + p).join('\n'));
process.exit(fail === 0 ? 0 : 1);
