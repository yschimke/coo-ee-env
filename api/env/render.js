// coo.ee/env — dynamic renderer (M2)
//
// Pure, testable core: given a list of requested modules, concatenate the
// shell fragments in modules/ into a single script — exactly what the M1
// hardcoded `java,android` artifact is, but rendered on demand.
//
// Modules may carry parameters in brackets, e.g. `skills[yschimke/skills]`
// or `skills[yschimke/skills,obra/superpowers]`. The bracketed list is the
// module's request-time input (which skill repos, which MCP servers, ...).
// Parameters are validated, deduped, sorted, and injected into the script as
// `set_params <module> '<comma-joined>'` so the shell fragment stays a static
// source of truth for *logic* while the renderer supplies the *data*.
//
// Single source of truth: the ../../modules fragments. No shell is duplicated.

const fs = require("fs");
const path = require("path");

// api/env/render.js -> repo-root modules/ (the coo-ee-env repo root).
const MODULES_DIR = path.join(__dirname, "..", "..", "modules");

// Module names are lowercase slugs; parameters keep their case (repo slugs and
// refs are case-sensitive) but are restricted to a safe charset so a request
// can never inject shell into the rendered script.
const NAME_RE = /^[a-z0-9][a-z0-9-]*$/;
const PARAM_RE = /^[A-Za-z0-9._/@-]+$/;

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

