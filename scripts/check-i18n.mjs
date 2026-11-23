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

if (fail.length) {
  console.log('FAIL ' + fail.length + ' i18n issue(s):');
  for (const m of fail.slice(0,30)) console.log('  - ' + m);
  process.exit(1);
}
console.log('PASS i18n: 10 languages x 3 docs, language bars, two-case install, CHANGELOG headings consistent (' + enHeads + ' headings)');
