// coo.ee/env — dynamic renderer (M2)
//
// Pure, testable core: given a list of requested modules, concatenate the
// shell fragments in modules/ into a single script — exactly what the M1
// hardcoded `java,android` artifact is, but rendered on demand.
//
// Single source of truth: the ../../modules fragments. No shell is duplicated.
//
// Modules may carry optional version specifiers in brackets, e.g.
//   java[17,21],android[30,37,wear-33]
// The versions are parsed here and injected as a COOEE_VERSIONS associative
// array (see _header.sh) that the module fragments read to pick what to install.

const fs = require("fs");
const path = require("path");

// api/env/render.js -> repo-root modules/ (the coo-ee-env repo root).
const MODULES_DIR = path.join(__dirname, "..", "..", "modules");

// A 400-class parse error (malformed request path). render() turns these into
// a plain-text 400 instead of a 500; anything else propagates as a real error.
class RequestError extends Error {}

// Module names: lowercase, start alphanumeric, then alphanumerics/hyphen.
const NAME_RE = /^[a-z0-9][a-z0-9-]*$/;
// Versions: lowercase alphanumeric plus . _ - (e.g. 17, 21, wear-33, 1.0).
// Kept strict on purpose — versions are interpolated into the rendered bash,
// so the charset must never allow shell metacharacters.
const VERSION_RE = /^[a-z0-9][a-z0-9._-]*$/;

// Allowed modules = *.sh fragments that aren't framing (_header/_footer).
function allowedModules() {
  return fs
    .readdirSync(MODULES_DIR)
    .filter((f) => f.endsWith(".sh") && !f.startsWith("_"))
    .map((f) => f.replace(/\.sh$/, ""))
    .sort();
}

function readFragment(name) {
  return fs.readFileSync(path.join(MODULES_DIR, `${name}.sh`), "utf8");
}

// Split on top-level commas only, leaving commas inside [ ... ] intact, so
// "java[17,21],android[30,37]" -> ["java[17,21]", "android[30,37]"].
function splitTopLevel(s) {
  const out = [];
  let depth = 0;
  let cur = "";
  for (const ch of s) {
    if (ch === "[") {
      depth++;
      cur += ch;
    } else if (ch === "]") {
      if (depth === 0) throw new RequestError(`unbalanced ']' in "${s}"`);
      depth--;
      cur += ch;
    } else if (ch === "," && depth === 0) {
      out.push(cur);
      cur = "";
    } else {
      cur += ch;
    }
  }
  if (depth !== 0) throw new RequestError(`unbalanced '[' in "${s}"`);
  out.push(cur);
  return out;
}

// Sort versions deterministically and numerically-aware: 9 < 17 < 21 < wear-33.
function cmpVersion(a, b) {
  return a.localeCompare(b, "en", { numeric: true });
}

// Parse one "name" or "name[v1,v2,...]" token into { name, versions } (or null
// for a blank token). Throws RequestError on anything malformed.
function parseEntry(raw) {
  const token = raw.trim().toLowerCase();
  if (!token) return null;

  const m = token.match(/^([^[\]]+)(?:\[([^[\]]*)\])?$/);
  if (!m) throw new RequestError(`malformed module spec: "${raw.trim()}"`);

  const name = m[1];
  if (!NAME_RE.test(name)) {
    throw new RequestError(`malformed module name: "${name}"`);
  }

  let versions = [];
  if (m[2] !== undefined) {
    versions = m[2]
      .split(",")
      .map((v) => v.trim())
      .filter(Boolean);
    for (const v of versions) {
      if (!VERSION_RE.test(v)) {
        throw new RequestError(`malformed version "${v}" in "${raw.trim()}"`);
      }
    }
    versions = [...new Set(versions)].sort(cmpVersion);
  }

  return { name, versions };
}

// A fragment may declare render-time dependencies with a directive comment:
//   # coo.ee:implies <name> [<name> ...]
// Requesting the module then pulls the implied modules into the render, so
// `android-emulator` alone yields base + android + android-emulator. Keeping
// the declaration in the fragment (not a map here) means a module's full
// definition — what it installs, the hosts it needs, what it implies — lives in
// one file. Implications are render-time only; the line is a plain comment at
// runtime. Names are validated against the available modules in render().
const IMPLIES_RE = /^#[ \t]*coo\.ee:implies[ \t]+(.+?)[ \t]*$/gm;

