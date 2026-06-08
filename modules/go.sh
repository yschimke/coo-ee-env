
# ===========================================================================
#  module: go
#    software : Go toolchain (via Nix), GOPATH
#    hosts    : cache.nixos.org (install)
#             : Go module proxy + checksum DB (build, advisory)
#  Prefer the cloud base image when present (Codex: CODEX_ENV_GO_VERSION).
# ===========================================================================
register_module go
provides_tool go go CODEX_ENV_GO_VERSION
need_host cache.nixos.org     "prebuilt Go toolchain from the Nix cache"
want_host proxy.golang.org    "Go module proxy"
want_host sum.golang.org      "Go checksum database"

module_go() {
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v go >/dev/null 2>&1; then
    add_env GOPATH "${GOPATH:-$HOME/go}"
    ok "go: adopted existing $(go version 2>/dev/null) ($(command -v go))."
    return 0
  fi
  log "Installing Go toolchain via Nix..."
  nix_ensure go nixpkgs#go --accept-flake-config
  command -v go >/dev/null 2>&1 || die "go not on PATH after install."
  add_env GOPATH "${GOPATH:-$HOME/go}"
  ok "go ready: $(go version 2>/dev/null)"
}
