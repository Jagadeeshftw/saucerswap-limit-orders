#!/usr/bin/env node
// Generates docs/CONTRACT-API.md, the contract API reference, from the NatSpec in the Foundry build artifacts.
//
//   node scripts/gen-contract-api.mjs           write docs/CONTRACT-API.md
//   node scripts/gen-contract-api.mjs --check   exit 1 if docs/CONTRACT-API.md is out of date
//
// Input is packages/foundry/out/<File>.sol/<Contract>.json, which carries the AST because foundry.toml sets
// `ast = true`. Signatures, NatSpec, structs, enums, selectors and library call sites all come from that AST;
// members a contract inherits (OpenZeppelin's) are looked up in the ASTs of the files it imports. Deployed
// addresses come from packages/nextjs/contracts/deployedContracts.ts. Nothing is fetched from the network.
//
// The output is deterministic: contracts in the fixed order below, members in source order, no timestamps or
// absolute paths, so the CI check's diff is meaningful.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const FOUNDRY = path.join(ROOT, "packages", "foundry");
const OUT = path.join(FOUNDRY, "out");
const DOC_REL = "docs/CONTRACT-API.md";
const DOC = path.join(ROOT, DOC_REL);
const DEPLOYED = path.join(ROOT, "packages", "nextjs", "contracts", "deployedContracts.ts");
const COMMAND = "node scripts/gen-contract-api.mjs";

// The contracts documented, in page order.
const TARGETS = [
  "OrderVault",
  "OrderVaultLens",
  "LimitOrderType",
  "StopOrderType",
  "TrailingStopType",
  "IOrderType",
  "MarketGuard",
  "MarketRegistry",
  "OrderCollection",
  "Settlement",
  "SweepMath",
  "PriceMath",
];
// File-level types (structs, enums, errors) shared by the contracts above.
const SHARED_SOURCE = "contracts/types/OrderTypes.sol";

const NETWORKS = {
  295: { label: "Hedera mainnet", hashscan: "mainnet" },
  296: { label: "Hedera testnet", hashscan: "testnet" },
};

// ---------------------------------------------------------------------------------------------------------------
// Artifacts
// ---------------------------------------------------------------------------------------------------------------

function fail(message) {
  console.error(`gen-contract-api: ${message}`);
  process.exit(1);
}

const readJson = file => JSON.parse(fs.readFileSync(file, "utf8"));

function requireAst(artifact, file) {
  if (!artifact.ast) {
    fail(
      `${path.relative(ROOT, file)} has no AST. Build the contracts with \`ast = true\` in ` +
        "packages/foundry/foundry.toml (run `forge build` in packages/foundry), then rerun.",
    );
  }
  return artifact;
}

const unitCache = new Map();

/** The artifact of the source unit at `absolutePath` (as solc names it), or null if it was not built. */
function loadUnit(absolutePath) {
  if (unitCache.has(absolutePath)) return unitCache.get(absolutePath);
  const dir = path.join(OUT, path.basename(absolutePath));
  let found = null;
  if (fs.existsSync(dir)) {
    for (const file of fs.readdirSync(dir).sort()) {
      if (!file.endsWith(".json")) continue;
      const full = path.join(dir, file);
      const artifact = readJson(full);
      requireAst(artifact, full);
      if (artifact.ast.absolutePath === absolutePath) {
        found = artifact;
        break;
      }
    }
  }
  unitCache.set(absolutePath, found);
  return found;
}

/** The artifact of a contract in this repo's contracts/ by name. */
function loadContractArtifact(name) {
  if (!fs.existsSync(OUT)) {
    fail("packages/foundry/out does not exist. Run `forge build` in packages/foundry first.");
  }
  const hits = [];
  for (const dir of fs.readdirSync(OUT).sort()) {
    const file = path.join(OUT, dir, `${name}.json`);
    if (!fs.existsSync(file)) continue;
    const artifact = requireAst(readJson(file), file);
    if (artifact.ast.absolutePath.startsWith("contracts/")) hits.push(artifact);
  }
  if (hits.length !== 1) fail(`expected one artifact for ${name} under packages/foundry/out, found ${hits.length}.`);
  unitCache.set(hits[0].ast.absolutePath, hits[0]);
  return hits[0];
}

function walk(node, visit, parents = []) {
  if (!node || typeof node !== "object") return;
  if (Array.isArray(node)) {
    for (const child of node) walk(child, visit, parents);
    return;
  }
  if (node.nodeType) visit(node, parents);
  const next = node.nodeType ? [...parents, node] : parents;
  for (const key of Object.keys(node)) {
    if (key === "documentation") continue;
    const value = node[key];
    if (value && typeof value === "object") walk(value, visit, next);
  }
}

/** Every source unit reachable through imports from `artifact`, depth first, in import order. */
function reachableUnits(artifact) {
  const seen = new Set();
  const units = [];
  const visit = unit => {
    if (!unit || seen.has(unit.ast.absolutePath)) return;
    seen.add(unit.ast.absolutePath);
    units.push(unit);
    for (const node of unit.ast.nodes) {
      if (node.nodeType === "ImportDirective") visit(loadUnit(node.absolutePath));
    }
  };
  visit(artifact);
  return units;
}

