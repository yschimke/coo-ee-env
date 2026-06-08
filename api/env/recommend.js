// coo.ee/env — recommendation core
//
// Given the modules a user has already selected, suggest the next things to
// install. Pure and testable, like render.js. Today the suggestions come from
// a static affinity table (the KNOWLEDGE block below); the engine is written
// so that table can later be replaced by usage-derived data (co-occurrence
// counts from real request logs) without touching the scoring logic — see
// recommend(segment, { knowledge }).
//
// A "recommendation" is an appendable request spec: either a sibling module
// ("android") or a tools[...] bundle ("tools[uv,ruff]"). Append it to the
// current path and you have a valid coo.ee/env request.

const { canonicalize, allowedModules } = require("./render");

// ---------------------------------------------------------------------------
// KNOWLEDGE — what developers generally want, encoded as affinities.
// ---------------------------------------------------------------------------

// The near-universal CLI kit: things most developers reach for regardless of
// language. nixpkgs attribute names, installed via the `tools` module.
const BASELINE_TOOLS = ["ripgrep", "fd", "jq", "fzf", "gh", "bat"];

// Modules worth suggesting to anyone, independent of language choice.
const BASELINE_MODULES = [
  { module: "skills", weight: 1, reason: "Agent skills for Claude Code (this is an agent-oriented env)." },
];

// Per-module affinities. When a module is selected, each rule contributes a
// weighted suggestion — a sibling `module`, or a `tools` bundle. Weights rank
// the output; higher = stronger nudge.
const RULES = {
  java: [
    { module: "android", weight: 5, reason: "Android builds run on the JDK you just added." },
    { tools: ["gradle", "kotlin"], weight: 3, reason: "Gradle + Kotlin are the usual JVM build/CLI companions." },
  ],
  android: [
    { module: "java", weight: 9, reason: "Android builds require a JDK — java is effectively a prerequisite." },
    { module: "android-emulator", weight: 4, reason: "Run/test on a device image without Android Studio." },
    { tools: ["kotlin"], weight: 3, reason: "Modern Android code is mostly Kotlin." },
  ],
  node: [
    { tools: ["pnpm", "typescript", "prettier", "eslint"], weight: 4, reason: "The standard JS/TS toolbelt: package manager, types, format, lint." },
  ],
  python: [
    { tools: ["uv", "ruff"], weight: 4, reason: "uv (envs/installs) and ruff (lint+format) are the modern Python defaults." },
  ],
  go: [
    { tools: ["golangci-lint", "gopls", "delve"], weight: 4, reason: "Linter, language server, and debugger round out a Go setup." },
  ],
  rust: [
    { tools: ["cargo-edit", "cargo-watch", "sccache"], weight: 4, reason: "Common cargo extensions plus a compile cache." },
  ],
  ruby: [
    { tools: ["rubocop", "solargraph"], weight: 4, reason: "RuboCop (lint/format) and Solargraph (language server) are the Ruby staples." },
  ],
  skills: [
    { tools: ["gh"], weight: 2, reason: "Agent workflows lean on the GitHub CLI." },
  ],
};

// Symmetric "these go together" nudges (lower weight than direct rules).
const COOCCURRENCE = [
  { a: "node", b: "python", weight: 2, reason: "Full-stack repos often need both Node and Python." },
];

const DEFAULT_KNOWLEDGE = { BASELINE_TOOLS, BASELINE_MODULES, RULES, COOCCURRENCE };

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

function specOf(name, params) {
  return params && params.length ? `${name}[${[...params].sort().join(",")}]` : name;
}

// recommend(segment, opts) -> { selected, recommendations, next }
//   opts.knowledge lets a caller inject usage-derived affinities later.
function recommend(segment, opts = {}) {
  const k = opts.knowledge || DEFAULT_KNOWLEDGE;
  const limit = opts.limit || 8;

  const { entries } = canonicalize(segment);
  const selected = new Set(entries.map((e) => e.name));
  const available = new Set(allowedModules());
  const toolsModule = available.has("tools");
  const haveTools = new Set(entries.find((e) => e.name === "tools")?.params || []);

  // --- module suggestions: sum weights from every contributing rule ---------
  const modules = new Map(); // name -> { score, reasons:Set }
  const addModule = (name, weight, reason) => {
    if (selected.has(name) || !available.has(name)) return;
    const m = modules.get(name) || { score: 0, reasons: new Set() };
    m.score += weight;
    m.reasons.add(reason);
    modules.set(name, m);
  };

  for (const b of k.BASELINE_MODULES) addModule(b.module, b.weight, b.reason);
  for (const name of selected)
    for (const rule of k.RULES[name] || [])
      if (rule.module) addModule(rule.module, rule.weight, rule.reason);
  for (const c of k.COOCCURRENCE) {
    if (selected.has(c.a)) addModule(c.b, c.weight, c.reason);
    if (selected.has(c.b)) addModule(c.a, c.weight, c.reason);
  }

  // --- tool-bundle suggestions ----------------------------------------------
  // Gather every tool rule (baseline + per-module), strongest first, and let
  // each bundle claim the tools it suggests so a tool is recommended once, in
  // its most relevant bundle. Tools already requested are dropped.
  const toolRules = [];
  if (toolsModule) {
    toolRules.push({ tools: k.BASELINE_TOOLS, weight: 1, reason: "Common CLI kit most developers want." });
    for (const name of selected)
      for (const rule of k.RULES[name] || [])
        if (rule.tools) toolRules.push(rule);
  }
  toolRules.sort((a, b) => b.weight - a.weight);

  const claimed = new Set([...haveTools]);
  const toolBundles = [];
  for (const rule of toolRules) {
    const missing = rule.tools.filter((t) => !claimed.has(t));
    if (!missing.length) continue;
    missing.forEach((t) => claimed.add(t));
    toolBundles.push({ kind: "tools", spec: specOf("tools", missing), score: rule.weight, reasons: [rule.reason] });
  }

  // --- merge, rank, trim ----------------------------------------------------
  const moduleRecs = [...modules.entries()].map(([name, m]) => ({
    kind: "module",
    spec: name,
    score: m.score,
    reasons: [...m.reasons],
  }));

  const recommendations = [...moduleRecs, ...toolBundles]
    .sort((a, b) => b.score - a.score || a.spec.localeCompare(b.spec))
    .slice(0, limit);

  // "next": current selection + every recommendation, canonicalized so the
  // separate tools[...] bundles merge into a single one and the path is valid.
  const combined = [...entries.map((e) => specOf(e.name, e.params)), ...recommendations.map((r) => r.spec)].join(",");
  const next = canonicalize(combined).entries.map((e) => specOf(e.name, e.params)).join(",");

  return {
    selected: entries.map((e) => specOf(e.name, e.params)),
    recommendations,
    next,
  };
}

module.exports = { recommend, DEFAULT_KNOWLEDGE };
