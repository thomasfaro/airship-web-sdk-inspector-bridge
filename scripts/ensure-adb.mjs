#!/usr/bin/env node
/**
 * Find adb, or install a private copy of Google's platform-tools in .adb/.
 *
 * adb is the whole cable: without it the bridge sees no phone. Asking for it
 * through Homebrew turns a two-double-click tool into "first install a package
 * manager", so the launcher fetches it the same way it fetches Node — into the
 * bridge folder, with no administrator password, undone by deleting .adb/.
 *
 * The download is verified. Google's "latest" URLs ship no checksum next to
 * them, so the version, the file name and its sha1 all come from the SDK
 * manifest instead, and the archive is only unpacked once the hash matches.
 *
 * Node built-ins only: this runs before anything is installed, and the bridge
 * itself has no dependencies.
 *
 * Contract with scripts/start.sh, which does all the asking:
 *   --probe    look only. Exit 0 and print the folder holding adb, or exit 2.
 *   --install  download and install. Exit 0 and print the folder, or exit 1.
 * Everything a person reads goes to stderr, so stdout stays a single path.
 */

import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PRIVATE_DIR = path.join(ROOT, ".adb");
const REPOSITORY = "https://dl.google.com/android/repository";
const MANIFEST_URL = `${REPOSITORY}/repository2-3.xml`;

const say = (line) => process.stderr.write(`${line}\n`);

function works(binary) {
  const result = spawnSync(binary, ["version"], { stdio: "ignore", timeout: 10_000 });
  return result.status === 0;
}

// Android Studio installs adb where no shell profile puts it, and a launcher
// started from Finder sees an even shorter PATH than a terminal would.
function findInstalled() {
  const candidates = [];

  const onPath = spawnSync("/usr/bin/which", ["adb"], { encoding: "utf8", timeout: 5_000 });
  if (onPath.status === 0) candidates.push(onPath.stdout.trim());

  candidates.push(
    path.join(PRIVATE_DIR, "platform-tools", "adb"),
    path.join(homedir(), "Library", "Android", "sdk", "platform-tools", "adb"),
    path.join(homedir(), "Android", "Sdk", "platform-tools", "adb"),
    "/opt/homebrew/bin/adb",
    "/usr/local/bin/adb"
  );

  for (const candidate of candidates) {
    if (candidate && existsSync(candidate) && works(candidate)) return path.dirname(candidate);
  }
  return null;
}

function hostOs() {
  if (process.platform === "darwin") return "macosx";
  if (process.platform === "linux") return "linux";
  return null;
}

async function get(url, { timeoutMs = 20_000 } = {}) {
  // Pinned to Google's own host: this file decides what gets executed later.
  if (new URL(url).origin !== "https://dl.google.com") {
    throw new Error(`refused a URL outside dl.google.com: ${url}`);
  }
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: abort.signal, redirect: "follow" });
    if (!response.ok) throw new Error(`HTTP ${response.status} for ${url}`);
    return response;
  } finally {
    clearTimeout(timer);
  }
}

// A hand-rolled read of the one package we want, rather than an XML parser we
// would have to vendor. The shape is stable and the result is checksum-verified
// either way: a misread here fails the hash, it does not install the wrong file.
function readManifest(xml) {
  const packages = [...xml.matchAll(/<remotePackage path="platform-tools">([\s\S]*?)<\/remotePackage>/g)].map(
    (match) => match[1]
  );
  if (!packages.length) throw new Error("the SDK manifest lists no platform-tools package");

  // channel-0 is the stable channel; beta and canary also publish here.
  const block = packages.find((candidate) => /channelRef ref="channel-0"/.test(candidate)) ?? packages[0];

  const revision = /<revision>([\s\S]*?)<\/revision>/.exec(block)?.[1] ?? "";
  const version = ["major", "minor", "micro"]
    .map((part) => new RegExp(`<${part}>(\\d+)</${part}>`).exec(revision)?.[1])
    .filter(Boolean)
    .join(".");

  const os = hostOs();
  const archive = [...block.matchAll(/<archive>([\s\S]*?)<\/archive>/g)]
    .map((match) => match[1])
    .find((candidate) => new RegExp(`<host-os>${os}</host-os>`).test(candidate));
  if (!archive) throw new Error(`the SDK manifest has no platform-tools build for ${os}`);

  // <complete> is the full archive; <patch> entries next to it are deltas.
  const complete = /<complete>([\s\S]*?)<\/complete>/.exec(archive)?.[1] ?? "";
  const file = /<url>([^<]+)<\/url>/.exec(complete)?.[1];
  const sha1 = /<checksum type="sha1">([0-9a-f]+)<\/checksum>/.exec(complete)?.[1];
  const size = Number(/<size>(\d+)<\/size>/.exec(complete)?.[1] ?? 0);
  if (!file || !sha1) throw new Error("the SDK manifest entry is missing its file name or checksum");

  return { version: version || "unknown", file, sha1, size };
}

