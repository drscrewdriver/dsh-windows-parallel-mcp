#!/usr/bin/env python3
# rm9_stage_audit.py -- re-run the RM-9 `0.0.0-stage` audit against the live registry.
#
# WHY A SCRIPT AND NOT A PARAGRAPH. RM-9's conclusion (the stub is generated server-side by
# npm's staged-publish flow, not by some process on this machine holding publish credentials)
# is a claim about EXTERNAL state, and the release discipline in this ecosystem says registry
# conclusions must be refreshed on the spot before any release batch rather than cited from a
# snapshot. It also cost two wrong answers before it gave a right one, both traceable to the
# same two mistakes, so they are encoded here as guard rails rather than as prose:
#
#   1. Reading a missing field as a fact. An unauthenticated doc read returns maintainers as
#      null, and the first audit treated null as "not my package" and reported that 7 packages
#      carrying the stub belonged to OTHER maintainers -- all 7 were mine. So owner identity
#      here comes from the search index, which does return publisher, and an unreadable owner
#      is reported as UNKNOWN, never as NOT-MINE.
#   2. Timestamp arithmetic on the wrong type: passing the version label '0.0.1' where
#      times['0.0.1'] was wanted. parse() now takes the value, and callers pass times[v].
#
# THE TEST THAT ACTUALLY DECIDED IT is the second half: does the same stub string appear on
# packages by maintainers who have never touched this machine? If yes, no local process is
# implicated and no credential rotation is owed. Run with no arguments; exits non-zero only
# on a network failure, never on an unfavourable finding.
import json
import sys
import urllib.request
import urllib.parse
import datetime

STUB = "Temporary package placeholder for staged publishing"
OURS = [
    "dsh-windows-parallel-mcp", "dsh-windows-shadow-mcp", "dsh-windows-mcp-parallel",
    "dsh-windows-mcp-shadow", "windows-parallel-mcp", "parallel-windows-mcp",
    "dsh-superagent-governance",
]
ACCOUNT = "drscrewdriver"


def get(url):
    req = urllib.request.Request(url, headers={
        "Accept": "application/json", "User-Agent": "rm9-stage-audit"})
    with urllib.request.urlopen(req, timeout=45) as r:
        return json.loads(r.read().decode("utf-8"))


def ts(v, times):
    """Timestamp OF a version. Callers pass times[v], never v itself."""
    t = times.get(v)
    if not t:
        return None
    return datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))


print("=" * 100)
print("PART 1 - our own names: is the stub present, and does latest still serve a real version?")
print("=" * 100)
print(f"{'package':32} {'stub':6} {'stage->real':13} {'latest':26} {'latest is real?':15}")
worst = 0
for n in OURS:
    try:
        d = get("https://registry.npmjs.org/" + urllib.parse.quote(n, safe=""))
    except Exception as e:
        print(f"{n:32} FETCH-FAIL {type(e).__name__}: {str(e)[:40]}")
        worst = max(worst, 2)
        continue
    times = d.get("time") or {}
    versions = [v for v in times if v not in ("created", "modified")]
    stage = times.get("0.0.0-stage")
    reals = sorted([v for v in versions if v != "0.0.0-stage"], key=lambda v: ts(v, times))
    gap = ""
    if stage and reals:
        gap = f"{(ts(reals[0], times) - ts('0.0.0-stage', times)).total_seconds():+.0f}s"
    latest = (d.get("dist-tags") or {}).get("latest")
    # 'real' means: latest names a version whose tarball field exists AND is not the stub.
    served = latest if latest and latest != "0.0.0-stage" and latest in (d.get("versions") or {}) else None
    ok = "YES" if served else "NO  <-- V4 TRAP"
    if not served:
        worst = max(worst, 1)
    print(f"{n:32} {'YES' if stage else 'no':6} {gap:13} {str(latest):26} {ok:15}")

print("\n  The trap this checks is documented and real: dsh-purge (another account) shipped a")
print("  genuine 1.2.1 after its stub yet its latest STILL read 0.0.0-stage. A stub that owns")
print("  latest is a published placeholder serving as the installable version.")

print("\n" + "=" * 100)
print("PART 2 - the discriminating test: does anyone else's package carry the same stub?")
print("         If yes, it cannot be a process on this machine, and no token rotation is owed.")
print("=" * 100)
q = urllib.parse.quote(f'"{STUB}"', safe="")
try:
    res = get(f"https://registry.npmjs.org/-/v1/search?text={q}&size=100")
except Exception as e:
    print(f"SEARCH-FAIL {type(e).__name__}: {e}")
    sys.exit(2)
objs = res.get("objects", [])
others, ours_seen, unknown = [], [], []
for o in objs:
    pk = o["package"]
    name = pk.get("name", "?")
    pub = pk.get("publisher") or {}
    who = pub.get("username")
    if who is None:
        # Unknown, NOT 'someone else'. This distinction is the entire reason Part 1 exists.
        unknown.append(name)
    elif who == ACCOUNT:
        ours_seen.append(name)
    else:
        others.append((name, who, (pk.get("description") or "")[:34]))
print(f"results scanned: {len(objs)}   by {ACCOUNT}: {len(ours_seen)}   "
      f"by OTHER maintainers: {len(others)}   owner unreadable: {len(unknown)}")
for name, who, desc in others[:10]:
    print(f"  {name:46} {who:22} {desc!r}")
if unknown:
    print(f"  (owner unreadable, excluded from both counts: {', '.join(unknown[:5])})")

print("\n" + "=" * 100)
if len(others) >= 3:
    print("FINDING: the stub text appears on packages by maintainers who have never touched")
    print("this machine (CI publishers and unrelated individuals). Server-side mechanism.")
    print("=> local credential compromise is NOT indicated; no token rotation owed.")
elif len(others) == 0 and ours_seen:
    print("FINDING: the stub appears ONLY on this account's packages. That reverses the")
    print("conclusion and makes local-process investigation necessary again. Rotate nothing")
    print("yet; first check whether an npm-side opt-in (staged publishing / name reservation)")
    print("is enabled on this account, then audit publish events with credentials.")
else:
    print("FINDING: inconclusive this run (too few results or owners unreadable). Re-run; do")
    print("not carry RM-9 closed on an empty answer.")
if worst == 1:
    print("\nACTION NEEDED: at least one of our names has latest pointing at the stub.")
print("=" * 100)
sys.exit(0)
