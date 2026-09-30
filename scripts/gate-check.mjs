#!/usr/bin/env node
// Reproduces the Scaffold-HBAR bounty eligibility gate against this template using the real CLI.
// Usage: node scripts/gate-check.mjs --help

import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CONFIG = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, "scripts", "gate.config.json"), "utf8"));

// Mirrors TemplateManifestSchema in create-scaffold-hbar src/types.ts at this version.
const SCHEMA_CLI_VERSION = "0.4.1";
const MANIFEST_ENUMS = {
  frontend: ["nextjs-app", "none"],
  solidityFramework: ["hardhat", "foundry", "none"],
  packageManager: ["yarn", "npm", "none"],
};
const MIN_NODE = [20, 18, 3];
const MINUTE = 60_000;

const HELP = `Scaffold-HBAR gate check

  node scripts/gate-check.mjs [options]

Options
  --template <owner/repo[#ref]>  Template to scaffold (default: this repo's origin remote)
  --local                        Scaffold from the working tree instead of GitHub
  --frameworks <list>            Comma list of foundry,hardhat (default: all the manifest allows)
  --pms <list>                   Comma list of npm,yarn (default: all the manifest allows)
  --cli-version <v>              create-scaffold-hbar version (default: latest on npm)
  --skip-skills                  Do not install Hedera Skills during scaffold
  --allow-pending-proof          Do not fail when no testnet proof is configured yet
  --proofs-only                  Only verify the testnet proofs in scripts/gate.config.json on the mirror node
  --strict                       Treat warnings as failures
  --keep                         Keep the temp workspace for inspection
`;

// ---------- args ----------

function parseArgs(argv) {
  const opts = { local: false, skipSkills: false, allowPendingProof: false, strict: false, keep: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      const value = argv[++i];
      if (!value) throw new Error(`${arg} needs a value`);
      return value;
    };
    switch (arg) {
      case "--template": opts.template = next(); break;
      case "--frameworks": opts.frameworks = next().split(","); break;
      case "--pms": opts.pms = next().split(","); break;
      case "--cli-version": opts.cliVersion = next(); break;
      case "--local": opts.local = true; break;
      case "--skip-skills": opts.skipSkills = true; break;
      case "--allow-pending-proof": opts.allowPendingProof = true; break;
      case "--proofs-only": opts.proofsOnly = true; break;
      case "--strict": opts.strict = true; break;
      case "--keep": opts.keep = true; break;
      case "-h": case "--help": console.log(HELP); process.exit(0);
      default: throw new Error(`Unknown option ${arg}`);
    }
  }
  return opts;
}

// ---------- results ----------

const results = [];
function record(scope, check, status, detail = "") {
  results.push({ scope, check, status, detail });
  const icon = { pass: "PASS", fail: "FAIL", warn: "WARN", skip: "SKIP", pending: "PEND" }[status];
  console.log(`  [${icon}] ${scope} · ${check}${detail ? ` — ${detail}` : ""}`);
}

// ---------- processes ----------

const liveChildren = new Set();

function killTree(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  try {
    process.kill(-child.pid, "SIGTERM");
  } catch {
    return;
  }
  setTimeout(() => {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {
      // already gone
    }
  }, 5000).unref();
}

function killAll() {
  for (const child of liveChildren) killTree(child);
}

process.on("exit", killAll);
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    killAll();
    process.exit(130);
  });
}