// A fragment declares the hosts it touches with two directives, defined in
// _header (need_host / want_host) but also the single source of truth for what
// the UI advertises:
//   need_host <host>          "<reason>"   — required to INSTALL (hard-fail if blocked)
//   want_host <host|*.host>   "<reason>"   — recommended for BUILDS (advisory)
// The host may be bare or double-quoted (wildcards like "*.jetbrains.com" are
// quoted in shell); the reason is always double-quoted. Parsing the actual
// calls — rather than the `# hosts :` header comment — keeps the catalog in
// lockstep with what the rendered script will probe and print.
const HOST_RE = /^(need|want)_host[ \t]+(?:"([^"]+)"|(\S+))[ \t]+"([^"]*)"/gm;

function moduleHosts(name) {
  const need = [];
  const want = [];
  for (const m of readFragment(name).matchAll(HOST_RE)) {
    const entry = { host: m[2] || m[3], reason: m[4] };
    (m[1] === "need" ? need : want).push(entry);
  }
  return { need, want };
}

// moduleInfo() -> [{ name, software, params, implies, implicit, hosts }], parsed
// from each fragment's header comments (`# software : <desc>`, `# params : <desc>`),
// its `# coo.ee:implies` directive, and its need_host/want_host declarations.
// The fragments stay the single source of truth: the autocomplete UI reads this
// rather than keeping its own copy of the module list, what each takes in
// brackets, what it pulls in, or which hosts it needs allowlisted. `base` is
// flagged implicit (always prepended, so the UI shows it as fixed).
function moduleInfo() {
  return allowedModules().map((name) => {
    const src = readFragment(name);
    const software = (src.match(/^#\s*software\s*:\s*(.+?)\s*$/m) || [])[1] || "";
    const params = (src.match(/^#\s*params\s*:\s*(.+?)\s*$/m) || [])[1] || "";
    return {
      name,
      software,
      params,
      implies: moduleImplies(name),
      implicit: name === "base",
      hidden: moduleHidden(name),
      hosts: moduleHosts(name),
    };
  });
}

// Split "a,b[c,d],e" on top-level commas only — commas inside [...] belong to
// the bracketed parameter list and must not split the module list.
function splitTopLevel(segment) {
  const out = [];
  let buf = "";
  let depth = 0;
  for (const ch of String(segment || "")) {
    if (ch === "[") { depth++; buf += ch; }
    else if (ch === "]") { depth = Math.max(0, depth - 1); buf += ch; }
    else if (ch === "," && depth === 0) { out.push(buf); buf = ""; }
    else buf += ch;
  }
  out.push(buf);
  return out;
}

// A fragment may declare render-time dependencies with a directive comment:
//   # coo.ee:implies <name> [<name> ...]
// Requesting the module then pulls the implied modules into the render
// (transitively), so `android-emulator` alone yields base + android +
// android-emulator. Keeping the declaration in the fragment means a module's
// full definition — what it installs, the hosts it needs, what it implies —
// lives in one file. Implications are render-time only; the line is a plain
// comment at run time. Implied names are validated like any other module below.
const IMPLIES_RE = /^#[ \t]*coo\.ee:implies[ \t]+(.+?)[ \t]*$/gm;

function moduleImplies(name) {
  const file = path.join(MODULES_DIR, `${name}.sh`);
  if (!fs.existsSync(file)) return []; // unknown modules are caught in render()
  const out = [];
  for (const m of fs.readFileSync(file, "utf8").matchAll(IMPLIES_RE)) {
    for (const n of m[1].split(/[\s,]+/)) {
      const t = n.trim().toLowerCase();
      if (t) out.push(t);
    }
  }
  return out;
}

// A fragment may opt out of the picker's top-level list with a directive:
//   # coo.ee:hidden
// The module still renders and installs exactly like any other (the /<name>
// one-liner works, and it can be pulled in via `# coo.ee:implies`), but the
// landing page leaves it out of the searchable catalog — for dependencies that
// ride along with another module rather than being picked on their own (e.g.
// android-cli, installed with the android SDK). It stays in moduleInfo (flagged)
// so the UI can still resolve its name, hosts, and implications.
const HIDDEN_RE = /^#[ \t]*coo\.ee:hidden\b/m;

function moduleHidden(name) {
  const file = path.join(MODULES_DIR, `${name}.sh`);
  if (!fs.existsSync(file)) return false;
  return HIDDEN_RE.test(fs.readFileSync(file, "utf8"));
}

// canonicalize(segment) -> { entries, errors }
//   entries: [{ name, params: [...] }] — `base` forced first, the rest sorted
//            by name; duplicate modules merge their params; params deduped+sorted.
//            Implied modules (see moduleImplies) are pulled in with no params.
//   errors:  human-readable strings for malformed tokens (renderer -> 400).
// Canonical order means android,java and java,android (and skills[b,a] vs
// skills[a,b]) render byte-identically and share a CDN cache entry.
function canonicalize(segment) {
  const errors = [];
  const params = new Map(); // name -> Set(params)

  for (const raw of splitTopLevel(segment)) {
    const token = raw.trim();
    if (!token) continue;

    const m = token.match(/^([^[\]]+?)(?:\[([^\]]*)\])?$/);
    if (!m) {
      errors.push(`malformed module token: ${token}`);
      continue;
    }
    const name = m[1].trim().toLowerCase();
    if (!NAME_RE.test(name)) {
      errors.push(`invalid module name: ${name}`);
      continue;
    }

    const set = params.get(name) || new Set();
    if (m[2] !== undefined && name !== "base") {
      for (const p of m[2].split(",").map((s) => s.trim()).filter(Boolean)) {
        if (!PARAM_RE.test(p)) {
          errors.push(`invalid parameter for ${name}: ${p}`);
          continue;
        }
        set.add(p);
      }
    }
    params.set(name, set);
  }

  // Resolve implications transitively. Implied modules arrive with no params of
  // their own; an explicitly-requested module (with params) is already present
  // and left untouched.
  const queue = [...params.keys()];
  while (queue.length) {
    for (const dep of moduleImplies(queue.shift())) {
      if (dep === "base" || params.has(dep)) continue;
      params.set(dep, new Set());
      queue.push(dep);
    }
  }

  const rest = [...params.keys()].filter((n) => n !== "base").sort();
  const entries = ["base", ...rest].map((name) => ({
    name,
    // Numeric-aware so version params order naturally (9 < 17 < 21 < wear-33),
    // not lexically (which would give 17 < 8). Harmless for non-numeric params
    // like repo slugs.
    params: [...(params.get(name) || new Set())].sort((a, b) =>
      a.localeCompare(b, "en", { numeric: true }),
    ),
  }));

  return { entries, errors };
}

// Canonical string form of an entry: "name" or "name[p1,p2]". Used for the
// cache key / x-cooee-modules header and for echoing the request back.
function entryToString(e) {
  return e.params.length ? `${e.name}[${e.params.join(",")}]` : e.name;
}

// Single-quote for safe embedding in the rendered shell. Parameters are
// already restricted to PARAM_RE (no quotes), so this is belt-and-suspenders.
function shQuote(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

// render(segment, opts) -> { status, contentType, body, canonical }
//   opts.devenv — when true (the `?devenv` request flag), the renderer splices
//   in the devenv.sh backend fragment instead of the default Nix-profile one.
//   The choice is resolved HERE, at render time: the emitted script carries
//   only the selected backend's code, with no run-time `if devenv` branches.
//   The module list (and thus the canonical form / cache key path) is
//   unaffected; only the query string and the backend fragment differ.
function render(segment, opts) {
  const devenv = !!(opts && opts.devenv);
  const allowed = allowedModules();
  const { entries, errors } = canonicalize(segment);
  const canonical = entries.map(entryToString);

  if (errors.length) {
    return {
      status: 400,
      contentType: "text/plain; charset=utf-8",
      canonical,
      body:
        `# coo.ee/env: ${errors.join("; ")}\n` +
        `# available: ${allowed.join(", ")}\n`,
    };
  }

  const unknown = entries
    .filter((e) => e.name !== "base" && !allowed.includes(e.name))
    .map((e) => e.name);

  if (unknown.length) {
    return {
      status: 400,
      contentType: "text/plain; charset=utf-8",
      canonical,
      body:
        `# coo.ee/env: unknown module(s): ${unknown.join(", ")}\n` +
        `# available: ${allowed.join(", ")}\n`,
    };
  }

  // _header (generic helpers) + the chosen backend driver. The backend
  // fragment defines nix_ensure and the cooee_backend_* hooks the modules call,
  // so a module fragment is backend-agnostic — only one implementation is ever
  // spliced in, never both.
  const parts = [
    readFragment("_header"),
    readFragment(devenv ? "_backend-devenv" : "_backend-nix"),
  ];

  // Inject request parameters before the module fragments run. set_params is
  // defined in _header; the fragments and _footer read _MODULE_PARAMS at run
  // time, so a no-parameter request (e.g. java,android) emits nothing here and
  // renders byte-identically to before parameters existed.
  const injections = entries
    .filter((e) => e.params.length)
    .map((e) => `set_params ${e.name} ${shQuote(e.params.join(","))}\n`);
  if (injections.length) {
    parts.push(
      "\n# ---- request parameters (injected by the renderer) -----------------------\n",
      ...injections,
    );
  }

  parts.push(...entries.map((e) => readFragment(e.name)), readFragment("_footer"));

  return {
    status: 200,
    contentType: "text/x-shellscript; charset=utf-8",
    canonical,
    body: parts.join(""),
  };
}

module.exports = {
  render,
  canonicalize,
  entryToString,
  allowedModules,
  moduleInfo,
  MODULES_DIR,
};