// ---------------------------------------------------------------------------------------------------------------
// NatSpec
// ---------------------------------------------------------------------------------------------------------------

const clean = text => text.replace(/\s+/g, " ").trim();

function parseDoc(node) {
  const raw = node?.documentation;
  const text = typeof raw === "string" ? raw : (raw?.text ?? "");
  const doc = { notice: [], dev: [], params: {}, returns: [], custom: {}, inheritdoc: null };
  let current = null;
  for (const rawLine of text.split("\n")) {
    const line = rawLine.replace(/^\s*\*(?!\*)\s?/, "").trim();
    const tag = line.match(/^@([a-z]+(?::[a-z0-9-]+)?)\s*(.*)$/);
    if (tag) {
      const [, name, rest] = tag;
      current = { text: rest };
      if (name === "notice") doc.notice.push(current);
      else if (name === "dev") doc.dev.push(current);
      else if (name === "return") doc.returns.push(current);
      else if (name === "param") {
        const [param, ...words] = rest.split(/\s+/);
        current = { text: words.join(" ") };
        doc.params[param] = current;
      } else if (name === "inheritdoc") {
        doc.inheritdoc = rest.trim();
        current = null;
      } else if (name.startsWith("custom:")) {
        doc.custom[name.slice("custom:".length)] = current;
      } else {
        current = { text: rest }; // @title, @author: not rendered
      }
    } else if (line) {
      if (!current) {
        current = { text: line };
        doc.notice.push(current);
      } else {
        current.text += ` ${line}`;
      }
    }
  }
  return {
    notice: clean(doc.notice.map(n => n.text).join(" ")),
    dev: doc.dev.map(d => clean(d.text)).filter(Boolean),
    params: Object.fromEntries(Object.entries(doc.params).map(([k, v]) => [k, clean(v.text)])),
    returns: doc.returns.map(r => clean(r.text)),
    custom: Object.fromEntries(Object.entries(doc.custom).map(([k, v]) => [k, clean(v.text)])),
    inheritdoc: doc.inheritdoc,
  };
}

/** A function's NatSpec with `@inheritdoc Base` filled in from Base's function of the same name. */
function functionDoc(fn, units) {
  const own = parseDoc(fn);
  if (!own.inheritdoc) return own;
  const base = findContract(own.inheritdoc, units);
  const inherited = base?.node.nodes.find(n => n.nodeType === "FunctionDefinition" && n.name === fn.name);
  if (!inherited) return own;
  const from = parseDoc(inherited);
  return {
    notice: own.notice || from.notice,
    dev: own.dev.length ? own.dev : from.dev,
    params: { ...from.params, ...own.params },
    returns: own.returns.length ? own.returns : from.returns,
    custom: { ...from.custom, ...own.custom },
    inheritdoc: null,
  };
}

// ---------------------------------------------------------------------------------------------------------------
// Types and signatures
// ---------------------------------------------------------------------------------------------------------------

function typeName(t) {
  if (!t) return "";
  switch (t.nodeType) {
    case "ElementaryTypeName":
      return t.stateMutability === "payable" ? `${t.name} payable` : t.name;
    case "UserDefinedTypeName":
      return t.pathNode?.name ?? t.name;
    case "ArrayTypeName":
      return `${typeName(t.baseType)}[${t.length ? expr(t.length) : ""}]`;
    case "Mapping": {
      const key = typeName(t.keyType) + (t.keyName ? ` ${t.keyName}` : "");
      const value = typeName(t.valueType) + (t.valueName ? ` ${t.valueName}` : "");
      return `mapping(${key} => ${value})`;
    }
    default:
      return t.typeDescriptions?.typeString ?? t.nodeType;
  }
}

/** Source-like rendering of the constant expressions used in declarations. */
function expr(e) {
  if (!e) return "";
  switch (e.nodeType) {
    case "Literal": {
      const value = e.kind === "string" ? JSON.stringify(e.value) : e.value;
      return e.subdenomination ? `${value} ${e.subdenomination}` : value;
    }
    case "Identifier":
      return e.name;
    case "ElementaryTypeNameExpression":
      return typeName(e.typeName);
    case "MemberAccess":
      return `${expr(e.expression)}.${e.memberName}`;
    case "BinaryOperation":
      return `${expr(e.leftExpression)} ${e.operator} ${expr(e.rightExpression)}`;
    case "UnaryOperation":
      return e.prefix ? `${e.operator}${expr(e.subExpression)}` : `${expr(e.subExpression)}${e.operator}`;
    case "FunctionCall":
      return `${expr(e.expression)}(${e.arguments.map(expr).join(", ")})`;
    case "TupleExpression":
      return `(${e.components.map(expr).join(", ")})`;
    default:
      return e.typeDescriptions?.typeString ?? e.nodeType;
  }
}

function variable(v, { withLocation = true, withName = true } = {}) {
  let out = typeName(v.typeName);
  if (withLocation && v.storageLocation && v.storageLocation !== "default") out += ` ${v.storageLocation}`;
  if (v.indexed) out += " indexed";
  if (withName && v.name) out += ` ${v.name}`;
  return out;
}

const paramList = list => list.parameters.map(p => variable(p)).join(", ");

