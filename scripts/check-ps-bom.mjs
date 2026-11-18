// check-ps-bom.mjs — gate: every PowerShell script containing non-ASCII must be valid
// UTF-8 and carry a BOM, or PowerShell 5.1 will decode it with the ANSI codepage.
//
// WHY THIS IS A GATE AND NOT A NOTE. On this host the ANSI codepage is GBK. A .ps1 file
// written as UTF-8 without a BOM is read as GBK, so every non-ASCII literal turns into
// mojibake. Sometimes that is a syntax error, which is the lucky case. Usually it is
// silent: a safety vocabulary like "never click 关闭" becomes a set of strings no control
// will ever match, so the filter silently protects nothing while the experiment still
// reports clean numbers. That happened in this repo — the destructive-control filter was
// dead for an entire run series, and only the encoding fix made it live.
//
// The alternatives are worse: keeping every .ps1 pure ASCII would forbid the Chinese
// literals that MUST match localized control names, and "remember to add a BOM" is a rule
// nobody remembers. So the rule is checked, not remembered.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const roots = process.argv.slice(2).filter((a) => !a.startsWith('--'));
if (!roots.length) roots.push('scripts', 'src');

function walk(dir, out = []) {
  let ents;
  try { ents = readdirSync(dir); } catch { return out; }
  for (const e of ents) {
    const p = join(dir, e);
    let st; try { st = statSync(p); } catch { continue; }
    if (st.isDirectory()) walk(p, out);
    else if (e.endsWith('.ps1')) out.push(p);
  }
  return out;
}

const problems = [];
const checked = [];
for (const r of roots) for (const f of walk(r)) {
  const raw = readFileSync(f);
  checked.push(f);
  const bom = raw.length >= 3 && raw[0] === 0xef && raw[1] === 0xbb && raw[2] === 0xbf;
  const body = bom ? raw.subarray(3) : raw;
  // Buffer.toString('utf8') cannot detect bad bytes: it substitutes U+FFFD instead of
  // throwing, so a GBK-encoded file decodes to *something* and looks fine — the exact
  // silent failure this gate exists to catch. TextDecoder with fatal:true is the one API
  // that actually rejects invalid UTF-8.
  let text;
  try {
    text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(body);
  } catch {
    problems.push(f + '  (bytes are not valid UTF-8 -- probably written in the ANSI codepage)');
    continue;
  }
  if (/[^\x00-\x7F]/.test(text) && !bom) {
    problems.push(f + '  (non-ASCII literals with no BOM: PS 5.1 will read them as GBK)');
  }
}

if (problems.length) {
  console.error(`FAIL: ${problems.length} PowerShell script(s) need attention.\n`);
  for (const p of problems) console.error('  ' + p);
  console.error('\nWhy it matters: PS 5.1 decodes a BOM-less file with the ANSI codepage');
  console.error('(GBK here). Chinese literals become mojibake that silently matches');
  console.error('nothing, so a safety vocabulary stops protecting anything while the');
  console.error('experiment keeps reporting clean numbers. This repo hit exactly that.');
  console.error('\nfix: node scripts/add-ps-bom.mjs   (adds the BOM where it is missing)');
  process.exit(1);
}
console.log(`OK: ${checked.length} .ps1 file(s) checked; all valid UTF-8, every non-ASCII one carrying a BOM.`);
