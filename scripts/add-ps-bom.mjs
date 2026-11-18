// add-ps-bom.mjs — prepend a UTF-8 BOM to exactly the files check-ps-bom.mjs rejects.
//
// Kept separate from the checker on purpose: a gate that silently rewrites files is a
// gate nobody trusts, and the fix must be a deliberate act. See check-ps-bom.mjs for why
// a BOM-less non-ASCII .ps1 is dangerous on this host rather than merely ugly.
import { readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
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

const BOM = Buffer.from([0xef, 0xbb, 0xbf]);
let fixed = 0, skipped = 0;
for (const r of roots) for (const f of walk(r)) {
  const raw = readFileSync(f);
  const hasBom = raw.length >= 3 && raw[0] === 0xef && raw[1] === 0xbb && raw[2] === 0xbf;
  const body = hasBom ? raw.subarray(3) : raw;
  const nonAscii = /(^|[^\x00-\x7F])/m.test(body.toString('latin1')) && /[^\x00-\x7F]/.test(body.toString('utf8'));
  if (!nonAscii) { skipped++; continue; }
  if (hasBom) { skipped++; continue; }
  writeFileSync(f, Buffer.concat([BOM, body]));
  console.log('BOM added: ' + f);
  fixed++;
}
console.log(`fixed=${fixed} leftAlone=${skipped}`);