function functionSignature(fn) {
  const head = fn.kind === "function" ? `function ${fn.name}` : fn.kind;
  const parts = [`${head}(${paramList(fn.parameters)})`];
  if (fn.kind !== "constructor") parts.push(fn.visibility);
  if (fn.stateMutability !== "nonpayable") parts.push(fn.stateMutability);
  for (const m of fn.modifiers ?? []) {
    if (m.kind === "baseConstructorSpecifier") continue;
    const name = m.modifierName.name ?? m.modifierName.namePath;
    parts.push(m.arguments?.length ? `${name}(${m.arguments.map(expr).join(", ")})` : name);
  }
  if (fn.returnParameters?.parameters.length) parts.push(`returns (${paramList(fn.returnParameters)})`);
  return parts.join(" ");
}

function stateVarDeclaration(v) {
  let out = `${typeName(v.typeName)} ${v.visibility}`;
  if (v.constant) out += " constant";
  if (v.mutability === "immutable") out += " immutable";
  out += ` ${v.name}`;
  if (v.constant && v.value) out += ` = ${expr(v.value)}`;
  return out;
}

const eventSignature = e => `event ${e.name}(${paramList(e.parameters)})${e.anonymous ? " anonymous" : ""}`;
const errorSignature = e => `error ${e.name}(${paramList(e.parameters)})`;

function structDefinition(s) {
  const members = s.members.map(m => `    ${variable(m, { withLocation: false })};`);
  return [`struct ${s.name} {`, ...members, "}"].join("\n");
}

const enumDefinition = e => [`enum ${e.name} {`, e.members.map(m => `    ${m.name}`).join(",\n"), "}"].join("\n");

/** The base type name a parameter's type refers to, for linking (`PlaceParams`, `SweepMath.ChargeInput`). */
function userTypeOf(t) {
  if (!t) return null;
  if (t.nodeType === "UserDefinedTypeName") return t.pathNode?.name ?? t.name;
  if (t.nodeType === "ArrayTypeName") return userTypeOf(t.baseType);
  return null;
}

// ---------------------------------------------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------------------------------------------

function contractNode(unit, name) {
  return unit.ast.nodes.find(n => n.nodeType === "ContractDefinition" && n.name === name);
}

function findContract(name, units) {
  for (const unit of units) {
    const node = contractNode(unit, name);
    if (node) return { unit, node };
  }
  return null;
}

/** C3 linearization by contract name, most derived first. */
function linearize(name, units, memo = new Map()) {
  if (memo.has(name)) return memo.get(name);
  const found = findContract(name, units);
  const bases = found ? found.node.baseContracts.map(b => b.baseName.name ?? b.baseName.namePath) : [];
  // Solidity lists bases from most base-like to most derived; C3 merges them right to left.
  const sequences = [...bases].reverse().map(b => [...linearize(b, units, memo)]);
  sequences.push([...bases].reverse());
  const result = [name];
  while (sequences.some(s => s.length)) {
    const candidate = sequences
      .filter(s => s.length)
      .map(s => s[0])
      .find(c => !sequences.some(s => s.indexOf(c) > 0));
    if (!candidate) break;
    result.push(candidate);
    for (const s of sequences) if (s[0] === candidate) s.shift();
  }
  memo.set(name, result);
  return result;
}

function accessOf(fn, doc) {
  const modifiers = (fn.modifiers ?? []).map(m => m.modifierName.name ?? m.modifierName.namePath);
  if (modifiers.includes("onlyOwner")) return "Owner only (`onlyOwner`)";
  if (doc.custom.access) return doc.custom.access;
  if (fn.stateMutability === "view" || fn.stateMutability === "pure") return "Anyone (read-only)";
  return "Anyone";
}

function splitReverts(doc, fn) {
  const reverts = doc.dev.filter(d => /^Reverts\b/.test(d)).map(d => d.replace(/^Reverts\s+/, ""));
  const dev = doc.dev.filter(d => !/^Reverts\b/.test(d));
  const modifiers = (fn?.modifiers ?? []).map(m => m.modifierName.name ?? m.modifierName.namePath);
  if (modifiers.includes("onlyOwner")) reverts.unshift("`OwnableUnauthorizedAccount` if the caller is not the owner.");
  return { reverts, dev };
}

function paramsOf(list, doc, { returns = false } = {}) {
  return list.parameters.map((p, i) => {
    let text;
    if (returns) {
      text = doc.returns[i] ?? "";
      if (p.name && text.split(" ")[0] === p.name) text = text.slice(p.name.length).trim();
    } else {
      text = p.name ? (doc.params[p.name] ?? "") : "Unused by this type.";
    }
    return { name: p.name, type: variable(p, { withName: false }), userType: userTypeOf(p.typeName), text };
  });
}

function buildFunction(fn, ctx) {
  const doc = functionDoc(fn, ctx.units);
  const { reverts, dev } = splitReverts(doc, fn);
  const selector = fn.functionSelector ? `0x${fn.functionSelector}` : null;
  return {
    key: `${ctx.name}.fn.${fn.name}`,
    name: fn.kind === "function" ? fn.name : fn.kind,
    signature: functionSignature(fn),
    visibility: fn.visibility,
    mutability: fn.stateMutability,
    access: ctx.kind === "library" || fn.kind === "constructor" ? null : accessOf(fn, doc),
    selector: ctx.kind === "library" ? null : selector,
    abiSignature: selector && ctx.kind !== "library" ? ctx.selectorToSig[fn.functionSelector] : null,
    notice: doc.notice,
    dev,
    params: paramsOf(fn.parameters, doc),
    returns: paramsOf(fn.returnParameters, doc, { returns: true }),
    reverts,
    node: fn,
  };
}

