// coo.ee/env — devcontainer renderer
//
// Renders a Dev Container from the same module selection the shell renderer
// (render.js) uses. The module list, canonical form, and cache key are
// unchanged; only the output differs (cf. the `?devenv` backend swap).
//
// Two strategies:
//   - "thin" (option A): one devcontainer.json whose postCreateCommand runs the
//     existing `curl … | bash` one-liner, so all provisioning logic (Nix/devenv
//     backends, host adoption, idempotent repair) is reused verbatim.
//   - "image" (option B): a multi-file .devcontainer/ bundle — Dockerfile +
//     an *enforcing* default-deny egress firewall (init-firewall.sh +
//     allowed-domains.txt) wired with NET_ADMIN, on top of the thin
//     provisioning. (Baking provisioning into a build-cached layer is the next
//     iteration; for now the image adds the firewall and the toolchain is still
//     installed at postCreate so it runs as the remote user.)
//
// Output modes (how the chosen strategy is delivered):
//   - "apply" (default): a shell script that writes the file(s) into the repo,
//     so `curl … | bash` drops a .devcontainer/ in place. Idempotent: refuses
//     to clobber unless COOEE_FORCE=1.
//   - "json": the raw devcontainer.json (thin strategy only — the image
//     strategy is multi-file, so its apply script *is* the inspectable form).
//
// The firewall allowlist is computed from each module's need_host/want_host
// declarations — the same metadata the shell script probes and the picker
// surfaces — so the bundle carries a minimal, correct egress allowlist.

const fs = require("fs");
const path = require("path");
const {
  canonicalize,
  entryToString,
  allowedModules,
  moduleInfo,
  MODULES_DIR,
} = require("./render");

const ONE_LINER_HOST = "https://env.coo.ee";

// Mainstream base images, chosen by host affinity. codex-universal is the image
// Codex cloud mirrors (and coo.ee already aligns with it via the CODEX_ENV_*
// version selectors); the MS devcontainers base is the neutral default.
const BASE_IMAGES = {
  ubuntu: "mcr.microsoft.com/devcontainers/base:ubuntu",
  codex: "ghcr.io/openai/codex-universal:latest",
};

// The maintained Claude Code dev container Feature — installs the CLI onto any
// base image, so the generated container is immediately usable for agents.
const CLAUDE_CODE_FEATURE =
  "ghcr.io/anthropics/devcontainer-features/claude-code:1.0";

// Static templates live on disk (so they're lint/`bash -n`-checkable and stay a
// single source of truth); the `_` prefix keeps them out of the module catalog.
const FIREWALL_TEMPLATE = "_devcontainer-firewall.sh";
const DOCKERFILE_TEMPLATE = "_devcontainer.Dockerfile";

function pickBase(base) {
  return BASE_IMAGES[base] || BASE_IMAGES.ubuntu;
}

function readTemplate(name) {
  return fs.readFileSync(path.join(MODULES_DIR, name), "utf8");
}

