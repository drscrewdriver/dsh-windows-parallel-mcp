// gen-i18n-skeleton.mjs — one-shot: derive 9 translated skeletons from the en canonical docs.
// Each translated file keeps the FULL en body (so no information is lost) and prepends a language
// bar plus a clear "translation pending" marker. Human refinement (tasks 10-18) replaces the body
// section by section; the gate checks structure, not prose.
import { readFileSync, writeFileSync } from 'node:fs';

const LANGS = [
  ['zh', '中文', 'README.zh.md'],
  ['ja', '日本語', 'README.ja.md'],
  ['ko', '한국어', 'README.ko.md'],
  ['fr', 'Français', 'README.fr.md'],
  ['de', 'Deutsch', 'README.de.md'],
  ['it', 'Italiano', 'README.it.md'],
  ['es', 'Español', 'README.es.md'],
  ['pt', 'Português', 'README.pt.md'],
  ['ru', 'Русский', 'README.ru.md'],
];
const BASE = ['README.md', 'CHANGELOG.md', 'INSTALL.md'];
// Derive the sibling name for a base doc in a target language.
const sibling = (base, lang) => base.replace(/\.md$/, '.' + lang + '.md');
// Language bar: English always first and linked when this is not the en doc; zh second and bolded
// when this is the zh doc; rest linked.
function bar(base, lang, label) {
  const self = sibling(base, lang);
  const link = (code, name, file) => code === lang
    ? '**' + name + '**'
    : '[' + name + '](' + file + ')';
  const en = link('en', 'English', base);
  const parts = [en];
  for (const [code, name] of LANGS) parts.push(link(code, name, sibling(base, code)));
  return parts.join(' · ');
}
function notice(lang, label) {
  return '> **' + label + ' translation — work in progress.** The English canonical text follows ' +
    'below; task-specific polishing replaces it section by section. The structure, code samples and ' +
    'numbers are already final — only the prose is pending. See the en document for the authoritative wording.\n';
}
for (const base of BASE) {
  const en = readFileSync(base, 'utf8');
  // Insert language bar right after the H1 line (and its following blank line).
  const nl = en.indexOf('\n');
  const afterH1 = en.slice(0, nl + 1);
  const rest = en.slice(nl + 1).replace(/^\r?\n/, '');
  for (const [lang, label] of LANGS) {
    const out = afterH1 + '\n' + bar(base, lang, label) + '\n\n' + notice(lang, label) + '\n' + rest;
    writeFileSync(sibling(base, lang), out);
  }
}
console.log('generated ' + (BASE.length * LANGS.length) + ' translated skeletons');