function spawnLogged(cmd, args, { cwd, env, logFile }) {
  const child = spawn(cmd, args, { cwd, env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
  liveChildren.add(child);
  child.on("exit", () => liveChildren.delete(child));
  const log = fs.createWriteStream(logFile, { flags: "a" });
  log.write(`\n$ ${cmd} ${args.join(" ")}\n`);
  let output = "";
  const onData = chunk => {
    output += chunk;
    log.write(chunk);
  };
  child.stdout.on("data", onData);
  child.stderr.on("data", onData);
  child.on("close", () => log.end());
  return { child, getOutput: () => output };
}

function run(cmd, args, { cwd, env, logFile, timeoutMs }) {
  return new Promise(resolve => {
    const { child, getOutput } = spawnLogged(cmd, args, { cwd, env, logFile });
    const timer = setTimeout(() => {
      killTree(child);
      resolve({ code: null, output: `${getOutput()}\n[gate-check] timed out after ${timeoutMs / MINUTE} min` });
    }, timeoutMs);
    child.on("close", code => {
      clearTimeout(timer);
      resolve({ code, output: getOutput() });
    });
    child.on("error", err => {
      clearTimeout(timer);
      resolve({ code: -1, output: `${getOutput()}\n${err.message}` });
    });
  });
}

function tail(text, lines = 15) {
  return text.trim().split("\n").slice(-lines).join("\n");
}

function which(bin) {
  try {
    execFileSync("which", [bin], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

// ---------- environment ----------

function versionAtLeast(version, floor) {
  const parts = version.replace(/^v/, "").split(".").map(Number);
  for (let i = 0; i < floor.length; i++) {
    if ((parts[i] ?? 0) !== floor[i]) return (parts[i] ?? 0) > floor[i];
  }
  return true;
}

// A stranger's shell: no npm_* leakage from a parent `npm run`, a throwaway git identity.
function baseEnv(workDir, binDir) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("npm_")));
  const gitConfig = path.join(workDir, "gitconfig");
  fs.writeFileSync(gitConfig, "[user]\n\tname = Gate Check\n\temail = gate-check@example.invalid\n[init]\n\tdefaultBranch = main\n");
  return {
    ...env,
    GIT_CONFIG_GLOBAL: gitConfig,
    PATH: `${binDir}${path.delimiter}${env.PATH}`,
    NEXT_TELEMETRY_DISABLED: "1",
    COREPACK_ENABLE_DOWNLOAD_PROMPT: "0",
    npm_config_yes: "true",
  };
}

function ensureYarn(binDir) {
  if (which("yarn")) return true;
  try {
    execFileSync("corepack", ["enable", "--install-directory", binDir, "yarn"], { stdio: "ignore" });
    return fs.existsSync(path.join(binDir, "yarn"));
  } catch {
    return false;
  }
}

// ---------- template source ----------

function originTemplate() {
  const url = execFileSync("git", ["remote", "get-url", "origin"], { cwd: REPO_ROOT, encoding: "utf8" }).trim();
  const match = url.match(/github\.com[:/]([\w.-]+)\/([\w.-]+?)(?:\.git)?$/);
  if (!match) throw new Error(`origin remote is not a GitHub repo: ${url}`);
  return `${match[1]}/${match[2]}`;
}

function parseTemplateRef(template) {
  const match = template.match(/^([\w.-]+)\/([\w.-]+)(?:#(.+))?$/);
  if (!match) throw new Error(`--template must be owner/repo[#ref], got ${template}`);
  return { owner: match[1], repo: match[2], ref: match[3] };
}

// Same file set a GitHub tarball would contain: tracked + untracked-not-ignored, submodules as empty dirs.
function exportWorkingTree(dest) {
  const gitlinks = new Set(
    execFileSync("git", ["ls-files", "-s"], { cwd: REPO_ROOT, encoding: "utf8" })
      .split("\n")
      .filter(line => line.startsWith("160000"))
      .map(line => line.split("\t")[1]),
  );
  const files = execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], {
    cwd: REPO_ROOT,
    encoding: "utf8",
  })
    .split("\0")
    .filter(Boolean);
  for (const rel of files) {
    const src = path.join(REPO_ROOT, rel);
    const dst = path.join(dest, rel);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    const stat = fs.lstatSync(src, { throwIfNoEntry: false });
    if (gitlinks.has(rel)) fs.mkdirSync(dst, { recursive: true });
    else if (stat?.isSymbolicLink()) fs.symlinkSync(fs.readlinkSync(src), dst);
    else if (stat) fs.copyFileSync(src, dst);
  }
}

// ---------- source checks ----------

function checkFiles(src) {
  for (const file of ["README.md", "AGENTS.md", "template.json", "packages/nextjs/package.json"]) {
    record("source", `${file} present`, fs.existsSync(path.join(src, file)) ? "pass" : "fail");
  }
  const contracts = ["hardhat", "foundry"].filter(fw => fs.existsSync(path.join(src, "packages", fw)));
  record("source", "contracts package in packages/", contracts.length ? "pass" : "fail", contracts.join(", "));

  const licence = ["LICENSE", "LICENCE", "LICENSE.md"].map(f => path.join(src, f)).find(f => fs.existsSync(f));
  const isMit = licence && /MIT License/.test(fs.readFileSync(licence, "utf8"));
  record("source", "MIT licence", isMit ? "pass" : "fail", licence ? path.basename(licence) : "no licence file");
}

function checkManifest(src) {
  const file = path.join(src, "template.json");
  if (!fs.existsSync(file)) return null;
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (err) {
    record("source", "template.json parses", "fail", err.message);
    return null;
  }
  const problems = [];
  if (typeof manifest.name !== "string" || !manifest.name) problems.push("top-level `name` is required");
  const block = manifest["create-scaffold-hbar"] ?? manifest["create-hbar"];
  if (!block) problems.push("missing `create-scaffold-hbar` block");
  for (const [key, allowed] of Object.entries(MANIFEST_ENUMS)) {
    const caps = block?.capabilities?.[key];
    if (caps !== undefined && (!Array.isArray(caps) || caps.some(v => !allowed.includes(v)))) {
      problems.push(`capabilities.${key} must be a subset of ${allowed.join("|")}`);
    }
    const def = block?.defaults?.[key];
    if (def !== undefined && !allowed.includes(def)) problems.push(`defaults.${key} must be one of ${allowed.join("|")}`);
    if (def !== undefined && caps && !caps.includes(def)) problems.push(`defaults.${key} is not in capabilities.${key}`);
  }
  for (const env of block?.envVars ?? []) {
    if (!env?.key || typeof env.description !== "string") problems.push("envVars entries need key + description");
  }
  record("source", `template.json matches CLI ${SCHEMA_CLI_VERSION} schema`, problems.length ? "fail" : "pass", problems.join("; "));
  return manifest;
}

async function checkManifestReachable({ owner, repo, ref }) {
  const repoInfo = await fetch(`https://api.github.com/repos/${owner}/${repo}`).then(r => (r.ok ? r.json() : null));
  if (!repoInfo) {
    record("remote", "repository is public", "fail", `${owner}/${repo} not reachable anonymously`);
    return;
  }
  record("remote", "repository is public", repoInfo.private ? "fail" : "pass");
  const onMain = repoInfo.default_branch === "main";
  record("remote", "default branch is main", onMain ? "pass" : "fail", onMain ? "" : `CLI reads template.json from 'main' but default is '${repoInfo.default_branch}'`);
  const res = await fetch(`https://api.github.com/repos/${owner}/${repo}/contents/template.json?ref=${ref ?? "main"}`);
  record("remote", "template.json fetchable where the CLI looks", res.ok ? "pass" : "fail", `HTTP ${res.status}`);
}

// The CLI deletes yarn.lock in npm mode, so each package manager needs its own lockfile to stay reproducible.
async function checkLockfiles(src, pms, env, logFile) {
  const leaksLocalPath = text => /\/Users\/|\/home\/|file:\//.test(text);
  if (pms.includes("npm")) {
    const lock = path.join(src, "package-lock.json");
    const text = fs.existsSync(lock) ? fs.readFileSync(lock, "utf8") : null;
    record("source", "package-lock.json for npm mode", text && !leaksLocalPath(text) ? "pass" : "fail", !text ? "missing" : leaksLocalPath(text) ? "contains local absolute paths" : "");
  }
  if (!pms.includes("yarn")) return;
  const lock = path.join(src, "yarn.lock");
  const text = fs.existsSync(lock) ? fs.readFileSync(lock, "utf8") : "";
  const berry = text.includes("__metadata:");
  record("source", "yarn.lock is Yarn Berry format", berry && !leaksLocalPath(text) ? "pass" : "fail", !text ? "missing" : !berry ? "v1 format (was it rewritten by npm?)" : leaksLocalPath(text) ? "contains local absolute paths" : "");
  if (!berry) return;
  // Install in a copy so the scaffold source stays free of node_modules and install state.
  const scratch = `${src}-lockcheck`;
  fs.cpSync(src, scratch, { recursive: true, verbatimSymlinks: true, filter: from => path.basename(from) !== ".git" });
  const { code, output } = await run("yarn", ["install", "--immutable", "--mode=skip-build"], { cwd: scratch, env, logFile, timeoutMs: 15 * MINUTE });
  fs.rmSync(scratch, { recursive: true, force: true });
  record("source", "yarn.lock in sync with package.json files", code === 0 ? "pass" : "fail", code === 0 ? "" : tail(output, 5));
}

function checkNoEnvFiles(src, trackedFiles) {
  const envFiles = trackedFiles.filter(f => /(^|\/)\.env(\..+)?$/.test(f) && !f.endsWith(".example"));
  record("source", "no committed .env files", envFiles.length ? "fail" : "pass", envFiles.join(", "));
}

async function secretScan(scope, args, logFile, env) {
  if (!which("gitleaks")) {
    record(scope, "secret scan (gitleaks)", "fail", "gitleaks not installed");
    return;
  }
  const { code, output } = await run("gitleaks", [...args, "--redact", "--no-banner", "--no-color", "--exit-code", "1"], {
    cwd: REPO_ROOT,
    env,
    logFile,
    timeoutMs: 5 * MINUTE,
  });
  record(scope, "secret scan (gitleaks)", code === 0 ? "pass" : "fail", code === 0 ? "" : tail(output, 5));
}

function mirrorTxPath(id, scheduled) {
  if (/^0x[0-9a-fA-F]{64}$/.test(id)) return `contracts/results/${id}`;
  const match = id.match(/^(\d+\.\d+\.\d+)[@-](\d+)[.-](\d+)$/);
  if (!match) throw new Error(`unrecognised transaction id ${id}`);
  // A scheduled transaction shares its id with the one that created the schedule.
  return `transactions/${match[1]}-${match[2]}-${match[3]}${scheduled ? "?scheduled=true" : ""}`;
}

const MIRROR = "https://testnet.mirrornode.hedera.com/api/v1";
const mirrorJson = url => fetch(url).then(r => (r.ok ? r.json() : null));

/**
 * A proof is a transaction id or hash, or a consensus timestamp. A timestamp proof can also require that the
 * transaction was run by the Schedule Service (`scheduled`) and that `contract` emitted at least `minLogs`
 * logs with `topic0` in it, so a proof shows what happened, not just that something succeeded.
 */
async function verifyProof(proof) {
  if (!proof.timestamp) {
    const body = await mirrorJson(`${MIRROR}/${mirrorTxPath(proof.id, proof.scheduled)}`);
    const result = body?.transactions?.[0]?.result ?? body?.result;
    return result === "SUCCESS" ? { ok: true, detail: "mirror node result: SUCCESS" } : { ok: false, detail: `mirror node result: ${result ?? "not found"}` };
  }
  const txs = (await mirrorJson(`${MIRROR}/transactions?timestamp=${proof.timestamp}`))?.transactions ?? [];
  const tx = txs[0];
  if (!tx) return { ok: false, detail: "no transaction at that consensus timestamp" };
  if (tx.result !== "SUCCESS") return { ok: false, detail: `result ${tx.result}` };
  if (proof.scheduled !== undefined && tx.scheduled !== proof.scheduled) {
    return { ok: false, detail: `scheduled is ${tx.scheduled}, expected ${proof.scheduled}` };
  }
  if (proof.topic0) {
    const logs = (await mirrorJson(`${MIRROR}/contracts/${proof.contract}/results/logs?timestamp=${proof.timestamp}&topic0=${proof.topic0}`))?.logs ?? [];
    const need = proof.minLogs ?? 1;
    if (logs.length < need) return { ok: false, detail: `${logs.length} ${proof.event ?? "matching"} log(s), expected ${need}` };
  }
  const what = [tx.scheduled ? "scheduled" : tx.name, proof.event ? `${proof.event} emitted` : null].filter(Boolean).join(", ");
  return { ok: true, detail: `SUCCESS, ${what}` };
}

async function checkTestnetProofs(allowPending) {
  if (!CONFIG.testnetProofs.length) {
    record("proof", "testnet transaction on mirror node", allowPending ? "pending" : "fail", "no testnetProofs in scripts/gate.config.json");
    return;
  }
  for (const proof of CONFIG.testnetProofs) {
    const { ok, detail } = await verifyProof(proof);
    record("proof", `${proof.description} (${proof.timestamp ?? proof.id})`, ok ? "pass" : "fail", detail);
  }
}

function checkHarness(src) {
  const dir = path.join(src, ".harness");
  if (!fs.existsSync(dir)) {
    record("source", "harness spec + validators", "skip", "no .harness/ directory");
    return;
  }
  const hasSpec = fs.existsSync(path.join(dir, "spec.yaml"));
  const hasValidators = fs.existsSync(path.join(dir, "validators")) && fs.readdirSync(path.join(dir, "validators")).length > 0;
  record("source", "harness spec + validators", hasSpec && hasValidators ? "pass" : "fail");
}

// ---------- scaffold matrix ----------

function scaffoldArgs(cliVersion, app, template, flags) {
  return ["create", `scaffold-hbar@${cliVersion}`, app, "--", "--template", template, "--network", "testnet", "--yes", ...flags];
}

function pmRun(pm, script) {
  return pm === "npm" ? ["npm", ["run", script]] : ["yarn", [script]];
}

async function freePort() {
  return new Promise(resolve => {
    const server = net.createServer();
    server.listen(0, () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function waitForHttp(url, timeoutMs, child) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) return false;
    try {
      await fetch(url, { signal: AbortSignal.timeout(60_000) });
      return true;
    } catch {
      await new Promise(r => setTimeout(r, 2000));
    }
  }
  return false;
}

async function checkBoot(scope, mode, pm, appDir, env, logFile) {
  const script = mode === "dev" ? "next:start" : "next:serve";
  const port = await freePort();
  const [cmd, args] = pmRun(pm, script);
  const { child } = spawnLogged(cmd, args, { cwd: appDir, env: { ...env, PORT: String(port) }, logFile });
  const base = `http://127.0.0.1:${port}`;
  try {
    if (!(await waitForHttp(base, 4 * MINUTE, child))) {
      record(scope, `boot (${mode})`, "fail", `${script} never answered on ${base}`);
      return;
    }
    for (const route of CONFIG.routes) {
      const res = await fetch(base + route, { signal: AbortSignal.timeout(3 * MINUTE) }).catch(err => ({ status: err.name }));
      const body = typeof res.text === "function" ? await res.text() : "";
      const broken = /Application error|Internal Server Error|Unhandled Runtime Error/.test(body);
      record(scope, `GET ${route} (${mode})`, res.status === 200 && !broken ? "pass" : "fail", `HTTP ${res.status}${broken ? ", error page rendered" : ""}`);
    }
  } finally {
    killTree(child);
  }
}

function lintWarnings(output) {
  const counted = [...output.matchAll(/(\d+)\s+warnings?\b/gi)].reduce((sum, m) => sum + Number(m[1]), 0);
  const listed = output.split("\n").filter(line => /^\s*\d+:\d+\s+warning\s/.test(line) || /^Warning: /.test(line)).length;
  return Math.max(counted, listed);
}

async function runCell({ framework, pm, template, cliVersion, workDir, env, opts, localTemplateDir }) {
  const scope = `${framework}+${pm}`;
  const cellDir = path.join(workDir, scope);
  fs.mkdirSync(cellDir, { recursive: true });
  const logFile = path.join(cellDir, "gate.log");
  const app = "gate-app";
  const appDir = path.join(cellDir, app);
  const cellEnv = localTemplateDir ? { ...env, CREATE_SCAFFOLD_HBAR_TEMPLATE_DIR: localTemplateDir } : env;
  console.log(`\n▸ ${scope} (log: ${logFile})`);

  const flags = ["--frontend", "nextjs-app", "--solidity-framework", framework, "--package-manager", pm];
  if (opts.skipSkills) flags.push("--skip-hedera-skills");
  const scaffold = await run("npm", scaffoldArgs(cliVersion, app, template, flags), {
    cwd: cellDir,
    env: cellEnv,
    logFile,
    timeoutMs: 30 * MINUTE,
  });
  if (scaffold.code !== 0 || !fs.existsSync(appDir)) {
    record(scope, "scaffold via CLI", "fail", tail(scaffold.output));
    return;
  }
  const softFailures = ["Format step failed", "Hedera Skills install exited", "not found on PATH"].filter(s => scaffold.output.includes(s));
  record(scope, "scaffold via CLI", softFailures.length ? "fail" : "pass", softFailures.join("; "));

  record(scope, "template.json consumed by CLI", fs.existsSync(path.join(appDir, "template.json")) ? "fail" : "pass");
  const other = framework === "foundry" ? "hardhat" : "foundry";
  record(scope, `unselected ${other} package removed`, fs.existsSync(path.join(appDir, "packages", other)) ? "fail" : "pass");

  const rootScripts = JSON.parse(fs.readFileSync(path.join(appDir, "package.json"), "utf8")).scripts ?? {};
  const steps = [
    { name: "lint", script: "lint", timeout: 10, warnings: true },
    { name: "type-check", script: "next:check-types", timeout: 10 },
    { name: "build", script: rootScripts.build ? "build" : "next:build", timeout: 20, warnings: true },
    { name: "contract tests", script: `${framework}:test`, timeout: 20 },
  ];
  let built = false;
  for (const step of steps) {
    if (!rootScripts[step.script]) {
      record(scope, step.name, "fail", `no root script "${step.script}"`);
      continue;
    }
    const [cmd, args] = pmRun(pm, step.script);
    const { code, output } = await run(cmd, args, { cwd: appDir, env, logFile, timeoutMs: step.timeout * MINUTE });
    if (code !== 0) {
      record(scope, `${step.name} (${step.script})`, "fail", tail(output));
      continue;
    }
    if (step.name === "build") built = true;
    const warnings = step.warnings ? lintWarnings(output) : 0;
    record(scope, `${step.name} (${step.script})`, warnings ? (opts.strict ? "fail" : "warn") : "pass", warnings ? `${warnings} warning(s)` : "");
  }

  // Production first: `next dev` rewrites .next and would discard the build.
  if (built) await checkBoot(scope, "production", pm, appDir, env, logFile);
  else record(scope, "boot (production)", "fail", "build failed, nothing to serve");
  await checkBoot(scope, "dev", pm, appDir, env, logFile);

  await secretScan(scope, ["detect", "--source", appDir], logFile, env);
}

async function checkCapabilitiesHonoured({ manifest, template, cliVersion, workDir, env }) {
  const caps = manifest?.["create-scaffold-hbar"]?.capabilities ?? {};
  const flagFor = { frontend: "--frontend", solidityFramework: "--solidity-framework", packageManager: "--package-manager" };
  const forbidden = Object.entries(MANIFEST_ENUMS)
    .map(([key, all]) => [key, all.find(v => caps[key] && !caps[key].includes(v))])
    .find(([, value]) => value);
  if (!forbidden) {
    record("remote", "CLI honours manifest capabilities", "skip", "manifest restricts nothing, so there is nothing to prove");
    return;
  }
  const limit = await fetch("https://api.github.com/rate_limit").then(r => r.json()).catch(() => null);
  if ((limit?.resources?.core?.remaining ?? 0) < 3) {
    record("remote", "CLI honours manifest capabilities", "fail", "GitHub anonymous rate limit exhausted; rerun later");
    return;
  }
  const [key, value] = forbidden;
  const cellDir = path.join(workDir, "capabilities");
  fs.mkdirSync(cellDir, { recursive: true });
  const { code, output } = await run(
    "npm",
    scaffoldArgs(cliVersion, "gate-neg", template, [flagFor[key], value, "--skip-install", "--skip-hedera-skills"]),
    { cwd: cellDir, env, logFile: path.join(cellDir, "gate.log"), timeoutMs: 5 * MINUTE },
  );
  const rejected = code !== 0 && output.includes("does not support");
  record("remote", "CLI honours manifest capabilities", rejected ? "pass" : "fail", rejected ? `${key}=${value} rejected as expected` : `CLI accepted ${key}=${value}: manifest was not applied`);
}

// ---------- main ----------

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.proofsOnly) {
    await checkTestnetProofs(false);
    process.exit(results.some(r => r.status === "fail") ? 1 : 0);
  }
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "scaffold-hbar-gate-"));
  const binDir = path.join(workDir, "bin");
  fs.mkdirSync(binDir);
  const env = baseEnv(workDir, binDir);
  const template = opts.template ?? originTemplate();
  const ref = parseTemplateRef(template);
  console.log(`Gate check: ${template}${opts.local ? " (local working tree)" : ""}\nWorkspace: ${workDir}`);

  record("env", `node ${process.version} >= ${MIN_NODE.join(".")}`, versionAtLeast(process.version, MIN_NODE) ? "pass" : "fail");
  const cliVersion = opts.cliVersion ?? execFileSync("npm", ["view", "create-scaffold-hbar", "version"], { encoding: "utf8" }).trim();
  record("env", `create-scaffold-hbar@${cliVersion}`, cliVersion === SCHEMA_CLI_VERSION ? "pass" : "warn", cliVersion === SCHEMA_CLI_VERSION ? "" : `schema mirror written for ${SCHEMA_CLI_VERSION}; re-read src/types.ts`);

  const srcDir = path.join(workDir, "source");
  const logFile = path.join(workDir, "source.log");
  let trackedFiles;
  if (opts.local) {
    exportWorkingTree(srcDir);
    trackedFiles = execFileSync("git", ["ls-files"], { cwd: REPO_ROOT, encoding: "utf8" }).split("\n");
    await secretScan("source", ["detect", "--source", REPO_ROOT], logFile, env);
    await secretScan("source", ["detect", "--no-git", "--source", srcDir], logFile, env);
  } else {
    const url = `https://github.com/${ref.owner}/${ref.repo}.git`;
    const clone = await run("git", ["clone", "--quiet", url, srcDir], { cwd: workDir, env, logFile, timeoutMs: 10 * MINUTE });
    if (clone.code !== 0) throw new Error(`clone failed: ${tail(clone.output, 5)}`);
    if (ref.ref) execFileSync("git", ["checkout", "--quiet", ref.ref], { cwd: srcDir, env });
    trackedFiles = execFileSync("git", ["ls-files"], { cwd: srcDir, encoding: "utf8" }).split("\n");
    await secretScan("source", ["detect", "--source", srcDir], logFile, env);
    await checkManifestReachable(ref);
  }

  checkFiles(srcDir);
  const manifest = checkManifest(srcDir);
  checkNoEnvFiles(srcDir, trackedFiles);
  checkHarness(srcDir);
  await checkTestnetProofs(opts.allowPendingProof);

  const caps = manifest?.["create-scaffold-hbar"]?.capabilities ?? {};
  const frameworks = opts.frameworks ?? (caps.solidityFramework ?? ["foundry", "hardhat"]).filter(fw => fw !== "none");
  const pms = opts.pms ?? (caps.packageManager ?? ["yarn", "npm"]).filter(pm => pm !== "none");

  if (!opts.local) await checkCapabilitiesHonoured({ manifest, template, cliVersion, workDir, env });

  if (pms.includes("yarn")) record("env", "yarn available (corepack shim if needed)", ensureYarn(binDir) ? "pass" : "fail");
  if (frameworks.includes("foundry")) record("env", "forge on PATH", which("forge") ? "pass" : "fail");
  await checkLockfiles(srcDir, pms, env, logFile);

  for (const framework of frameworks) {
    for (const pm of pms) {
      await runCell({ framework, pm, template, cliVersion, workDir, env, opts, localTemplateDir: opts.local ? srcDir : undefined });
    }
  }

  const failed = results.filter(r => r.status === "fail" || (r.status === "pending" && !opts.allowPendingProof));
  const reportFile = path.join(REPO_ROOT, ".gate", "report.json");
  fs.mkdirSync(path.dirname(reportFile), { recursive: true });
  fs.writeFileSync(reportFile, JSON.stringify({ template, local: opts.local, cliVersion, results }, null, 2));
  console.log(`\n${results.length} checks, ${failed.length} failing. Report: ${reportFile}`);
  for (const r of failed) console.log(`  ✗ ${r.scope} · ${r.check}`);

  if (!opts.keep && failed.length === 0) fs.rmSync(workDir, { recursive: true, force: true });
  else console.log(`Workspace kept at ${workDir}`);
  process.exitCode = failed.length ? 1 : 0;
}

main().catch(err => {
  console.error(`gate-check crashed: ${err.stack ?? err}`);
  killAll();
  process.exitCode = 2;
});