function unpack(zip, target) {
  rmSync(target, { recursive: true, force: true });
  mkdirSync(target, { recursive: true });

  // unzip is on every macOS and nearly every Linux; ditto is the macOS fallback.
  for (const [binary, args] of [
    ["unzip", ["-q", "-o", zip, "-d", target]],
    ["ditto", ["-xk", zip, target]]
  ]) {
    const result = spawnSync(binary, args, { stdio: "ignore", timeout: 180_000 });
    if (result.status === 0) return;
  }
  throw new Error("could not unpack the archive (neither unzip nor ditto worked)");
}

async function install() {
  const os = hostOs();
  if (!os) {
    say(`Unsupported operating system: ${process.platform}.`);
    return null;
  }

  say("Looking up the current Android platform-tools release…");
  let manifest;
  try {
    const response = await get(MANIFEST_URL);
    manifest = readManifest(await response.text());
  } catch (error) {
    say(`Could not read Google's SDK manifest: ${error.message}`);
    say("Check the internet connection or your proxy settings.");
    return null;
  }

  const megabytes = manifest.size ? Math.round(manifest.size / 1e6) : 16;
  say(`Downloading platform-tools ${manifest.version} (about ${megabytes} MB, once)…`);

  const staging = mkdtempSync(path.join(tmpdir(), "airship-bridge-adb-"));
  const zip = path.join(staging, manifest.file);
  try {
    const response = await get(`${REPOSITORY}/${manifest.file}`, { timeoutMs: 180_000 });
    const bytes = Buffer.from(await response.arrayBuffer());

    const actual = createHash("sha1").update(bytes).digest("hex");
    if (actual !== manifest.sha1) {
      say("Checksum mismatch: the download is corrupted or was tampered with.");
      say("Nothing was installed.");
      return null;
    }

    writeFileSync(zip, bytes);
    say("Verifying the download… ok");
    unpack(zip, PRIVATE_DIR);
  } catch (error) {
    say(`The download failed: ${error.message}`);
    rmSync(PRIVATE_DIR, { recursive: true, force: true });
    return null;
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }

  const binDir = path.join(PRIVATE_DIR, "platform-tools");
  const adb = path.join(binDir, "adb");
  if (!existsSync(adb)) {
    say("The unpacked platform-tools folder looks incomplete.");
    return null;
  }

  // Zip carries Unix modes, but not through every unpacker.
  for (const name of readdirSync(binDir)) {
    const file = path.join(binDir, name);
    if (!path.extname(name)) {
      try {
        chmodSync(file, 0o755);
      } catch {
        /* a mode we could not set is only a problem if adb itself fails below */
      }
    }
  }

  if (!works(adb)) {
    say("The installed adb does not run on this machine.");
    return null;
  }

  try {
    const version = execFileSync(adb, ["version"], { encoding: "utf8", timeout: 10_000 }).split("\n")[0];
    say(`${version.trim()} is ready.`);
  } catch {
    say("adb is ready.");
  }
  return binDir;
}

const mode = process.argv.includes("--install") ? "install" : "probe";

const found = findInstalled();
if (found) {
  process.stdout.write(`${found}\n`);
  process.exit(0);
}
if (mode === "probe") {
  process.exit(2);
}

const installed = await install();
if (!installed) process.exit(1);
process.stdout.write(`${installed}\n`);
