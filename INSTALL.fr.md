# Install

[English](INSTALL.md) · [中文](INSTALL.zh.md) · [日本語](INSTALL.ja.md) · [한국어](INSTALL.ko.md) · **Français** · [Deutsch](INSTALL.de.md) · [Italiano](INSTALL.it.md) · [Español](INSTALL.es.md) · [Português](INSTALL.pt.md) · [Русский](INSTALL.ru.md)

> **Français translation — work in progress.** The English canonical text follows below; task-specific polishing replaces it section by section. The structure, code samples and numbers are already final — only the prose is pending. See the en document for the authoritative wording.

**English** · [中文](INSTALL.zh.md) · [日本語](INSTALL.ja.md) · [한국어](INSTALL.ko.md) · [Français](INSTALL.fr.md) · [Deutsch](INSTALL.de.md) · [Italiano](INSTALL.it.md) · [Español](INSTALL.es.md) · [Português](INSTALL.pt.md) · [Русский](INSTALL.ru.md)
## Requirements

- Windows (the engine is a Windows PowerShell sidecar; there is no portability story and none is claimed)
- Windows PowerShell 5.1 — ships with Windows 10/11. `pwsh` also works if you set `powershellPath`
- A DSH host `>=0.1.7-0 <0.3.0-0`

No Python, no `uv`, no MSVC runtime, no native module, no build step. The engine is four `.ps1` files
driven over a JSON line protocol by one long-lived STA process, started on the first tool call.

## Install into a profile: two cases, not three

There are exactly **two** cases — desktop and non-desktop. Choose the one that matches your host.

### 1. Non-desktop profiles (web, and any named profile)

Both routes work — pick either:

```bash
dsh --profile <profile> plugin add dsh-windows-parallel-mcp
```

```bash
pnpm add dsh-windows-parallel-mcp
```

The host adds the package to the profile's `dsh.profile.bundles`; the bundle patch
(`cordis.patch.yml`) inserts one row (`id: windows-parallel`). Nothing else is mounted or replaced.

### 2. The desktop profile (Electron-managed) — manual, pnpm only

The `desktop` profile is owned by the Electron application. **Do not use `dsh plugin add` for it** —
the CLI refuses every command against `desktop`, including read-only ones, with
`profile "desktop" is managed exclusively by the Electron application`. There is no CLI path here.

Install it manually with **pnpm only** — specifically the desktop app's **built-in pnpm** (the
`desktopPnpm` service, not the pnpm on your PATH). The supported sequence:

```bash
# 1. Back up the profile manifests and the installed package directory first.
# 2. Add the dependency with the built-in pnpm and refresh the lockfile.
# 3. Restart DSH so the new bundle is composed at startup.
```

A pinned lockfile must be changed surgically: a freshly published package is rejected from the
lockfile while it is inside pnpm's `minimumReleaseAge` cooling window. Add the exact version to the
profile's `pnpm-workspace.yaml`:

```yaml
minimumReleaseAgeExclude:
  - dsh-windows-parallel-mcp@<version>   # e.g. 0.2.0
```

Without that line, `pnpm install --frozen-lockfile` fails with
`dsh-windows-parallel-mcp@<version> was published at ... within the minimumReleaseAge cutoff`.

### Installing from a local build (both cases)

Pack first, then install the tarball — this is also how the profile's other local-development
plugins are mounted:

```bash
npm pack --ignore-scripts                       # -> dsh-windows-parallel-mcp-<version>.tgz
```

For non-desktop profiles, pass the tarball to `dsh --profile <profile> plugin add <tgz>`.
For desktop, unpack the tarball over the installed package directory (after backing it up).

A `link:` install keeps the package's REAL path outside the profile tree, and Node resolves bare
peer specifiers (`@deepseek-ai/schemastery`) upward from the real path -- so the peers never
resolve, the settings form silently disappears, and the plugin falls to its shim. A `file:` tarball
installs as a real directory inside the profile and the peers resolve exactly like every other
plugin. Measured, not inferred: `link:` -> `config schema: local-standard-schema-shim`,
`file:` -> `config schema: @deepseek-ai/schemastery`.

## Verify it actually activated

Installing is not the same as activating, and a plugin that fails to activate prints one warning into
a busy log while its tool silently does not exist. From the package directory:

```bash
node scripts/verify-install.mjs
```

It creates a throwaway profile, installs the package, boots the host, asserts the plugin is **not**
named in the "did not activate" block, and removes the profile again. `--keep` leaves it for
inspection, `--profile <name>` uses a different name (it only ever deletes profiles it created).

## Settings

Settings live in the bundle patch / profile config. On hosts where `@deepseek-ai/schemastery` is
resolvable from the plugin, the fields also appear in the settings form; where it is not, the plugin
falls back to a built-in standard-schema shim, the values still work, and **the form is not rendered**.
The fallback is reported in the host log as `config schema: local-standard-schema-shim`.

| key | default |
|---|---|
| `enabled` | `true` |
| `settleMs` | `350` |
| `requestTimeoutMs` | `20000` |
| `powershellPath` | `""` |
| `logWorkerStderr` | `false` |

## Uninstall

```bash
dsh plugin --profile <profile> remove dsh-windows-parallel-mcp
```

The worker process is a child of the host and exits when stdin closes; there is no daemon, no service,
no scheduled task, nothing left behind.

## Troubleshooting

| symptom | cause |
|---|---|
| `wpm` tool missing | the plugin did not activate — check the boot output for `windows-parallel`, then run `node scripts/verify-install.mjs` |
| every action returns `paused` | `enabled` is false, or the engine is paused by the owner |
| `unreachable` on a terminal | by design: terminal text surfaces expose neither a child window nor a `Document` element (`terminal_no_door` when recognised as a terminal) |
| `engine worker unavailable` | the sidecar could not start; set `logWorkerStderr` to `true` and re-run — the worker's own message is the diagnostic |