function buildEvent(e, owner) {
  const doc = parseDoc(e);
  return {
    key: `${owner}.event.${e.name}`,
    name: e.name,
    signature: eventSignature(e),
    topic: e.eventSelector ? `0x${e.eventSelector}` : null,
    notice: doc.notice,
    dev: doc.dev,
    fields: e.parameters.parameters.map(p => ({
      name: p.name,
      type: typeName(p.typeName),
      userType: userTypeOf(p.typeName),
      indexed: p.indexed,
      text: doc.params[p.name] ?? "",
    })),
  };
}

function buildError(e, owner) {
  const doc = parseDoc(e);
  return {
    key: `${owner}.error.${e.name}`,
    name: e.name,
    signature: errorSignature(e),
    selector: e.errorSelector ? `0x${e.errorSelector}` : null,
    notice: doc.notice,
    dev: doc.dev,
    params: e.parameters.parameters.map(p => ({
      name: p.name,
      type: typeName(p.typeName),
      userType: userTypeOf(p.typeName),
      text: doc.params[p.name] ?? "",
    })),
  };
}

function buildStruct(s, owner) {
  const doc = parseDoc(s);
  return {
    key: `type.${s.canonicalName ?? s.name}`,
    owner,
    name: s.name,
    kind: "struct",
    definition: structDefinition(s),
    notice: doc.notice,
    dev: doc.dev,
    fields: s.members.map(m => ({
      name: m.name,
      type: typeName(m.typeName),
      userType: userTypeOf(m.typeName),
      text: doc.params[m.name] ?? "",
    })),
  };
}

function buildEnum(e, owner) {
  const doc = parseDoc(e);
  return {
    key: `type.${e.canonicalName ?? e.name}`,
    owner,
    name: e.name,
    kind: "enum",
    definition: enumDefinition(e),
    notice: doc.notice,
    dev: doc.dev,
    values: e.members.map((m, i) => ({ index: i, name: m.name, text: doc.params[m.name] ?? "" })),
  };
}

function buildStateVar(v, owner) {
  const doc = parseDoc(v);
  return {
    key: `${owner}.var.${v.name}`,
    name: v.name,
    declaration: stateVarDeclaration(v),
    selector: v.functionSelector ? `0x${v.functionSelector}` : null,
    text: [doc.notice, ...doc.dev].filter(Boolean).join(" "),
  };
}

function buildContract(name) {
  const artifact = loadContractArtifact(name);
  const units = reachableUnits(artifact);
  const node = contractNode(artifact, name);
  if (!node) fail(`no contract ${name} in ${artifact.ast.absolutePath}.`);
  const selectorToSig = Object.fromEntries(Object.entries(artifact.methodIdentifiers ?? {}).map(([s, id]) => [id, s]));
  const ctx = { name, kind: node.contractKind, units, selectorToSig };
  const doc = parseDoc(node);
  const isLibrary = node.contractKind === "library";

  const members = node.nodes;
  const functions = members
    .filter(n => n.nodeType === "FunctionDefinition")
    .filter(n => isLibrary || n.kind !== "function" || n.visibility === "public" || n.visibility === "external")
    .map(fn => buildFunction(fn, ctx));
  const stateVars = members
    .filter(n => n.nodeType === "VariableDeclaration" && n.visibility === "public")
    .map(v => buildStateVar(v, name));
  const constants = isLibrary
    ? members.filter(n => n.nodeType === "VariableDeclaration" && n.constant).map(v => buildStateVar(v, name))
    : [];
  const events = members.filter(n => n.nodeType === "EventDefinition").map(e => buildEvent(e, name));
  const errors = members.filter(n => n.nodeType === "ErrorDefinition").map(e => buildError(e, name));
  // A contract's own structs are internal working state (OrderVault.Pass); a library's are part of its API.
  const types = members
    .filter(n => isLibrary || node.contractKind === "interface")
    .filter(n => n.nodeType === "StructDefinition" || n.nodeType === "EnumDefinition")
    .map(t => (t.nodeType === "StructDefinition" ? buildStruct(t, name) : buildEnum(t, name)));

  // ABI members declared elsewhere: inherited (looked up in C3 order) or, for errors, file-level or library errors.
  const own = {
    function: new Set(functions.map(f => f.selector).filter(Boolean)),
    event: new Set(events.map(e => e.topic)),
    error: new Set(errors.map(e => e.selector)),
  };
  for (const v of stateVars) if (v.selector) own.function.add(v.selector);
  const bases = linearize(name, units)
    .slice(1)
    .map(b => findContract(b, units))
    .filter(Boolean);
  const inherited = { functions: [], events: [], errors: [] };
  const externalErrors = [];
  const abiSelector = item => {
    const sig = `${item.name}(${item.inputs.map(abiType).join(",")})`;
    return { sig, item };
  };
  for (const item of artifact.abi) {
    if (item.type === "function") {
      const { sig } = abiSelector(item);
      const id = artifact.methodIdentifiers?.[sig];
      if (!id || own.function.has(`0x${id}`)) continue;
      for (const base of bases) {
        const fn = base.node.nodes.find(n => n.nodeType === "FunctionDefinition" && n.functionSelector === id);
        if (fn) {
          const baseCtx = { ...ctx, name: base.node.name };
          inherited.functions.push({ from: base.node.name, ...buildFunction(fn, baseCtx), key: `${name}.fn.${fn.name}` });
          break;
        }
      }
    } else if (item.type === "event") {
      const found = findDeclaration(bases.map(b => b.node), "EventDefinition", item.name);
      if (found && !own.event.has(`0x${found.node.eventSelector}`)) {
        inherited.events.push({ from: found.owner, ...buildEvent(found.node, name) });
      }
    } else if (item.type === "error") {
      if (errors.some(e => e.name === item.name)) continue;
      const fromBases = findDeclaration(
        bases.map(b => b.node),
        "ErrorDefinition",
        item.name,
      );
      const found = fromBases ?? findDeclaration(units.map(u => u.ast), "ErrorDefinition", item.name);
      if (!found) continue;
      externalErrors.push({ name: item.name, owner: found.owner, node: found.node });
    }
  }

  return {
    name,
    kind: node.contractKind,
    source: `packages/foundry/${artifact.ast.absolutePath}`,
    bases: node.baseContracts.map(b => b.baseName.name ?? b.baseName.namePath),
    doc,
    functions,
    stateVars,
    constants,
    events,
    errors,
    types,
    inherited,
    externalErrors,
    linked: isLibrary && functions.some(f => f.visibility === "external" || f.visibility === "public"),
    node,
    artifact,
  };
}

