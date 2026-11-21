// chromium-a11y-flag.mjs — does Chromium expose the page's own controls only under
// --force-renderer-accessibility?
//
// WHY THIS QUESTION. The window-level scan found 5 Edit elements in an Edge window, and
// every one of them was BROWSER UI (omnibox, search box, sidebar). Walking inside the page
// Document found exactly one element: the RootWebArea itself, read-only. The `<input>` the
// probe authored was simply not in the tree. That single observation decides the coverage
// verdict for the largest interactive family on this desktop, so it needs an explanation,
// not a number: either Chromium never exposes page content to UIA in this configuration
// (a hard reachability gap for the R2 claim), or it exposes it only once renderer
// accessibility is switched on -- which is a launch-time condition the engine cannot
// impose on a browser the user already has open.
//
// Method: two Edge windows on a THROWAWAY profile (never the user's), same data: URL, one
// launched with the flag and one without; the page subtree of each is counted by
// uia-page-subtree.ps1. The page input is identified by its value attribute so the count
// cannot be satisfied by browser chrome.
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { rmSync } from 'node:fs';

const PS = join(process.cwd(), 'scripts', 'uia-page-subtree.ps1');
const CLOSE_PS = join(process.cwd(), 'scripts', 'close-edge-profile.ps1');

// Each arm authors its own page title. Sharing one title across arms would let the second
// census read the first arm's window: EnumWindows returns Z-order, and "the window I just
// launched is on top" is an assumption, not a measurement. Distinct titles make every
// census unambiguous by construction, and the arm's flag is then the only difference.
function pageUrl(tag) {
  const page = 'WpmA11y' + tag;
  return {
    page,
    url: `data:text/html,<title>${page}</title><body><h3>a11y</h3><input id=k value=abc style="width:300px;font-size:22px"><button id=b>Press</button></body>`,
  };
}

function run(args) {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', ...args],
    { encoding: 'utf8', windowsHide: true });
  return (r.stdout || '') + (r.stderr || '');
}

function launch(profileDir, extraFlags, url) {
  const a = ['--new-window', '--no-first-run', `--user-data-dir=${profileDir}`, ...extraFlags, url];
  return run(['-Command', `Start-Process msedge -ArgumentList ${a.map((s) => `'${s.replace(/'/g, "''")}'`).join(',')}`]);
}

function census(tagArm, profileDir, flags) {
  const { page, url } = pageUrl(tagArm);
  const prof = join(tmpdir(), profileDir);
  rmSync(prof, { recursive: true, force: true });
  launch(prof, flags, url);
  // uia-page-subtree.ps1 does its own bounded wait for the window: a second, independent
  // timeout in the driver would be a second place for the same decision to be wrong.
  const out = run(['-File', PS, '-TitlePart', page, '-DocName', page, '-MaxScan', '4000', '-WaitSec', '30']);
  // Close what we launched, on the profile directory, so a later arm cannot read it and
  // the user is not left holding probe windows.
  run(['-File', CLOSE_PS, '-ProfileDir', prof]);
  const m = /in-document elements visited: (\d+)/.exec(out);
  const d = /documents found: (\d+)/.exec(out);
  const w = /=> the page IS reachable/.test(out);
  return {
    page,
    out,
    // Three distinct readings, because "0" and "absent" are not the same finding and the
    // verdict depends on which one happened:
    //   documents = 0 : no page Document node exists in the UIA tree at all
    //   docElements = 1 : the Document is there but has no children
    //   docElements > 1 : page content is exposed, and writableValue says whether any of it
    //                     can be written.
    documentsFound: d ? +d[1] : null,
    docElements: m ? +m[1] : null,
    writableValue: w,
    editElementPresent: /\bEdit\b/.test(out),
  };
}

const cases = [
  // Arm key is the exact difference between the arms, so the log itself states what is
  // being compared; the page title differs by arm too (see pageUrl).
  { tagArm: 'Plain', profile: 'wpm-a11y-plain', flags: [], label: 'A plain launch (no accessibility flag)' },
  { tagArm: 'Force', profile: 'wpm-a11y-force', flags: ['--force-renderer-accessibility'], label: 'B --force-renderer-accessibility' },
];

