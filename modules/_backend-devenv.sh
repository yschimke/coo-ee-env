
# ===========================================================================
#  BACKEND: devenv.sh  (https://devenv.sh/ad-hoc-developer-environments/)
# ---------------------------------------------------------------------------
#  Spliced in by the renderer for a `?devenv` request, in place of
#  _backend-nix.sh. Same contract (nix_ensure + cooee_backend_* hooks), but
#  packages are provisioned through a single devenv.sh environment: devenv is
#  installed on top of Nix, each nixpkgs attr a module would `nix profile
#  install` is written into a generated devenv.nix, devenv builds the
#  environment, and its profile bin dir is prepended to PATH — so the tool
#  resolves immediately afterwards exactly as the nix-profile backend's does.
#
#  We write a real (minimal) devenv.nix rather than the newer ad-hoc
#  `--option packages:pkgs` flag: it works on any devenv version and sidesteps
#  the empty-directory edge cases ad-hoc invocations hit on a fresh project.
# ===========================================================================
COOEE_DEVENV_DIR="${COOEE_DEVENV_DIR:-$HOME/.config/coo-ee/devenv}"
_COOEE_DEVENV_PKGS=()       # nixpkgs attrs accumulated across nix_ensure calls
_COOEE_DEVENV_ANDROID=""    # generated `android = { … };` block (see android hook)
_COOEE_DEVENV_OVERLAYS=""   # generated `overlays = [ … ];` block (ncurses5 stub)

# Hook: install devenv on top of Nix and seed the project (called by module_base
# once Nix is on PATH).
cooee_backend_setup() { cooee_devenv_install; }

