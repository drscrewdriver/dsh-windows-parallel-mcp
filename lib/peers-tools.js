// peers-tools.js -- the host's defineTool, reached through a STATIC import. See peers-schemastery.js
// for why the bridge is split in two and why a dynamic bare specifier does not resolve for a
// `link:`-installed package.
//
// @ts-nocheck -- DELIBERATE, and the only honest option. `@deepseek-ai/dsh-tools` is a peer the HOST
// provides; it is not installed in this checkout, so a type checker can only see an unresolved module
// here. The alternatives are both lies: a `declare module` stub would assert a shape nobody verified
// against the real package (and this file exists precisely because peer resolution is unpredictable),
// while dropping the file from the check config makes its IMPORTER fail with TS2307 -- a gate
// inventing a problem of its own. The barrier is the point: everything downstream of this import is
// untyped on purpose, and this line says so where a reader will see it.
// @ts-nocheck
import * as toolsNs from '@deepseek-ai/dsh-tools';

export const defineTool = toolsNs.defineTool;
