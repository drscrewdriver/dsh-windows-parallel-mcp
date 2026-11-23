// peers-schemastery.js -- the host's schema library, reached through a STATIC import.
//
// WHY THIS FILE EXISTS (and why it is separate from peers-tools.js). The desktop profile showed
// `config schema: local-standard-schema-shim` -- no settings form -- because a DYNAMIC
// import('@deepseek-ai/schemastery') from a `link:`-installed package resolves upward from the
// link TARGET (E:\test\...), never through the profile's node_modules. The proven pattern in the
// same profile is dsh-bash-terminal-ts: STATIC bare imports, which the host's loader resolves in
// the host realm.
//
// WHY THE SPLIT MATTERS. schemastery is a cordis dependency: present wherever the host runs.
// dsh-tools is NOT installed in this profile at all (verified: absent from node_modules). One
// combined bridge module would mean the missing dsh-tools throws during evaluation and takes
// schemastery down with it -- the plugin would fail to LOAD, which is worse than the shim path it
// was meant to fix. Two files, two independent failure domains.
// @ts-nocheck -- DELIBERATE, same reasoning as peers-tools.js: `@deepseek-ai/schemastery` is a
// cordis dependency the HOST supplies, and whatever type surface a checker resolves for it here is a
// property of THIS machine's checkout, not of the package. `z` below is deliberately the shape-agnostic
// handoff into config.js; pinning it to one installed version's `.default` export would turn a
// host-version difference into a false red. The barrier is the point.
// @ts-nocheck
import schemasteryNs from '@deepseek-ai/schemastery';

export const z = schemasteryNs?.default ?? schemasteryNs;
