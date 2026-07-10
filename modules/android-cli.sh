
# ===========================================================================
#  module: android-cli — Google's Android CLI (the agent-first `android` tool)
#    type     : a single prebuilt binary from Google (NOT a Nix package, NOT a
#               Claude SKILL.md). The official Android CLI from
#               developer.android.com/tools/agents — it standardizes agent-driven
#               Android workflows (scaffold projects, manage AVDs, run Journeys)
#               and is the entry point to the Android skills + Knowledge Base.
#               After install we run `android init` to register its agent skill.
#    software : the `android` binary, downloaded to ~/.local/bin and put on PATH.
#               It self-bootstraps the rest of its payload on first run.
#    params   : none.
#    hosts    : dl.google.com (the binary + its first-run payload)
#  A one-token install — `curl -fsSL https://env.coo.ee/android-cli | bash`. The
#  `android` SDK module implies this, so selecting the SDK installs the CLI too.
#  Standalone (it does NOT pull in the heavyweight Nix SDK): the CLI manages its
#  own SDK on demand. Pair it with `android` when you want the Nix-built SDK too.
#  Not a top-level pick: it rides along with `android` (which implies it) or
#  installs via its own one-liner, but the picker leaves it off the module list.
# ===========================================================================
# coo.ee:hidden
register_module android-cli
provides_tool android-cli android   # adopt an Android CLI already on PATH
# Pre-approve Google's agent-first `android` CLI for Claude Code sessions.
provides_perms android-cli "Bash(android:*)"
need_host dl.google.com "download of the Android CLI binary and its first-run payload"

# Where the official install.sh puts it. We manage PATH via the env profile
# (add_env) rather than editing shell rc files the way install.sh does.
COOEE_ANDROID_CLI_BIN_DIR="${COOEE_ANDROID_CLI_BIN_DIR:-$HOME/.local/bin}"

# Register the android-cli agent skill with `android init`. It installs into the
# detected agent skills dir (~/.claude, ~/.gemini/antigravity/skills, ...), i.e.
# the home dir — not this repo. Run non-interactively (stdin from /dev/null so it
# can never hang) and advisory: a hiccup here doesn't fail the provision, the CLI
# itself is installed. Opt out with COOEE_ANDROID_CLI_INIT=0.
cooee_android_cli_init() {  # cooee_android_cli_init <android binary>
  local bin=$1
  if [[ "${COOEE_ANDROID_CLI_INIT:-1}" == 0 ]]; then
    log "android-cli: skipping 'android init' (COOEE_ANDROID_CLI_INIT=0)."
    return 0
  fi
  log "android-cli: registering the agent skill via 'android init'..."
  if "$bin" init </dev/null >/dev/null 2>&1; then
    ok "android-cli: 'android init' registered the android-cli agent skill."
  else
    warn "android-cli: 'android init' didn't complete (network, or it wants"
    warn "interactive agent selection). Run 'android init' yourself to register"
    warn "the skill, or set COOEE_ANDROID_CLI_INIT=0 to silence this."
  fi
}

module_android-cli() {
  local bin
  # Adopt an Android CLI already on PATH (a warm box, or a previous run's install).
  if command -v android >/dev/null 2>&1; then
    bin="$(command -v android)"
    add_env PATH "$(dirname "$bin"):$PATH"
    ok "android-cli: adopted existing Android CLI ($bin)."
    cooee_android_cli_init "$bin"
    return 0
  fi

  command -v curl >/dev/null 2>&1 || die "android-cli: curl is required to download the Android CLI."

  # Map this host to Google's published build, mirroring the official install.sh.
  local os arch url_os
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os $arch" in
    "Linux x86_64")  url_os="linux_x86_64"  ;;
    "Darwin x86_64") url_os="darwin_x86_64" ;;
    "Darwin arm64")  url_os="darwin_arm64"  ;;
    *) die "android-cli: no Android CLI build for '$os $arch' (supported: Linux x86_64, macOS x86_64/arm64)." ;;
  esac

  local dir="$COOEE_ANDROID_CLI_BIN_DIR"
  bin="$dir/android"
  mkdir -p "$dir"

  log "Downloading the Android CLI ($url_os) from dl.google.com..."
  curl -fsSL "https://dl.google.com/android/cli/latest/${url_os}/android" -o "$bin" \
    || die "android-cli: download failed (is dl.google.com reachable?)."
  chmod +x "$bin"

  # Persist the bin dir on PATH for this and every later shell — via the env
  # profile, not ~/.bashrc (that's the installer's job; we own our own profile).
  add_env PATH "$dir:$PATH"
  export PATH="$dir:$PATH"

  # Force the binary's first-run self-download, exactly as install.sh does. Don't
  # fail the provision if this network step hiccups — the binary is in place and
  # will finish bootstrapping on first real use.
  ANDROID_CLI_FRESH_INSTALL=1 "$bin" >/dev/null 2>&1 \
    || warn "android-cli: first-run bootstrap didn't finish (network?); the 'android' binary is installed and bootstraps on first use."

  ok "android-cli ready: 'android' installed at $bin."

  # Register the agent skill (the whole point of installing the CLI for agents).
  cooee_android_cli_init "$bin"
}
