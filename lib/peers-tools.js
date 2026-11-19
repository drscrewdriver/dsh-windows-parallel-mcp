// peers-tools.js -- the host's defineTool, reached through a STATIC import. See peers-schemastery.js
// for why the bridge is split in two and why a dynamic bare specifier does not resolve for a
// `link:`-installed package.
import * as toolsNs from '@deepseek-ai/dsh-tools';

export const defineTool = toolsNs.defineTool;
