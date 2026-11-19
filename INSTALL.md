# Install

## Requirements

- Windows (the engine is a Windows PowerShell sidecar; there is no portability story and none is claimed)
- Windows PowerShell 5.1 — ships with Windows 10/11. `pwsh` also works if you set `powershellPath`
- A DSH host `>=0.1.7-0 <0.3.0-0`

No Python, no `uv`, no MSVC runtime, no native module, no build step. The engine is four `.ps1` files
driven over a JSON line protocol by one long-lived STA process, started on the first tool call.

## Install into a profile

```bash
dsh plugin --profile <profile> add dsh-windows-parallel-mcp
```

The host adds the package to the profile's `dsh.profile.bundles`; the bundle patch
(`cordis.patch.yml`) inserts one row (`id: windows-parallel`). Nothing else is mounted or replaced.

To install from a local checkout instead:

```bash
dsh plugin --profile <profile> add /path/to/dsh-windows-parallel-mcp
```

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