function moduleImplies(name) {
  const file = path.join(MODULES_DIR, `${name}.sh`);
  if (!fs.existsSync(file)) return []; // unknown modules are caught in render()
  const text = fs.readFileSync(file, "utf8");
  const names = [];
  for (const m of text.matchAll(IMPLIES_RE)) {
    for (const n of m[1].split(/[\s,]+/)) {
      const t = n.trim().toLowerCase();
      if (t) names.push(t);
    }
  }
  return names;
}

// Parse the path segment into a canonical module list:
//   - { name, versions } entries
//   - blanks dropped, modules deduped (versions merged), `base` forced first
//   - implied modules pulled in transitively (with no version request of their
//     own; an explicit entry with versions is kept)
//   - modules sorted by name; versions sorted within each
// Canonical order means android,java and java,android render identically and
// share a CDN cache entry; the same holds for version order within a module.
function canonicalize(segment) {
  const tokens = splitTopLevel(String(segment || ""));
  const byName = new Map();

  for (const tok of tokens) {
    const entry = parseEntry(tok);
    if (!entry || entry.name === "base") continue; // base is implicit, no versions
    const prev = byName.get(entry.name);
    if (prev) {
      prev.versions = [
        ...new Set([...prev.versions, ...entry.versions]),
      ].sort(cmpVersion);
    } else {
      byName.set(entry.name, entry);
    }
  }

  // Resolve implications transitively. Implied modules arrive version-less; if
  // the user also named one explicitly (with versions) it is already in the map
  // and left untouched.
  const queue = [...byName.keys()];
  while (queue.length) {
    for (const dep of moduleImplies(queue.shift())) {
      if (dep === "base" || byName.has(dep)) continue;
      byName.set(dep, { name: dep, versions: [] });
      queue.push(dep);
    }
  }

  const rest = [...byName.values()].sort((a, b) => a.name.localeCompare(b.name));
  return [{ name: "base", versions: [] }, ...rest];
}

// "java" or "java[17,21]" — the human/cache-key form of one canonical entry.
function formatEntry(entry) {
  return entry.versions.length
    ? `${entry.name}[${entry.versions.join(",")}]`
    : entry.name;
}

// Generated bash that records the requested versions for the module fragments.
// Emitted only when something asked for versions, so a plain `java,android`
// request stays byte-identical to the version-less rendering (and its cache
// entry). COOEE_VERSIONS itself is always declared in _header.sh, so modules
// can safely read ${COOEE_VERSIONS[x]:-<default>} whether or not this runs.
function renderVersionsBlock(modules) {
  const withVersions = modules.filter((m) => m.versions.length);
  if (!withVersions.length) return "";

  const lines = [
    "",
    "# ---- requested module versions (coo.ee/env) -------------------------------",
    "# Parsed from version specifiers in the request path, e.g. java[17,21].",
    "# Modules read COOEE_VERSIONS[<module>]; an unset entry means module default.",
  ];
  for (const m of withVersions) {
    // versions pass VERSION_RE (no shell metacharacters), so plain double
    // quotes around the space-joined list are safe.
    lines.push(`COOEE_VERSIONS[${m.name}]="${m.versions.join(" ")}"`);
  }
  lines.push("");
  return lines.join("\n");
}

// render(segment) -> { status, contentType, body, canonical }
function render(segment) {
  const allowed = allowedModules();

  let modules;
  try {
    modules = canonicalize(segment);
  } catch (err) {
    if (err instanceof RequestError) {
      return {
        status: 400,
        contentType: "text/plain; charset=utf-8",
        canonical: [],
        body: `# coo.ee/env: ${err.message}\n`,
      };
    }
    throw err;
  }

  const unknown = modules
    .filter((m) => m.name !== "base" && !allowed.includes(m.name))
    .map((m) => m.name);

  if (unknown.length) {
    return {
      status: 400,
      contentType: "text/plain; charset=utf-8",
      canonical: modules.map(formatEntry),
      body:
        `# coo.ee/env: unknown module(s): ${unknown.join(", ")}\n` +
        `# available: ${allowed.join(", ")}\n`,
    };
  }

  const parts = [
    readFragment("_header"),
    renderVersionsBlock(modules),
    ...modules.map((m) => readFragment(m.name)),
    readFragment("_footer"),
  ];

  return {
    status: 200,
    contentType: "text/x-shellscript; charset=utf-8",
    canonical: modules.map(formatEntry),
    body: parts.join(""),
  };
}

module.exports = { render, canonicalize, allowedModules, MODULES_DIR };
