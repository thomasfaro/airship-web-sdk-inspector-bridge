#!/usr/bin/env node
/**
 * Bring the bridge folder up to date, at launch.
 *
 * Two folders exist in the wild and each gets the mechanism it can use: a
 * `git clone` is fast-forwarded, a folder unzipped from the repository page
 * compares published version numbers and replaces its own files.
 *
 * Contract with scripts/start.sh: never fail, never prompt, never hang. Print
 * one line only when something actually moved, and exit 10 so the launcher can
 * restart itself on the new code. Every other outcome, including no network and
 * a folder someone is working in, is exit 0 and silence — an install that stays
 * on the version it had is a fine outcome, a launcher that dies is not.
 *
 * Node built-ins only: this runs before anything else, on whatever Node the
 * launcher just made available.
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const OWNER = "thomasfaro";
const REPO = "airship-web-sdk-inspector-bridge";
const BRANCH = "main";
const MANIFEST_URL = `https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/package.json`;
const ARCHIVE_URL = `https://codeload.github.com/${OWNER}/${REPO}/tar.gz/refs/heads/${BRANCH}`;
const ALLOWED_HOSTS = ["raw.githubusercontent.com", "codeload.github.com"];

// What an update must never write — everything else in the published archive is
// the source of truth. Asking it this way round, rather than listing what may be
// replaced, is what lets a file added at the top level of a release reach a
// folder that has never heard of it: a list of allowed names can only ever hold
// names the version doing the updating already knew.
//
// The private Node in .node/, the private adb in .adb/, the opt-out marker and
// the staging folders belong to this install rather than to the source.
const PROTECTED = new Set([".git", ".node", ".adb", ".no-auto-update", ".DS_Store"]);

function isProtected(entry) {
  return PROTECTED.has(entry) || entry.startsWith(".update-");
}

const UPDATED = 10;

function optedOut() {
  return process.env.BRIDGE_NO_AUTO_UPDATE === "1" || existsSync(path.join(ROOT, ".no-auto-update"));
}

function localVersion() {
  try {
    return String(JSON.parse(readFileSync(path.join(ROOT, "package.json"), "utf8"))?.version ?? "").trim() || null;
  } catch {
    return null;
  }
}

// 1 when left is strictly newer than right, 0 otherwise. Unreadable on either
// side means "do nothing", which is what 0 gets you.
function isNewer(left, right) {
  if (!left || !right) return false;
  const parse = (value) => String(value).split(".").map((part) => Number.parseInt(part, 10) || 0);
  const [a, b] = [parse(left), parse(right)];
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const [x, y] = [a[i] ?? 0, b[i] ?? 0];
    if (x !== y) return x > y;
  }
  return false;
}

async function get(url, { timeoutMs = 15_000, headers = {} } = {}) {
  const parsed = new URL(url);
  if (parsed.protocol !== "https:" || !ALLOWED_HOSTS.includes(parsed.hostname)) {
    throw new Error(`refused a URL outside the pinned GitHub hosts: ${url}`);
  }
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: abort.signal, redirect: "follow", headers });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response;
  } finally {
    clearTimeout(timer);
  }
}

// A checkout gets the stronger mechanism: git refuses to overwrite work, so the
// guards only have to establish that fast-forwarding is unambiguously safe.
function updateCheckout() {
  const git = (...args) =>
    spawnSync("git", ["-C", ROOT, ...args], {
      encoding: "utf8",
      timeout: 30_000,
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_SSH_COMMAND: "ssh -o BatchMode=yes" }
    });

  if (git("status", "--porcelain").stdout?.trim()) return false;

  const branch = git("rev-parse", "--abbrev-ref", "HEAD").stdout?.trim();
  if (!branch || branch === "HEAD") return false;

  const before = git("rev-parse", "HEAD").stdout?.trim();
  const pull = git(
    "-c",
    "http.lowSpeedLimit=1000",
    "-c",
    "http.lowSpeedTime=10",
    "pull",
    "--ff-only",
    "--quiet",
    "origin",
    branch
  );
  if (pull.status !== 0) return false;
  if (git("rev-parse", "HEAD").stdout?.trim() === before) return false;

  process.stderr.write("Updated to the latest version.\n");
  return true;
}

// Replacing a folder by renaming it into place, rather than copying over it,
// is what lets the shell script running this survive its own update: the old
// inode stays open until the launcher re-executes.
function swapIn(staging) {
  const attic = mkdtempSync(path.join(tmpdir(), "airship-bridge-old-"));
  try {
    // Entries the release has dropped are left where they are: an orphaned file
    // nobody reads is inert, and a delete loop pointed at the wrong folder is
    // not. A folder still in the release is replaced whole, so anything removed
    // inside one does go.
    for (const entry of readdirSync(staging)) {
      if (isProtected(entry)) continue;
      const current = path.join(ROOT, entry);
      if (existsSync(current)) renameSync(current, path.join(attic, entry));
      renameSync(path.join(staging, entry), current);
    }
  } finally {
    rmSync(attic, { recursive: true, force: true });
  }
}

async function updateArchive() {
  const current = localVersion();
  let published = null;
  try {
    // Uncompressed on purpose. raw.githubusercontent caches the gzip and the
    // identity variants separately, and the gzip one was observed serving a
    // version that had been superseded ten minutes earlier, from several edge
    // nodes, long past its own max-age. Node asks for gzip by default, so left
    // alone this reads a stale number and skips a release. The file is 400 bytes.
    const response = await get(MANIFEST_URL, { headers: { "accept-encoding": "identity" } });
    published = String(JSON.parse(await response.text())?.version ?? "").trim();
  } catch {
    return false;
  }
  if (!isNewer(published, current)) return false;

  // Staged next to the folder it will replace, so every rename below stays on
  // one filesystem and is therefore atomic.
  const staging = mkdtempSync(path.join(ROOT, ".update-"));
  try {
    const archive = path.join(staging, "bridge.tar.gz");
    writeFileSync(archive, Buffer.from(await (await get(ARCHIVE_URL, { timeoutMs: 120_000 })).arrayBuffer()));

    const extracted = path.join(staging, "unpacked");
    mkdirSync(extracted, { recursive: true });
    const tar = spawnSync("tar", ["-xzf", archive, "-C", extracted, "--strip-components=1"], {
      stdio: "ignore",
      timeout: 120_000
    });
    if (tar.status !== 0) return false;

    // The archive is fetched from a second cache, so check what actually came
    // down rather than what was announced. Swapping in something no newer would
    // announce an update that did not happen, at every single launch.
    let arrived = null;
    try {
      arrived = String(
        JSON.parse(readFileSync(path.join(extracted, "package.json"), "utf8"))?.version ?? ""
      ).trim();
    } catch {
      return false;
    }
    if (!isNewer(arrived, current)) return false;

    swapIn(extracted);
    process.stderr.write(`Updated to version ${arrived}.\n`);
    return true;
  } catch {
    return false;
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}

async function main() {
  if (optedOut()) return 0;

  const moved = existsSync(path.join(ROOT, ".git")) ? updateCheckout() : await updateArchive();
  return moved ? UPDATED : 0;
}

let code = 0;
try {
  code = await main();
} catch {
  code = 0;
}
process.exit(code);
