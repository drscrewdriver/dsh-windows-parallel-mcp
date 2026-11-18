// check-ps-calls.mjs — find PowerShell statements that call a .NET static member with the
// brackets missing, i.e. `CHW::ByKind($h)` where PowerShell requires `[CHW]::ByKind($h)`.
//
// WHY A SCRIPT AND NOT ATTENTION. This exact mistake appeared five separate times across four
// files in one session, and the PowerShell parser does NOT catch it: `Foo::Bar` is a perfectly
// legal command name syntactically, so the file parses green and then dies at runtime with
// CommandNotFoundException -- usually after minutes of window setup, which is the expensive
// part. check.mjs runs the real parser; the parser is structurally blind to this class, so a
// second check with different eyes is the only fix that does not depend on remembering.
//
// WHAT IT FLAGS: `Ident::Name` not preceded by `[`. That covers both failure shapes seen in
// practice -- `XMSG::Edits(...)` (runtime command-not-found) and `$x.GetType().Name` style
// chains, which are method CALLS on a variable and are legitimate -- so variable receivers
// (`$`, `)`, backtick and member chains already inside brackets) are excluded.
//
// WHAT IT CANNOT KNOW: a static call inside a double-quoted string that is meant to be text
// ("see [CM]::Fg()") will be flagged only if written WITHOUT brackets, which is also the
// mistake. There is no known false-positive class in this repo; if one appears, whitelist by
// fixing the prose rather than weakening the check.
import { readdirSync, statSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const roots = process.argv.slice(2).filter((r) => r.length);
const files = [];
const walk = (d) => {
  let ents; try { ents = readdirSync(d); } catch { return; }
  for (const e of ents) {
    const p = join(d, e);
    let st; try { st = statSync(p); } catch { continue; }
    if (st.isDirectory()) walk(p);
    else if (e.endsWith('.ps1')) files.push(p);
  }
};
roots.forEach(walk);

// `Ident::Member` where Ident is not `[Ident]`. The lookbehind rejects `[` (correct form) and
// `$`/alphanumeric/`.` (instance member access, which is legal PowerShell).
const BAD = /(?<![\[\w.$])([A-Za-z][A-Za-z0-9_]*)::([A-Za-z_][A-Za-z0-9_]*)/g;
let bad = 0;
for (const f of files) {
  const lines = readFileSync(f, 'utf8').replace(/^/, '').split(/\r?\n/);
  const hits = [];
  lines.forEach((line, i) => {
    // A C# block inside Add-Type is real C#, where Type::Member never appears but
    // Type.Method does; the pattern above cannot fire on valid C#, so no carve-out needed
    // beyond skipping pure-comment prose lines that describe the mistake itself.
    if (/^\s*#/.test(line)) return;
    let m;
    BAD.lastIndex = 0;
    while ((m = BAD.exec(line))) hits.push({ ln: i + 1, text: m[0], line: line.trim() });
  });
  if (hits.length) {
    bad++;
    console.log(`FAIL ${f}`);
    for (const h of hits.slice(0, 6)) console.log(`   L${h.ln}  ${h.text}   |${h.line.slice(0, 76)}|`);
  }
}
console.log(`${files.length} .ps1 file(s) scanned for bare static calls, ${bad} with hits`);
process.exit(bad ? 1 : 0);
