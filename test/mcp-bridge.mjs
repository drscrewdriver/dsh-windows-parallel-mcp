// test/mcp-bridge.mjs -- task_47: the DSH bridge, driven by the bridge's own code.
//
// WHAT THIS PROVES AND WHAT IT DOES NOT. 0.8.0 claims one engine reachable two ways: the DSH plugin
// half (lib/index.js via apply()) and an MCP stdio server (lib/mcp-server.mjs). Two claims hide in that
// sentence. The first is that a real MCP client -- not my own test harness, but the SDK the DSH host
// ships -- will accept what our server says in `initialize` and `tools/list`; that SDK validates the
// shapes strictly, and a schema it dislikes fails the connection rather than warning. The second is
// that the bridge's OWN tool definition and executor still hand the model our result, including a
// refusal code and a coordinate mapping. So this file imports both from the DSH installation and uses
// them the way the host does.
//
// What it does NOT prove: that a booted DSH profile with this plugin configured shows the tool in a
// live session. That is the same code path plus Cordis's service graph; it needs a logged-in profile,
// and the mechanical part is what can be gated.
//
// Environment fact, named not faked: no DSH install on this machine => the suite says SKIP and exits 0,
// exactly like the tsc arms do when there is no compiler. A green that depends on a missing tool is a
// red that has not happened yet.
import { execSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');

let pass = 0, fail = 0;
const problems = [];
const ok = (name, cond, detail = '') => {
  if (cond) pass++;
  else { fail++; problems.push(`${name} :: ${detail}`); }
  console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${name}${detail ? '  :: ' + detail : ''}`);
};

/**
 * Where the DSH host keeps its own node_modules, on a machine that has one.
 * `npm` is a .cmd on Windows, so this goes through a shell -- the same reason scripts/check-pack.mjs
 * passes shell:true. Calling it with execFileSync silently throws ENOENT here, and a throw in a
 * locator reads as "not installed", which is how an environment probe becomes a permanent SKIP.
 */
function findDshTree() {
  let globals;
  try {
    globals = execSync('npm root -g', { encoding: 'utf8' }).trim();
  } catch { return null; }
  for (const base of [globals, process.env.DSH_NPM_ROOT].filter(Boolean)) {
    const mods = join(base, '@deepseek-ai', 'dsh', 'node_modules');
    const bridge = join(mods, '@deepseek-ai', 'dsh-mcp-client', 'lib', 'index.js');
    if (existsSync(bridge)) return { mods, bridge };
  }
  return null;
}

const tree = findDshTree();
if (!tree) {
  console.log('SKIP mcp-bridge: no @deepseek-ai/dsh install found (npm root -g). This arm tests the host');
  console.log('     bridge and cannot run without it -- an environment fact, not a regression.');
  process.exit(0);
}

const clientDir = join(tree.mods, '@modelcontextprotocol', 'client');
const require2 = createRequire(pathToFileURL(join(clientDir, 'package.json')));
const sdkMain = join(clientDir, require2('./package.json').exports['.'].import.default.replace(/^\.\//, ''));
const sdkStdio = join(clientDir, require2('./package.json').exports['./stdio'].import.default.replace(/^\.\//, ''));
for (const f of [sdkMain, sdkStdio, tree.bridge]) if (!existsSync(f)) {
  console.log(`FAIL mcp-bridge: expected module missing: ${f}`);
  process.exit(1);
}

const { Client } = await import(pathToFileURL(sdkMain).href);
const { StdioClientTransport } = await import(pathToFileURL(sdkStdio).href);
const { createMcpToolDefinition } = await import(pathToFileURL(tree.bridge).href);
ok('the host SDK and the bridge both load', true, `sdk=${require2('./package.json').version} bridge-tree=@deepseek-ai/dsh`);

const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const contract = JSON.parse(readFileSync(join(root, 'src', 'schema', 'tools.json'), 'utf8'));

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [join(root, 'lib', 'mcp-server.mjs')],
  env: { ...process.env },
  cwd: root,
});
const client = new Client({ name: 'wpm-bridge-test', version: '0' });
try {
  await client.connect(transport);
  // The SDK does not hand the initialize payload back to the caller; it keeps the peer identity on the
  // client (`getServerVersion()` / `getServerCapabilities()`), which is what a host reads. Asserted
  // through that API because it is the one the bridge itself uses.
  const version = client.getServerVersion();
  const caps = client.getServerCapabilities();
  ok('the real MCP SDK accepts our initialize answer (a version it does not speak would throw here)',
    !!caps?.tools && typeof caps.tools === 'object', `capabilities=${JSON.stringify(caps ?? null)}`);
  ok('it reports the package version, not a private one', version?.version === pkg.version && version?.name === 'wpm-mcp',
    `serverInfo.version=${version?.version} name=${version?.name} package.json=${pkg.version}`);

  const listed = await client.listTools();
  const tools = listed.tools ?? [];
  ok('the SDK accepts our tools/list shape and reports one tool', tools.length === 1, `count=${tools.length}`);
  const wire = tools[0];
  ok('the tool is named wpm', wire?.name === 'wpm', wire?.name);

  // The bridge's own definition, from the listed tool, exactly as the host would build it.
  const calls = [];
  const ctx = {
    // The bridge asks for services through get(); no attachment store and no llm route are mounted
    // here on purpose -- a screenshot must still deliver its NUMBERS when the host cannot take pixels.
    get: () => undefined,
    logger: { info: () => {}, warn: () => {} },
  };
  const def = createMcpToolDefinition(ctx, {
    name: `mcp__wpm__${wire.name}`,
    rawName: wire.name,
    description: wire.description,
    inputSchema: wire.inputSchema,
    call: async (args, exec) => {
      calls.push(args);
      return client.callTool({ name: wire.name, arguments: args }, undefined, { signal: exec?.signal });
    },
  });
  ok('the bridged tool is registered under the host naming scheme', def.name === 'mcp__wpm__wpm', def.name);
  ok('the bridged parameter schema survived the trip unchanged',
    JSON.stringify(def.parameters) === JSON.stringify(wire.inputSchema));
  const enum_ = def.parameters?.properties?.action?.enum ?? def.parameters?.oneOf?.[0]?.properties?.action?.enum ?? [];
  ok('the bridge still shows every contract action', enum_.length === 0
    ? JSON.stringify(def.parameters?.oneOf ?? []).length > 0 && contract.tools.every((t) => JSON.stringify(def.parameters).includes(`"${t.action}"`))
    : contract.tools.every((t) => enum_.includes(t.action)),
    `enum=${enum_.length}`);

  const st = await def.execute({ action: 'status' }, {});
  const stText = String(st?.content?.[0]?.text ?? '');
  ok('the bridge calls our tool and hands back the same text the DSH form returns',
    stText.includes('paused='), stText.split('\n')[0].slice(0, 80));
  ok('structuredContent survives the bridge', st?.structuredContent?.action === 'status',
    JSON.stringify(st?.structuredContent ?? {}).slice(0, 80));
  ok('the call reached the server, not a stub', calls.length === 1 && calls[0].action === 'status');

  // A refusal across the bridge. The bridge throws on isError and uses the text as the message, so the
  // CODE has to be legible in that message or the model loses the only thing it can branch on.
  let refused = '';
  try {
    await def.execute({ action: 'click', hwnd: '1', x: 1, y: 1, takeover: true }, {});
  } catch (e) { refused = String(e?.message ?? e); }
  ok('a policy refusal arrives through the bridge with its code intact', refused.startsWith('policy_denied'),
    refused.slice(0, 90));

  // A picture across a bridge with no attachment store: the image cannot be admitted, and the caller
  // must still get the mapping it needs to act. This is the arm that decides whether attaching image
  // content by default is safe for a client that cannot display it.
  const shot = await def.execute({ action: 'screenshot', fullScreen: true }, {});
  const blocks = shot?.content ?? [];
  const allText = blocks.map((b) => String(b.text ?? '')).join('\n');
  ok('a screenshot across the bridge does not throw when the host cannot take pixels',
    blocks.length >= 1 && !shot?.isError, `blocks=${blocks.map((b) => b.type).join('+')}`);
  ok('the coordinate mapping is still there', /screenRect=\d+,\d+,\d+,\d+/.test(allText) && /scale=/.test(allText),
    allText.split('\n')[0].slice(0, 80));
  ok('the refusal to show the picture is said out loud rather than silent',
    /image unavailable/i.test(allText) || blocks.some((b) => b.type === 'image'),
    allText.slice(0, 120).replace(/\n/g, ' / '));

  // BOTH forms at once: the native DSH half and the bridged MCP half, in the same process, against the
  // same engine. A parallel entry that replaces the original is the failure mode the plan forbids.
  const mod = await import(pathToFileURL(join(root, 'lib', 'index.js')).href);
  const reg = [];
  const disposers = [];
  mod.apply({ tools: { register: (t) => reg.push(t) }, logger: { info() {}, warn() {} }, on: (e, f) => { if (e === 'dispose') disposers.push(f); } }, {});
  const native = await reg[0].execute({ action: 'status' }, {});
  const viaBridge = await def.execute({ action: 'status' }, {});
  const nativeLine = String(native.text ?? '').split('\n')[0];
  const bridgeLine = String(viaBridge?.content?.[0]?.text ?? '').split('\n')[0];
  ok('the two forms answer the same call with the same first line', nativeLine === bridgeLine,
    `native="${nativeLine}" bridge="${bridgeLine}"`);
  ok('the native form still registers its own tool (unchanged, not replaced)',
    reg.length === 1 && reg[0].name === 'wpm' && typeof reg[0].execute === 'function', reg[0]?.name);
  for (const fn of disposers) { try { await fn(); } catch { /* dispose is best-effort here */ } }
} catch (e) {
  ok('the bridge end-to-end completed without throwing', false, String(e?.stack ?? e).split('\n').slice(0, 3).join(' | '));
} finally {
  try { await client.close(); } catch { /* already gone */ }
}

console.log(`\nmcp-bridge: ${pass} passed, ${fail} failed`);
if (problems.length) console.log(problems.map((p) => '  - ' + p).join('\n'));
process.exit(fail === 0 ? 0 : 1);