function abiType(input) {
  if (input.type.startsWith("tuple")) return `(${input.components.map(abiType).join(",")})${input.type.slice(5)}`;
  return input.type;
}

/** The first declaration of `nodeType` named `name` in `containers` (contracts or source units). */
function findDeclaration(containers, nodeType, name) {
  for (const container of containers) {
    const isUnit = container.nodeType === "SourceUnit";
    for (const n of container.nodes) {
      if (n.nodeType === nodeType && n.name === name) {
        return { owner: isUnit ? `file ${path.basename(container.absolutePath)}` : container.name, node: n };
      }
      if (isUnit && n.nodeType === "ContractDefinition") {
        const inner = n.nodes.find(m => m.nodeType === nodeType && m.name === name);
        if (inner) return { owner: n.name, node: inner };
      }
    }
  }
  return null;
}

function buildShared() {
  const artifact = loadUnit(SHARED_SOURCE);
  if (!artifact) fail(`no artifact for ${SHARED_SOURCE}; run \`forge build\` in packages/foundry.`);
  const nodes = artifact.ast.nodes;
  return {
    source: `packages/foundry/${SHARED_SOURCE}`,
    types: nodes
      .filter(n => n.nodeType === "StructDefinition" || n.nodeType === "EnumDefinition")
      .map(t => (t.nodeType === "StructDefinition" ? buildStruct(t, null) : buildEnum(t, null))),
    errors: nodes.filter(n => n.nodeType === "ErrorDefinition").map(e => buildError(e, "shared")),
    ast: artifact.ast,
  };
}

/** Where each library function is called from, as `Contract.function`, in page order. */
function callSites(contracts) {
  const sites = new Map();
  const add = (key, where) => {
    if (!sites.has(key)) sites.set(key, []);
    if (!sites.get(key).includes(where)) sites.get(key).push(where);
  };
  const libraries = new Map(contracts.filter(c => c.kind === "library").map(c => [c.name, c]));
  for (const c of contracts) {
    walk(c.node, (n, parents) => {
      const fn = [...parents].reverse().find(p => p.nodeType === "FunctionDefinition");
      const where = `${c.name}.${fn ? (fn.kind === "function" ? fn.name : fn.kind) : "(declarations)"}`;
      if (n.nodeType === "MemberAccess" && n.expression?.nodeType === "Identifier") {
        const lib = libraries.get(n.expression.name);
        if (lib && lib.name !== c.name && lib.functions.some(f => f.node.name === n.memberName)) {
          add(`${lib.name}.fn.${n.memberName}`, where);
        }
      }
      if (n.nodeType === "Identifier" && c.kind === "library") {
        const target = c.functions.find(f => f.node.id === n.referencedDeclaration);
        if (target) add(`${c.name}.fn.${target.node.name}`, where);
      }
    });
  }
  return sites;
}

// ---------------------------------------------------------------------------------------------------------------
// Deployments
// ---------------------------------------------------------------------------------------------------------------

