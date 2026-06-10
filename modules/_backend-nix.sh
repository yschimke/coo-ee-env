
# ===========================================================================
#  BACKEND: nix profile (default)
# ---------------------------------------------------------------------------
#  Spliced in by the renderer when ?devenv is absent. Packages install
#  straight into the default Nix profile. Defines the backend contract the
#  modules rely on: nix_ensure + the cooee_backend_* hooks. The devenv backend
#  (_backend-devenv.sh) is the alternative implementation of the same contract;
#  exactly one is ever present in a rendered script.
# ===========================================================================

# Hook: extra provisioning after Nix is on PATH (called by module_base). The
# nix backend needs nothing beyond Nix itself.
cooee_backend_setup() { :; }

# Hook: which of the requested JDK majors to actually install. The nix profile
# gives each install its own --priority, so multiple JDKs coexist — install all.
cooee_backend_jdks() { printf '%s\n' "$@"; }

# ---- idempotent nix package install ---------------------------------------
# Safe to run repeatedly: installs only what's missing, treats an already
# present package as success, so the whole script is a no-op on a warm box
# and a repair on a cold/partial one.
nix_ensure() {  # nix_ensure <match> <flakeref> [extra nix flags...]
  local match=$1; shift
  if nix profile list 2>/dev/null | grep -qiF -- "$match"; then
    ok "already present: $match"; return 0
  fi
  local out
  if out=$(nix profile install "$@" 2>&1); then
    ok "installed: $match"
  elif grep -qiF "already installed" <<<"$out"; then
    ok "already present: $match"
  else
    printf '%s\n' "$out" >&2
    return 1
  fi
}