// Single-quote a string for safe embedding in the apply script. Paths are
// controlled (literal file names), but quote defensively.
function shq(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

// Hosts the selected modules need (to install) or want (for builds), deduped
// and split: concrete hosts are IP-enforceable by the firewall; wildcard hosts
// (*.example.com) can only be matched by name, so they're advisory. Single
// source of truth: the need_host/want_host directives parsed by moduleInfo().
function gatherDomains(entries) {
  const byName = Object.fromEntries(moduleInfo().map((m) => [m.name, m.hosts]));
  const set = new Set();
  for (const e of entries) {
    const hosts = byName[e.name];
    if (!hosts) continue;
    for (const h of [...hosts.need, ...hosts.want]) set.add(h.host);
  }
  const all = [...set].sort();
  return {
    all,
    concrete: all.filter((d) => !d.startsWith("*.")),
    wildcard: all.filter((d) => d.startsWith("*.")),
  };
}

// The curl one-liner the devcontainer runs to provision (postCreateCommand).
// Targets the canonical list (minus the implicit base) so it shares the cache
// key the shell endpoint emits; ?devenv rides along.
function oneLiner(requested, devenv) {
  const query = devenv ? "?devenv" : "";
  return `curl -fsSL ${ONE_LINER_HOST}/${requested.join(",")}${query} | bash`;
}

function jsonError(status, message, allowed, canonical) {
  return {
    status,
    contentType: "application/json; charset=utf-8",
    canonical,
    devcontainer: null,
    allowedDomains: [],
    body:
      JSON.stringify(
        { error: `coo.ee/env: ${message}`, available: allowed },
        null,
        2,
      ) + "\n",
  };
}

// applyScript(files, label) -> a bash script that writes each file into the
// repo's .devcontainer/ (git root when run inside one, else $PWD; override the
// dir with COOEE_DEVCONTAINER_DIR). Each file is embedded via a *quoted*
// heredoc so nothing in it is shell-expanded. Refuses to overwrite an existing
// file unless COOEE_FORCE=1 — the same force convention the installer uses.
// files: [{ path, content }] with path relative to .devcontainer/.
function applyScript(files, label) {
  const blocks = files
    .map((f, i) => {
      const delim = `COOEE_FILE_${i}`;
      const body = f.content.endsWith("\n") ? f.content : f.content + "\n";
      return `write_file ${shq(f.path)} <<'${delim}'\n${body}${delim}\n`;
    })
    .join("\n");

  return `#!/usr/bin/env bash
# coo.ee/env — devcontainer apply script for: ${label}
# Writes the .devcontainer/ file(s) below into your repo, then you can "Reopen in
# Container" (VS Code), launch with the devcontainer CLI, or commit them.
#   curl -fsSL 'https://env.coo.ee/${label}?devcontainer' | bash
# Re-run with COOEE_FORCE=1 to overwrite existing files.
set -euo pipefail

# Write at the git repo root when we're in one, else the current directory.
root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
dcdir="\${COOEE_DEVCONTAINER_DIR:-\${root:-$PWD}/.devcontainer}"

write_file() {
  local rel="$1" dst="$dcdir/$1"
  mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" && "\${COOEE_FORCE:-0}" != "1" ]]; then
    echo "coo.ee/env: $dst already exists — set COOEE_FORCE=1 to overwrite." >&2
    exit 1
  fi
  cat > "$dst"
  echo "coo.ee/env: wrote $dst" >&2
}

${blocks}`;
}

// The allowed-domains.txt the firewall reads: concrete hosts active (one per
// line), wildcard hosts listed as comments (not IP-enforceable here).
function allowedDomainsFile(label, domains) {
  const lines = [
    `# coo.ee/env — allowed egress domains for: ${label}`,
    `# One host per line; resolved to IPs and enforced by init-firewall.sh.`,
    ...domains.concrete,
  ];
  if (domains.wildcard.length) {
    lines.push(
      ``,
      `# Wildcard / name-based hosts below are advisory — the IP firewall can't`,
      `# match by name. Allow them in your platform's proxy allowlist (Codex`,
      `# domain allowlist, Claude web custom allowlist) if a build needs them:`,
      ...domains.wildcard.map((d) => `# ${d}`),
    );
  }
  return lines.join("\n") + "\n";
}

// Validate a segment like render() does: malformed/invalid tokens and unknown
// modules -> 400 with the available list. Returns { entries, canonical } on
// success, or { error } (a ready jsonError result) on failure.
function validate(segment) {
  const allowed = allowedModules();
  const { entries, errors } = canonicalize(segment);
  const canonical = entries.map(entryToString);
  if (errors.length) {
    return { error: jsonError(400, errors.join("; "), allowed, canonical) };
  }
  const unknown = entries
    .filter((e) => e.name !== "base" && !allowed.includes(e.name))
    .map((e) => e.name);
  if (unknown.length) {
    return {
      error: jsonError(
        400,
        `unknown module(s): ${unknown.join(", ")}`,
        allowed,
        canonical,
      ),
    };
  }
  return { entries, canonical };
}

// renderDevcontainer(segment, opts) -> { status, contentType, body, canonical,
//   devcontainer, allowedDomains }
//   opts.base   — "ubuntu" (default) | "codex": base image by host affinity.
//   opts.devenv — when true, the one-liner carries ?devenv (devenv.sh backend).
//   opts.mode   — "apply" (default) | "json" | "image".
// Because the apply UX is `curl -f … | bash`, a 400 makes curl fail without
// piping anything to the shell, so a JSON error body is safe for every mode.
function renderDevcontainer(segment, opts) {
  const o = opts || {};
  const mode = o.mode === "json" || o.mode === "image" ? o.mode : "apply";
  const v = validate(segment);
  if (v.error) return v.error;

  const { entries, canonical } = v;
  const requested = canonical.filter((c) => c !== "base");
  const label = requested.join(",") || "base";
  const baseImage = pickBase(o.base);
  const domains = gatherDomains(entries);
  const provision = oneLiner(requested, o.devenv);

  if (mode === "image") {
    // Option B: Dockerfile + enforcing firewall bundle.
    const devcontainer = {
      name: `coo.ee/env • ${label} (image)`,
      build: { dockerfile: "Dockerfile", args: { BASE: baseImage } },
      features: { [CLAUDE_CODE_FEATURE]: {} },
      // The default-deny firewall needs these caps; drop them and the
      // postStart line to opt out of in-container egress control.
      runArgs: ["--cap-add=NET_ADMIN", "--cap-add=NET_RAW"],
      postCreateCommand: provision,
      postStartCommand: "sudo /usr/local/bin/init-firewall.sh",
      containerEnv: { COOEE_ALLOWED_DOMAINS: domains.concrete.join(",") },
    };
    const files = [
      { path: "devcontainer.json", content: JSON.stringify(devcontainer, null, 2) + "\n" },
      { path: "Dockerfile", content: readTemplate(DOCKERFILE_TEMPLATE) },
      { path: "init-firewall.sh", content: readTemplate(FIREWALL_TEMPLATE) },
      { path: "allowed-domains.txt", content: allowedDomainsFile(label, domains) },
    ];
    return {
      status: 200,
      contentType: "text/x-shellscript; charset=utf-8",
      canonical,
      devcontainer,
      allowedDomains: domains.concrete,
      body: applyScript(files, label),
    };
  }

  // Thin strategy (option A): a single devcontainer.json.
  const devcontainer = {
    name: `coo.ee/env • ${label}`,
    image: baseImage,
    features: { [CLAUDE_CODE_FEATURE]: {} },
    postCreateCommand: provision,
    // Option A surfaces the allowlist for the platform's network policy but does
    // not enforce a firewall (that's the image strategy).
    containerEnv: { COOEE_ALLOWED_DOMAINS: domains.all.join(",") },
  };
  const jsonText = JSON.stringify(devcontainer, null, 2) + "\n";

  return {
    status: 200,
    contentType:
      mode === "json"
        ? "application/json; charset=utf-8"
        : "text/x-shellscript; charset=utf-8",
    canonical,
    devcontainer,
    allowedDomains: domains.all,
    body:
      mode === "json"
        ? jsonText
        : applyScript([{ path: "devcontainer.json", content: jsonText }], label),
  };
}

module.exports = {
  renderDevcontainer,
  gatherDomains,
  allowedDomainsFile,
  BASE_IMAGES,
  CLAUDE_CODE_FEATURE,
};
