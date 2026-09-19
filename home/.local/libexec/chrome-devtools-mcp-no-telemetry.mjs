#!/usr/bin/env node
// Privacy shim for chrome-devtools-axi -> chrome-devtools-mcp.
// Forces the usage-statistics opt-out, then hands off to the installed
// chrome-devtools-mcp entry point. Referenced by CHROME_DEVTOOLS_AXI_MCP_PATH
// in ~/.profile and ~/.config/environment.d/90-kunchenguid-privacy.conf.
//
// The target is resolved at load time (global npm root, then any node
// resolution from this file's location) so an `npm i -g` relocation or a
// mise/nvm node switch fails loudly with the searched paths instead of
// silently killing the axi bridge with BRIDGE_NOT_READY.
import { existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { createRequire } from "node:module";

const ENTRY = "chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js";
const tried = [];

function fromGlobalRoot() {
  try {
    const root = execFileSync("npm", ["root", "-g"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    const p = join(root, ENTRY);
    tried.push(p);
    return existsSync(p) ? p : null;
  } catch {
    return null;
  }
}

function fromRequire() {
  try {
    return createRequire(import.meta.url).resolve(ENTRY);
  } catch (e) {
    tried.push(`require.resolve(${ENTRY}) from ${import.meta.url}`);
    return null;
  }
}

const target = fromGlobalRoot() ?? fromRequire();
if (!target) {
  console.error(`[chrome-devtools-mcp-no-telemetry] cannot find ${ENTRY}. Tried:\n  ${tried.join("\n  ")}\nInstall with: npm i -g chrome-devtools-mcp`);
  process.exit(1);
}

process.env.CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS = "1";
if (!process.argv.includes("--no-usageStatistics") && !process.argv.includes("--usageStatistics=false")) {
  process.argv.push("--no-usageStatistics");
}
await import(pathToFileURL(target).href);