function deployments() {
  if (!fs.existsSync(DEPLOYED)) return {};
  const text = fs.readFileSync(DEPLOYED, "utf8");
  const chains = [...text.matchAll(/^ {2}(\d+): \{/gm)].map(m => ({ id: Number(m[1]), at: m.index }));
  const found = {};
  for (const m of text.matchAll(/^ {4}(\w+): \{\s*address: "(0x[0-9a-fA-F]{40})"/gm)) {
    const chain = chains.filter(c => c.at < m.index).pop();
    if (!chain) continue;
    (found[m[1]] ??= []).push({ chainId: chain.id, address: m[2].toLowerCase() });
  }
  return found;
}

// ---------------------------------------------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------------------------------------------

/** Prose that renders the same on GitHub and in MDX: no raw JSX characters outside code spans. */
function md(text, { table = false } = {}) {
  const out = text
    .split(/(`[^`]*`)/)
    .map((part, i) => {
      if (i % 2 === 1) return part;
      return part
        .replace(/\{([A-Za-z_][\w.-]*)\}/g, "`$1`") // OpenZeppelin cross-references: {acceptOwnership}
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/\{/g, "&#123;")
        .replace(/\}/g, "&#125;");
    })
    .join("");
  return table ? out.replace(/\|/g, "\\|") : out;
}

const code = text => `\`${text}\``;
const cell = text => (text ? md(text, { table: true }) : "–");

class Slugger {
  constructor() {
    this.seen = new Map();
  }
  slug(text) {
    const base = text
      .toLowerCase()
      .replace(/[^a-z0-9 _-]/g, "")
      .replace(/ /g, "-");
    let slug = base;
    while (this.seen.has(slug)) {
      const n = this.seen.get(base) + 1;
      this.seen.set(base, n);
      slug = `${base}-${n}`;
    }
    this.seen.set(slug, 0);
    return slug;
  }
}

function render(model, anchors) {
  const lines = [];
  const slugger = new Slugger();
  const found = new Map();
  const push = (...l) => lines.push(...l);
  const heading = (level, text, key) => {
    const slug = slugger.slug(text);
    if (key) found.set(key, slug);
    push(`${"#".repeat(level)} ${text}`, "");
  };
  const link = (label, key) => (anchors.has(key) ? `[${label}](#${anchors.get(key)})` : label);
  const typeLink = (type, userType) => {
    if (!userType) return code(type);
    const key = model.typeKeys.get(userType);
    if (!key) return code(type);
    return `[${code(type)}](#${anchors.get(key) ?? ""})`;
  };
  const errorKey = (name, contract) => {
    const candidates = [
      `${contract.name}.error.${name}`,
      `shared.error.${name}`,
      ...model.contracts.map(c => `${c.name}.error.${name}`),
      ...model.contracts.map(c => `${c.name}.inherited-error.${name}`),
    ];
    return candidates.find(k => anchors.has(k));
  };
  const revertLine = (text, contract) => {
    const linked = text.replace(/`([A-Za-z_]\w*)`/g, (whole, name) => {
      const key = errorKey(name, contract);
      return key && /^[A-Z]/.test(name) ? `[${whole}](#${anchors.get(key)})` : whole;
    });
    return `- ${md(linked)}`;
  };
  const paragraphs = (...texts) => {
    for (const t of texts.flat()) if (t) push(md(t), "");
  };
  const table = (header, rows) => {
    if (!rows.length) return;
    push(`| ${header.join(" | ")} |`, `| ${header.map(() => "---").join(" | ")} |`);
    for (const row of rows) push(`| ${row.join(" | ")} |`);
    push("");
  };
  const block = text => push("```solidity", text, "```", "");

  // Header
  push("# Contract API", "");
  push(`> Generated by \`${COMMAND}\` from NatSpec; do not edit by hand.`, "");
  push(
    "Every public and external function, event, custom error, struct and enum of the vault, its lens, the order " +
      "types and the libraries, read from the NatSpec in the Foundry build artifacts. Members appear in source " +
      "order. Prices are quote per 1 base with 8 decimals; HBAR amounts are tinybar; bps are basis points.",
    "",
  );
  heading(2, "Contents");
  for (const c of model.contracts) push(`- [${c.name}](#${anchors.get(`${c.name}`) ?? ""}) (${c.kind})`);
  push(`- [Shared types](#${anchors.get("shared") ?? ""}) (\`OrderTypes.sol\`)`);
  push("");

  for (const c of model.contracts) {
    heading(2, c.name, c.name);
    const facts = [`Source: ${code(c.source)}`];
    const kindLine = {
      contract: null,
      interface: "Interface",
      library: c.linked
        ? "External library: deployed once and linked; its external functions run by DELEGATECALL in the caller's context"
        : "Internal library: compiled into each contract that uses it",
    }[c.kind];
    if (kindLine) facts.push(kindLine);
    const isInterface = b => model.contracts.some(o => o.name === b && o.kind === "interface");
    const named = list => list.map(b => (anchors.has(b) ? link(code(b), b) : code(b))).join(", ");
    const parents = c.bases.filter(b => !isInterface(b));
    const interfaces = c.bases.filter(isInterface);
    if (parents.length) facts.push(`Inherits ${named(parents)}`);
    if (interfaces.length) facts.push(`Implements ${named(interfaces)}`);
    const implementers = model.contracts.filter(o => o.bases.includes(c.name)).map(o => link(code(o.name), o.name));
    if (implementers.length) facts.push(`Implemented by ${implementers.join(", ")}`);
    for (const d of model.deployed[c.name] ?? []) {
      const net = NETWORKS[d.chainId];
      const label = net ? net.label : `chain ${d.chainId}`;
      const url = net ? `https://hashscan.io/${net.hashscan}/contract/${d.address}` : null;
      facts.push(`${label}: ${url ? `[${code(d.address)}](${url})` : code(d.address)}`);
    }
    for (const f of facts) push(`- ${f}`);
    push("");
    paragraphs(c.doc.notice, c.doc.dev);

    if (c.stateVars.length) {
      heading(3, "Public variables");
      table(
        ["Name", "Declaration", "Description"],
        c.stateVars.map(v => [code(v.name), md(code(v.declaration), { table: true }), cell(v.text)]),
      );
    }
    if (c.constants.length) {
      heading(3, "Constants");
      table(
        ["Name", "Declaration", "Description"],
        c.constants.map(v => [code(v.name), md(code(v.declaration), { table: true }), cell(v.text)]),
      );
    }

    if (c.functions.length) {
      heading(3, "Functions");
      for (const f of c.functions) renderFunction(f, c, `${c.name}.fn.${f.node.name}`);
    }
    if (c.events.length) {
      heading(3, "Events");
      for (const e of c.events) renderEvent(e);
    }
    if (c.errors.length) {
      heading(3, "Errors");
      for (const e of c.errors) renderError(e, `${c.name}.error.${e.name}`);
    }
    if (c.types.length) {
      heading(3, "Types");
      for (const t of c.types) renderType(t);
    }

    const inh = c.inherited;
    const outside = c.externalErrors.filter(e => !model.ownErrorNames.has(e.name));
    const shared = c.externalErrors.filter(e => model.ownErrorNames.has(e.name));
    if (inh.functions.length || inh.events.length || outside.length) {
      const from = [...new Set([...inh.functions, ...inh.events, ...outside.map(e => ({ from: e.owner }))].map(x => x.from))];
      heading(3, "Inherited and imported");
      push(md(`Part of this ABI but declared in ${from.map(code).join(", ")}; the text is the upstream NatSpec.`), "");
      for (const f of inh.functions) renderFunction({ ...f, inheritedFrom: f.from }, c, `${c.name}.fn.${f.node.name}`);
      for (const e of inh.events) renderEvent({ ...e, inheritedFrom: e.from });
      for (const e of outside) {
        const built = buildError(e.node, c.name);
        renderError({ ...built, inheritedFrom: e.owner }, `${c.name}.inherited-error.${e.name}`);
      }
    }
    if (shared.length) {
      push(
        `Other errors in this ABI: ${shared
          .map(e => {
            const key = errorKey(e.name, { name: "" });
            return key ? link(code(e.name), key) : code(e.name);
          })
          .join(", ")}.`,
        "",
      );
    }
  }

  heading(2, "Shared types", "shared");
  push(`- Source: ${code(model.shared.source)}`, "");
  push(md("File-level structs, enums and errors used across the contracts above."), "");
  heading(3, "Types");
  for (const t of model.shared.types) renderType(t);
  if (model.shared.errors.length) {
    heading(3, "Errors");
    for (const e of model.shared.errors) renderError(e, `shared.error.${e.name}`);
  }

  return { text: `${lines.join("\n").replace(/\n+$/, "")}\n`, anchors: found };

  function renderFunction(f, c, key) {
    heading(4, code(f.name), key);
    block(f.signature);
    paragraphs(f.notice);
    const facts = [];
    if (f.inheritedFrom) facts.push(`Inherited from ${code(f.inheritedFrom)}`);
    if (f.access && !(f.inheritedFrom && f.access.startsWith("Anyone") && f.mutability === "nonpayable")) {
      facts.push(`Access: ${md(f.access)}`);
    }
    facts.push(`Mutability: ${code(f.mutability)}`);
    if (c.kind === "library") facts.push(`Visibility: ${code(f.visibility)}`);
    if (f.selector) facts.push(`Selector: ${code(f.selector)}${f.abiSignature ? ` (${code(f.abiSignature)})` : ""}`);
    const sites = model.callSites.get(key);
    if (c.kind === "library") facts.push(`Used by: ${sites?.length ? sites.map(code).join(", ") : "–"}`);
    for (const fact of facts) push(`- ${fact}`);
    push("");
    paragraphs(f.dev);
    table(
      ["Parameter", "Type", "Description"],
      f.params.map(p => [p.name ? code(p.name) : "_(unnamed)_", typeLink(p.type, p.userType), cell(p.text)]),
    );
    table(
      ["Returns", "Type", "Description"],
      f.returns.map(p => [p.name ? code(p.name) : "–", typeLink(p.type, p.userType), cell(p.text)]),
    );
    if (f.reverts.length) {
      push("Reverts:", "");
      for (const r of f.reverts) push(revertLine(r, c));
      push("");
    }
  }

  function renderEvent(e) {
    heading(4, code(e.name), e.key);
    block(e.signature);
    paragraphs(e.notice);
    const facts = [];
    if (e.inheritedFrom) facts.push(`Inherited from ${code(e.inheritedFrom)}`);
    if (e.topic) facts.push(`Topic 0: ${code(e.topic)}`);
    for (const fact of facts) push(`- ${fact}`);
    push("");
    paragraphs(e.dev);
    table(
      ["Field", "Type", "Indexed", "Description"],
      e.fields.map(f => [code(f.name), typeLink(f.type, f.userType), f.indexed ? "yes" : "no", cell(f.text)]),
    );
  }

  function renderError(e, key) {
    heading(4, code(e.name), key);
    block(e.signature);
    paragraphs(e.notice);
    const facts = [];
    if (e.inheritedFrom) facts.push(`Declared in ${code(e.inheritedFrom)}`);
    if (e.selector) facts.push(`Selector: ${code(e.selector)}`);
    for (const fact of facts) push(`- ${fact}`);
    push("");
    paragraphs(e.dev);
    table(
      ["Parameter", "Type", "Description"],
      e.params.map(p => [code(p.name), typeLink(p.type, p.userType), cell(p.text)]),
    );
  }

  function renderType(t) {
    heading(4, code(t.name), t.key);
    block(t.definition);
    paragraphs(t.notice, t.dev);
    if (t.kind === "struct") {
      table(
        ["Field", "Type", "Description"],
        t.fields.map(f => [code(f.name), typeLink(f.type, f.userType), cell(f.text)]),
      );
    } else {
      table(
        ["Value", "Name", "Description"],
        t.values.map(v => [String(v.index), code(v.name), cell(v.text)]),
      );
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Checks on the NatSpec itself
// ---------------------------------------------------------------------------------------------------------------

function gaps(model) {
  const missing = [];
  const need = (ok, what) => {
    if (!ok) missing.push(what);
  };
  for (const c of model.contracts) {
    for (const f of c.functions) {
      const at = `${c.name}.${f.name}`;
      need(f.notice || f.dev.length || f.name === "constructor", `${at}: no @notice`);
      for (const p of f.params) need(!p.name || p.text, `${at}: no @param ${p.name}`);
      for (const [i, r] of f.returns.entries()) need(r.text, `${at}: no @return ${r.name || `#${i}`}`);
    }
    for (const e of c.events) {
      need(e.notice, `${c.name}.${e.name}: no @notice`);
      for (const p of e.fields) need(p.text, `${c.name}.${e.name}: no @param ${p.name}`);
    }
    for (const e of c.errors) {
      need(e.notice, `${c.name}.${e.name}: no @notice`);
      for (const p of e.params) need(p.text, `${c.name}.${e.name}: no @param ${p.name}`);
    }
    for (const v of c.stateVars) need(v.text, `${c.name}.${v.name}: no @notice`);
    for (const t of c.types) for (const f of t.fields ?? []) need(f.text, `${c.name}.${t.name}: no @param ${f.name}`);
  }
  for (const t of model.shared.types) {
    need(t.notice, `${t.name}: no @notice`);
    for (const f of t.fields ?? t.values) need(f.text, `${t.name}: no @param ${f.name}`);
  }
  return missing;
}

// ---------------------------------------------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------------------------------------------

function generate() {
  const contracts = TARGETS.map(buildContract);
  const shared = buildShared();
  const typeKeys = new Map();
  for (const t of shared.types) typeKeys.set(t.name, t.key);
  for (const c of contracts) {
    for (const t of c.types) {
      typeKeys.set(`${c.name}.${t.name}`, t.key);
      if (!typeKeys.has(t.name)) typeKeys.set(t.name, t.key);
    }
    typeKeys.set(c.name, c.name);
  }
  const ownErrorNames = new Set([
    ...shared.errors.map(e => e.name),
    ...contracts.flatMap(c => c.errors.map(e => e.name)),
  ]);
  const model = {
    contracts,
    shared,
    typeKeys,
    ownErrorNames,
    deployed: deployments(),
    callSites: callSites(contracts),
  };
  // Two passes: the first collects every heading's anchor, the second renders links to them.
  const first = render(model, new Map());
  const second = render(model, first.anchors);
  return { text: second.text, gaps: gaps(model) };
}

function firstDifference(a, b) {
  const left = a.split("\n");
  const right = b.split("\n");
  let i = 0;
  while (i < left.length && i < right.length && left[i] === right[i]) i++;
  const out = [`First difference at line ${i + 1}:`];
  for (let j = i; j < Math.min(i + 6, Math.max(left.length, right.length)); j++) {
    if (left[j] !== undefined && left[j] !== right[j]) out.push(`- ${left[j]}`);
    if (right[j] !== undefined && left[j] !== right[j]) out.push(`+ ${right[j]}`);
  }
  return out.join("\n");
}

const { text, gaps: missing } = generate();
for (const m of missing) console.warn(`gen-contract-api: missing NatSpec: ${m}`);

if (process.argv.includes("--check")) {
  const current = fs.existsSync(DOC) ? fs.readFileSync(DOC, "utf8") : "";
  if (current !== text) {
    console.error(`${DOC_REL} is out of date with the contracts' NatSpec.`);
    console.error(firstDifference(current, text));
    console.error(`Regenerate it with \`${COMMAND}\` (after \`forge build\` in packages/foundry) and commit it.`);
    process.exit(1);
  }
  console.log(`${DOC_REL} is up to date.`);
} else {
  fs.writeFileSync(DOC, text);
  console.log(`Wrote ${DOC_REL} (${text.split("\n").length - 1} lines).`);
}