const results = [];
for (const c of cases) {
  console.error('--- ' + c.label);
  const r = census(c.tagArm, c.profile, c.flags);
  console.error(r.out.split('\n').slice(-18).join('\n'));
  results.push({ label: c.label, flags: c.flags, documentsFound: r.documentsFound, docElements: r.docElements, writableValue: r.writableValue, editElementPresent: r.editElementPresent });
}

console.log('\n===== COMPARISON =====');
for (const r of results) console.log(JSON.stringify(r));
const plain = results[0], forced = results[1];

// REVERSE ASSERTION -- MEASURED, AND THE REASON NO RETRY EXISTS ANYWHERE IN THE ENGINE.
// The arm comparison above leaves one alternative reading alive: "maybe the plain-launch tree is
// just SLOW" (Chromium's renderer accessibility is documented as demand-activated, and building
// it is asynchronous -- a first empty answer could legitimately be a pending one). That reading
// was tested, not assumed away: the same window was re-read IN PLACE three times (+0/+700/+1500ms)
// with the census's own counting (scripts/uia-tree-content.ps1, which also separates raw
// descendants from CONTENT elements -- raw alone lies, because an a11y-off Chromium window still
// exposes one Chrome_RenderWidgetHostHWND shell pane):
//   uTools  raw p1/p2/p3 = 0/0/0, content 0/0/0 -- the run the census published; one earlier
//           peek the same day read raw=1 (the shell pane surfacing) with content still 0/0/0;
//   DSH     first read = 1019 raw / 85 content (514 raw at census time, same day) -- an a11y-on
//           tree answers completely on the FIRST query, it does not trickle in.
// Three reads over 2.2 seconds produced zero content elements every time, two orders of magnitude
// below every a11y-on tree on the same desktop. That kills the lazy-activation reading for
// coverage purposes: an empty tree is not a tree that is slow, it is an application that has not
// enabled UI Automation, and nothing a client re-queries will change it. Consequences, stated so
// they cannot be softened later: (1) the engine must NOT re-query with a deadline -- there is
// nothing to wait for, and a poll built on a wrong premise reports its own artifact (the
// idle-baseline lesson, twice); (2) the refusal that names this world is `uia_tree_empty`
// (docs/refusals.md), distinct from `unreachable` (tree alive, nothing usable at that point);
// (3) the actual switch is launch-time -- --force-renderer-accessibility -- which the engine
// cannot impose on a browser the user already has open.

// The primary signal is documentsFound, not docElements. A plain launch returned
// "documents found: 0" -- there was NO page Document node to count children of -- and
// reading that as "0 children" would misdescribe the finding: the page is not exposed as
// an empty subtree, it is not exposed as a subtree at all. That distinction decides
// whether an engine could ever discover page controls in a browser the user already has
// open, so it is preserved in the verdict text instead of being flattened to a number.
if (plain.documentsFound === null || forced.documentsFound === null) {
  console.log('VERDICT: INCONCLUSIVE -- a census produced no readable parse (window never appeared, or the probe errored). Do not quote coverage from this run.');
} else if (plain.documentsFound === 0 && forced.documentsFound > 0) {
  console.log(`VERDICT: without the flag there is NO page Document node in the UIA tree at all (documents=0); with --force-renderer-accessibility the page appears (${forced.documentsFound} document(s), ${forced.docElements} in-document elements, writable=${forced.writableValue}). So Chromium page content is gated on a LAUNCH-TIME renderer-accessibility state that the engine cannot impose on a browser the user already opened: page controls are unreachable, while browser chrome (omnibox etc.) is reachable -- which is the opposite of what a "UIA reaches the browser" claim needs.`);
} else if (forced.docElements > plain.docElements) {
  console.log(`VERDICT: the flag increases exposed page content (${plain.docElements} -> ${forced.docElements} elements), and the page node exists either way. Reachability is still a launch-time condition of the target.`);
} else {
  console.log(`VERDICT: the flag changed nothing (documents ${plain.documentsFound} vs ${forced.documentsFound}, elements ${plain.docElements} vs ${forced.docElements}). Either this Edge build always/never exposes page content, or the probe cannot reach the renderer subtree -- a probe limitation to fix before any coverage number is quoted.`);
}