# Hook: which JDK majors to install. A single devenv profile is one buildEnv and
# can't hold two JDKs at once — their files (lib/modules, …) collide, and the
# per-install --priority the nix backend uses to break that tie isn't available.
# Install just the first (lowest) requested major, and say so.
cooee_backend_jdks() {
  if (( $# > 1 )); then
    warn "java: devenv backend provisions a single JDK; using $1 (requested: $*)."
  fi
  printf '%s\n' "${1:-}"
}

# Hook: provision the Android SDK as a native devenv `android` integration —
# devenv's first-class wrapper over the same androidenv. Writes the android
# config (and the i686/ncurses5 stub overlay) into the devenv project, lets
# devenv build it, and sets COOEE_ANDROID_SDK_DIR from the ANDROID_HOME the
# integration exports (…/libexec/android-sdk). Inputs arrive in the
# _COOEE_ANDROID_* globals; die()s on failure (call directly, not in $()).
cooee_backend_android_sdk() {
  command -v devenv >/dev/null 2>&1 || die "android: devenv not on PATH (base's cooee_backend_setup should have installed it)."
  cooee_devenv_seed_project

  local -a levels=("${_COOEE_ANDROID_LEVELS[@]}")
  local -a img_types=("${_COOEE_ANDROID_IMG_TYPES[@]}")
  local want_emu="${_COOEE_ANDROID_WANT_EMU:-0}"

  # The Android SDK is unfree; devenv gates that in devenv.yaml (not devenv.nix).
  cooee_devenv_allow_unfree

  # Build the android config block for devenv.nix. devenv's android integration
  # takes platform/build-tools versions as strings and installs system images
  # (and the emulator) only when enabled — mirroring the nix backend's expr.
  local platforms_nix="" img_types_nix="" l t
  for l in "${levels[@]}"; do platforms_nix+="\"$l\" "; done
  for t in "${img_types[@]}"; do img_types_nix+="\"$t\" "; done
  local emu_bool="false"; (( want_emu )) && emu_bool="true"

  _COOEE_DEVENV_ANDROID="  android = {
    enable = true;
    platforms.version = [ ${platforms_nix}];
    buildTools.version = [ \"${COOEE_ANDROID_BUILD_TOOLS}\" ];
    abis = [ \"x86_64\" ];
    systemImageTypes = [ ${img_types_nix}];
    systemImages.enable = ${emu_bool};
    emulator.enable = ${emu_bool};
  };"

  # Same i686/ncurses5 stub the nix backend applies (see _backend-nix.sh for the
  # rationale): devenv's android integration honors top-level nixpkgs overlays,
  # so route the stub through `overlays`.
  if [[ "${COOEE_ANDROID_NCURSES5_STUB:-1}" != 0 && "$(uname -m)" == x86_64 ]]; then
    _COOEE_DEVENV_OVERLAYS="  overlays = [
    (final: prev: {
      pkgsi686Linux = prev.pkgsi686Linux.extend (i686final: i686prev: {
        ncurses5 = prev.runCommand \"ncurses5-stub\" { } \"mkdir -p \$out/lib \$out/include\";
      });
    })
  ];"
  fi

  cooee_devenv_write_config

  local dir="$COOEE_DEVENV_DIR"
  log "android: building the SDK via devenv's native android integration (platforms: ${levels[*]}; build-tools ${COOEE_ANDROID_BUILD_TOOLS})..."
  ( cd "$dir" && devenv shell bash -- -c 'true' ) \
    || die "android: devenv failed to build the Android environment. Common causes: dl.google.com unreachable; the requested platform/build-tools versions are unavailable; or a 32-bit (i686) ncurses build on a kernel without 32-bit x86 support (keep the default COOEE_ANDROID_NCURSES5_STUB=1)."

  # The integration exports ANDROID_HOME (…/libexec/android-sdk); read it back
  # from inside the devenv shell, the same way cooee_devenv_sync reads DEVENV_PROFILE.
  local sdk
  sdk=$( cd "$dir" && devenv shell bash -- -c 'printf %s "${ANDROID_HOME:-}"' 2>/dev/null ) || true
  [[ -n "$sdk" && -d "$sdk" ]] || die "android: could not resolve ANDROID_HOME from the devenv environment."
  COOEE_ANDROID_SDK_DIR="$sdk"
}

# Provision <flakeref> by adding its nixpkgs attr to the devenv environment.
# Same signature as the nix backend's nix_ensure; extra nix-profile flags
# (e.g. --priority) don't apply to devenv and are ignored.
nix_ensure() {  # nix_ensure <match> <flakeref> [extra nix flags...]
  local match=$1; shift
  local pkg=${1#nixpkgs#}   # nixpkgs#nodejs_22 -> nodejs_22
  local p
  for p in "${_COOEE_DEVENV_PKGS[@]}"; do
    [[ "$p" == "$pkg" ]] && { ok "already present (devenv): $match"; return 0; }
  done
  _COOEE_DEVENV_PKGS+=("$pkg")
  cooee_devenv_sync || return 1
  ok "installed (devenv): $match"
}

# Install devenv itself (idempotent) into the default Nix profile, then seed the
# project dir. Uses `nix profile install` directly (NOT nix_ensure, which routes
# back through devenv here and would recurse).
cooee_devenv_install() {
  if command -v devenv >/dev/null 2>&1; then
    ok "devenv already installed: $(devenv version 2>/dev/null || echo present)"
  else
    # Prefer the prebuilt nixpkgs#devenv from the binary cache (fast, no Rust
    # source build); --accept-flake-config lets devenv's own cache be used too.
    log "Installing devenv.sh via Nix (prebuilt nixpkgs#devenv)..."
    nix profile install nixpkgs#devenv --accept-flake-config \
      || die "failed to install devenv (nixpkgs#devenv)."
    command -v devenv >/dev/null 2>&1 || die "devenv not on PATH after install."
    ok "devenv ready: $(devenv version 2>/dev/null || echo installed)"
  fi
  cooee_devenv_seed_project
}

# Seed a minimal, valid devenv project in COOEE_DEVENV_DIR: a devenv.yaml that
# pins the nixpkgs input (the same nixpkgs-unstable channel the nix backend
# draws from) and a git repo (devenv reads git-tracked files and is happiest
# inside a repo). Best-effort and idempotent; the package list lands in
# devenv.nix, (re)generated per sync by cooee_devenv_write_config.
cooee_devenv_seed_project() {
  mkdir -p "$COOEE_DEVENV_DIR"
  if [[ ! -f "$COOEE_DEVENV_DIR/devenv.yaml" ]]; then
    cat > "$COOEE_DEVENV_DIR/devenv.yaml" <<'YAML'
# Generated by coo.ee/env for the ?devenv backend — do not hand-edit.
inputs:
  nixpkgs:
    url: github:NixOS/nixpkgs/nixpkgs-unstable
YAML
  fi
  [[ -f "$COOEE_DEVENV_DIR/devenv.nix" ]] || cooee_devenv_write_config
  if command -v git >/dev/null 2>&1 && [[ ! -d "$COOEE_DEVENV_DIR/.git" ]]; then
    ( cd "$COOEE_DEVENV_DIR" \
        && git init -q \
        && git -c user.name=coo.ee -c user.email=coo@ee.invalid \
             -c commit.gpgsign=false add -A \
        && git -c user.name=coo.ee -c user.email=coo@ee.invalid \
             -c commit.gpgsign=false commit -qm "coo.ee devenv seed" ) >/dev/null 2>&1 || true
  fi
}

# (Re)generate devenv.nix from the accumulated package list (and any extra blocks
# the hooks staged: the android integration, the ncurses5 overlay). nixpkgs attrs
# map straight to pkgs.<attr> (nodejs_22 -> pkgs.nodejs_22, temurin-bin-21 -> ...).
cooee_devenv_write_config() {
  local p body=""
  for p in "${_COOEE_DEVENV_PKGS[@]}"; do body+="    pkgs.${p}"$'\n'; done
  {
    printf '%s\n' "# Generated by coo.ee/env for the ?devenv backend — do not hand-edit."
    printf '%s\n' "{ pkgs, ... }:"
    printf '%s\n' "{"
    printf '%s\n' "  packages = ["
    printf '%s' "$body"
    printf '%s\n' "  ];"
    [[ -n "$_COOEE_DEVENV_OVERLAYS" ]] && printf '%s\n' "$_COOEE_DEVENV_OVERLAYS"
    [[ -n "$_COOEE_DEVENV_ANDROID"  ]] && printf '%s\n' "$_COOEE_DEVENV_ANDROID"
    printf '%s\n' "}"
  } > "$COOEE_DEVENV_DIR/devenv.nix"
}

# Ensure devenv.yaml allows unfree packages — required for the Android SDK (the
# integration accepts the SDK licenses itself, but the unfree gate is the user's
# to open). Appends a top-level `nixpkgs.allow_unfree` once; idempotent.
cooee_devenv_allow_unfree() {
  local yaml="$COOEE_DEVENV_DIR/devenv.yaml"
  [[ -f "$yaml" ]] || cooee_devenv_seed_project
  grep -q 'allow_unfree:[[:space:]]*true' "$yaml" 2>/dev/null && return 0
  cat >> "$yaml" <<'YAML'
nixpkgs:
  allow_unfree: true
YAML
}

# Build the environment from the current package list and prepend its profile
# bin dir to PATH (now + persisted, mirroring base.sh's handling of the nix
# profile). devenv maintains a stable $dir/.devenv/profile symlink that
# re-points on each rebuild, so persisting it keeps a future shell's PATH valid
# as packages accrue; DEVENV_PROFILE (the underlying store path) is the fallback.
cooee_devenv_sync() {
  (( ${#_COOEE_DEVENV_PKGS[@]} )) || return 0
  cooee_devenv_write_config
  local dir="$COOEE_DEVENV_DIR"
  log "devenv: building environment (packages: ${_COOEE_DEVENV_PKGS[*]})..."
  ( cd "$dir" && devenv shell bash -- -c 'true' ) \
    || die "devenv: failed to build environment for: ${_COOEE_DEVENV_PKGS[*]}"

  local bin=""
  if [[ -d "$dir/.devenv/profile/bin" ]]; then
    bin="$dir/.devenv/profile/bin"
  else
    local profile
    profile=$( cd "$dir" && devenv shell bash -- -c 'printf %s "${DEVENV_PROFILE:-}"' 2>/dev/null ) || true
    [[ -n "$profile" && -d "$profile/bin" ]] && bin="$profile/bin"
  fi
  [[ -n "$bin" ]] || die "devenv: could not locate the built profile bin dir under $dir."

  # Prepend once — the bin path (a stable symlink) doesn't change between syncs.
  case ":$PATH:" in
    *":$bin:"*) : ;;
    *)
      export PATH="$bin:$PATH"
      echo "export PATH=\"$bin:\$PATH\"" >> "$COOEE_PROFILE"
      printf 'PATH=%s\n' "$PATH" >> "$COOEE_HARNESS_ENV"
      cooee_forward_to_harness "PATH=$PATH"
      ;;
  esac
}
