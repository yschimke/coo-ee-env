
# ===========================================================================
#  module: node
#    software : Node.js 22 LTS (via Nix), npm
#    hosts    : cache.nixos.org (install)
#             : npm registry (build; used by the best-effort dependency
#               prefetch, advisory — opt out COOEE_NO_DEPS=1)
#  Prefer the cloud base image when present (Codex: CODEX_ENV_NODE_VERSION).
# ===========================================================================
register_module node
provides_tool node node CODEX_ENV_NODE_VERSION
# Pre-approve the Node.js toolchain for Claude Code sessions.
provides_perms node "Bash(node:*)" "Bash(npm:*)" "Bash(npx:*)" "Bash(pnpm:*)" "Bash(yarn:*)" "Bash(corepack:*)"
need_host cache.nixos.org     "prebuilt Node.js from the Nix cache"
want_host registry.npmjs.org  "npm package downloads"
want_host nodejs.org          "Node.js release metadata / corepack"

module_node() {
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v node >/dev/null 2>&1; then
    ok "node: adopted existing $(node --version 2>/dev/null) ($(command -v node))."
    cooee_prefetch_npm
    return 0
  fi
  log "Installing Node.js 22 LTS via Nix..."
  nix_ensure nodejs nixpkgs#nodejs_22 --accept-flake-config
  command -v node >/dev/null 2>&1 || die "node not on PATH after install."
  ok "node ready: $(node --version 2>/dev/null)"

  cooee_prefetch_npm
}

# Warm the npm cache / node_modules: with node + npm ready and the registry
# reachable, install the project's dependencies now so a later build/test —
# possibly under tighter egress — has them on disk. Best-effort and never fatal.
# A clean lockfile uses `npm ci` (reproducible; falls back to `npm install` if
# the lockfile is out of sync); otherwise `npm install`. Skipped when there is
# no package.json in the project dir, or when COOEE_NO_DEPS=1.
cooee_prefetch_npm() {
  cooee_deps_enabled || { log "node: skipping npm dependency install (COOEE_NO_DEPS=1)."; return 0; }

  local dir; dir=$(cooee_project_dir)
  [[ -f "$dir/package.json" ]] || { log "node: no package.json in $dir; skipping dependency install."; return 0; }
  command -v npm >/dev/null 2>&1 || { warn "node: npm not on PATH; skipping dependency install."; return 0; }

  local -a cmd
  if [[ -f "$dir/package-lock.json" || -f "$dir/npm-shrinkwrap.json" ]]; then cmd=(npm ci); else cmd=(npm install); fi
  log "node: installing npm dependencies (${cmd[*]})..."
  local out
  if out=$( cd "$dir" && "${cmd[@]}" </dev/null 2>&1 ); then
    ok "node: npm dependencies installed (${cmd[*]})."
    return 0
  fi
  # `npm ci` is strict — it fails when the lockfile and package.json disagree.
  # Fall back to a plain install once before giving up.
  if [[ "${cmd[*]}" == "npm ci" ]]; then
    local out2
    if out2=$( cd "$dir" && npm install </dev/null 2>&1 ); then
      ok "node: npm dependencies installed (npm install fallback)."
      return 0
    fi
    out="$out2"
  fi
  printf '%s\n' "$out" >&2
  warn "node: npm dependency install failed (continuing). Allowlist registry.npmjs.org, or set COOEE_NO_DEPS=1 to skip."
}
