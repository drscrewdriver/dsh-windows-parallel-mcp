// check-i18n.mjs — the 10-language documentation gate.
// A translation that drifts from the canonical structure is worse than no translation: it links to a
// missing sibling, or teaches an install path that the plugin refuses. This gate checks STRUCTURE
// (files, language bar, install two-case wording, CHANGELOG headings) -- not prose fluency.
import { readFileSync, existsSync } from 'node:fs';

const LANGS = ['en','zh','ja','ko','fr','de','it','es','pt','ru'];
const BASES = ['README.md','CHANGELOG.md','INSTALL.md'];
const sibling = (base, lang) => base.replace(/\.md$/, lang === 'en' ? '.md' : '.' + lang + '.md');
const fail = [];
function need(cond, msg) { if (!cond) fail.push(msg); }

// 1. Every one of the 30 documents exists.
for (const base of BASES) {
  for (const lang of LANGS) need(existsSync(sibling(base, lang)), 'missing ' + sibling(base, lang));
}

// 2. Every document has a complete language bar (all 10 codes appear as links or bold).
for (const base of BASES) {
  for (const lang of LANGS) {
    const f = sibling(base, lang);
    if (!existsSync(f)) continue;
    const c = readFileSync(f, 'utf8');
    const head = c.split('\n').slice(0, 6).join(' ');
    need(head.includes('English') && head.includes('中文'), f + ': language bar missing English/中文');
    for (const [, label] of [['zh','中文'],['ja','日本語'],['ko','한국어'],['fr','Français'],['de','Deutsch'],['it','Italiano'],['es','Español'],['pt','Português'],['ru','Русский']]) {
      need(head.includes(label), f + ': language bar missing ' + label);
    }
  }
}

// 3. Every INSTALL carries the two-case split and the pnpm-cooling whitelist.
for (const lang of LANGS) {
  const f = sibling('INSTALL.md', lang);
  if (!existsSync(f)) continue;
  const c = readFileSync(f, 'utf8');
  need(c.includes('two cases, not three'), f + ': missing two-case split');
  need(c.includes('Do not use'), f + ': missing desktop dsh-plugin-add refusal');
  need(c.includes('pnpm'), f + ': missing pnpm-only desktop path');
  need(c.includes('minimumReleaseAgeExclude'), f + ': missing pnpm cooling whitelist');
  need(c.includes('dsh --profile'), f + ': missing non-desktop dsh add route');
}

// 4. CHANGELOG translations keep the en version-heading count.
const enHeads = (readFileSync('CHANGELOG.md','utf8').match(/^## /gm)||[]).length;
for (const lang of LANGS) {
  if (lang === 'en') continue;
  const f = sibling('CHANGELOG.md', lang);
  if (!existsSync(f)) continue;
  const n = (readFileSync(f,'utf8').match(/^## /gm)||[]).length;
  need(n === enHeads, f + ': CHANGELOG heading count ' + n + ' != en ' + enHeads);
}

// 5. The README's release line names the version that is actually in package.json.
//
// This is the check that would have caught the drift this whole section exists for. Until 0.4.0 the
// README opened with a "what's new in 0.2.0" block, and 0.3.0 shipped without touching it -- so the
// front page of a 0.3.0 package announced 0.2.0, and every gate stayed green because nothing was
// looking. A version string that a human must remember to bump is exactly the kind of promise this
// repo converts into a gate instead.
const pkgVersion = JSON.parse(readFileSync('package.json', 'utf8')).version;
const RELEASE_LINE = '> **Current release: ';
for (const lang of LANGS) {
  const f = sibling('README.md', lang);
  if (!existsSync(f)) continue;
  const c = readFileSync(f, 'utf8');
  const line = c.split('\n').find((l) => l.startsWith(RELEASE_LINE));
  need(Boolean(line), f + ': no "Current release" line at the top');
  if (!line) continue;
  const stated = line.slice(RELEASE_LINE.length).replace(/\*\*.*$/, '').trim();
  need(stated === pkgVersion, f + ': release line says ' + JSON.stringify(stated)
    + ' but package.json says ' + JSON.stringify(pkgVersion));
}

// 6. Every README carries a BYTE-IDENTICAL English body after its localized summary.
//
// The nine translated READMEs each open with a localized orientation paragraph, a note saying the
// English text below is authoritative, and then the English body itself -- the same body, verbatim.
// That identity is what makes the note true; it is also silently breakable, because a one-file edit
// to README.md leaves nine files claiming to reproduce a body they no longer match. Comparing them
// here costs nothing and is the only thing standing between "identical across all 10 languages" and
// a lie.
// The body is everything from the release line down. Anchoring on that one line is what makes the
// comparison possible at all: the English README has no localized summary above it, the translated
// ones do, and the note between them differs from file to file in nothing but its fixed wording.
const bodyOf = (text) => {
  const lines = text.split('\n');
  const i = lines.findIndex((l) => l.startsWith('> **Current release: '));
  return i < 0 ? '' : lines.slice(i).join('\n').trim();
};
const enBody = bodyOf(readFileSync('README.md', 'utf8'));
for (const lang of LANGS) {
  if (lang === 'en') continue;
  const f = sibling('README.md', lang);
  if (!existsSync(f)) continue;
  const c = readFileSync(f, 'utf8');
  need(c.includes('> **English canonical text follows.**'), f + ': missing the English-canonical note');
  const body = bodyOf(c);
  if (body === enBody) continue;
  // Report where, not just that: a 20 kB body diff is useless without the first divergent line.
  const a = body.split('\n'), b = enBody.split('\n');
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i += 1;
  need(false, f + ': English body differs from README.md at line ' + (i + 1)
    + '\n      ' + f + ': ' + JSON.stringify((a[i] ?? '<end>').slice(0, 90))
    + '\n      README.md: ' + JSON.stringify((b[i] ?? '<end>').slice(0, 90)));
}

if (fail.length) {
  console.log('FAIL ' + fail.length + ' i18n issue(s):');
  for (const m of fail.slice(0,30)) console.log('  - ' + m);
  process.exit(1);
}
console.log('PASS i18n: 10 languages x 3 docs, language bars, two-case install, CHANGELOG headings ('
  + enHeads + '), release line ' + pkgVersion + ', English body identical across 10 READMEs');
