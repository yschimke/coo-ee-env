
# ===========================================================================
#  module: python
#    software : CPython 3 + pip (via Nix)
#    hosts    : cache.nixos.org (install)
#             : PyPI (build, advisory)
#  Prefer the cloud base image when present (Codex: CODEX_ENV_PYTHON_VERSION).
# ===========================================================================
register_module python
provides_tool python python3 CODEX_ENV_PYTHON_VERSION
# Pre-approve the Python toolchain for Claude Code sessions.
provides_perms python "Bash(python:*)" "Bash(python3:*)" "Bash(pip:*)" "Bash(pip3:*)" "Bash(pytest:*)"
need_host cache.nixos.org          "prebuilt CPython from the Nix cache"
want_host pypi.org                 "Python package index metadata"
want_host files.pythonhosted.org   "Python package wheels / sdists"

module_python() {
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v python3 >/dev/null 2>&1; then
    ok "python: adopted existing $(python3 --version 2>&1) ($(command -v python3))."
    return 0
  fi
  log "Installing CPython 3 via Nix..."
  nix_ensure python3 nixpkgs#python3 --accept-flake-config
  command -v python3 >/dev/null 2>&1 || die "python3 not on PATH after install."
  ok "python ready: $(python3 --version 2>&1)"
}
