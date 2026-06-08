
# ===========================================================================
#  module: node
#    software : Node.js 22 LTS (via Nix), npm
#    hosts    : cache.nixos.org (install)
#             : npm registry (build, advisory)
#  Prefer the cloud base image when present (Codex: CODEX_ENV_NODE_VERSION).
# ===========================================================================
register_module node
provides_tool node node CODEX_ENV_NODE_VERSION
need_host cache.nixos.org     "prebuilt Node.js from the Nix cache"
want_host registry.npmjs.org  "npm package downloads"
want_host nodejs.org          "Node.js release metadata / corepack"

module_node() {
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v node >/dev/null 2>&1; then
    ok "node: adopted existing $(node --version 2>/dev/null) ($(command -v node))."
    return 0
  fi
  log "Installing Node.js 22 LTS via Nix..."
  nix_ensure nodejs nixpkgs#nodejs_22 --accept-flake-config
  command -v node >/dev/null 2>&1 || die "node not on PATH after install."
  ok "node ready: $(node --version 2>/dev/null)"
}
