
# ===========================================================================
#  module: rust
#    software : Rust toolchain — rustc + cargo (via Nix)
#    hosts    : cache.nixos.org (install)
#             : crates.io (build, advisory)
#  Prefer the cloud base image when present (Codex: CODEX_ENV_RUST_VERSION).
# ===========================================================================
register_module rust
provides_tool rust cargo CODEX_ENV_RUST_VERSION
# Pre-approve the Rust toolchain for Claude Code sessions.
provides_perms rust "Bash(cargo:*)" "Bash(rustc:*)" "Bash(rustup:*)" "Bash(rustfmt:*)"
need_host cache.nixos.org     "prebuilt Rust toolchain from the Nix cache"
want_host static.crates.io    "crates.io package downloads"
want_host index.crates.io     "crates.io sparse index"

module_rust() {
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v cargo >/dev/null 2>&1; then
    ok "rust: adopted existing $(cargo --version 2>/dev/null) ($(command -v cargo))."
    return 0
  fi
  log "Installing Rust (rustc + cargo) via Nix..."
  nix_ensure rustc nixpkgs#rustc --accept-flake-config
  nix_ensure cargo nixpkgs#cargo --accept-flake-config
  command -v cargo >/dev/null 2>&1 || die "cargo not on PATH after install."
  ok "rust ready: $(rustc --version 2>/dev/null) / $(cargo --version 2>/dev/null)"
}
