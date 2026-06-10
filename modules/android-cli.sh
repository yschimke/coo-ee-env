
# ===========================================================================
#  module: android-cli — Google's Android CLI (the agent-first `android` tool)
#    type     : a single prebuilt binary from Google (NOT a Nix package, NOT a
#               Claude SKILL.md). The official Android CLI from
#               developer.android.com/tools/agents — it standardizes agent-driven
#               Android workflows (scaffold projects, manage AVDs, run Journeys)
#               and is the entry point to the Android skills + Knowledge Base.
#               `android init` registers its agent skill into a project.
#    software : the `android` binary, downloaded to ~/.local/bin and put on PATH.
#               It self-bootstraps the rest of its payload on first run.
#    params   : none.
#    hosts    : dl.google.com (the binary + its first-run payload)
#  A one-token install — `curl -fsSL https://env.coo.ee/android-cli | bash`. The
#  `android` SDK module implies this, so selecting the SDK installs the CLI too.
#  Standalone (it does NOT pull in the heavyweight Nix SDK): the CLI manages its
#  own SDK on demand. Pair it with `android` when you want the Nix-built SDK too.
# ===========================================================================
register_module android-cli
provides_tool android-cli android   # adopt an Android CLI already on PATH
need_host dl.google.com "download of the Android CLI binary and its first-run payload"

# Where the official install.sh puts it. We manage PATH via the env profile
# (add_env) rather than editing shell rc files the way install.sh does.
COOEE_ANDROID_CLI_BIN_DIR="${COOEE_ANDROID_CLI_BIN_DIR:-$HOME/.local/bin}"

module_android-cli() {
  # Adopt an Android CLI already on PATH (a warm box, or a previous run's install).
  if command -v android >/dev/null 2>&1; then
    add_env PATH "$(dirname "$(command -v android)"):$PATH"
    ok "android-cli: adopted existing Android CLI ($(command -v android))."
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

  local dir="$COOEE_ANDROID_CLI_BIN_DIR" bin="$COOEE_ANDROID_CLI_BIN_DIR/android"
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

  ok "android-cli ready: 'android' installed at $bin. Run 'android init' in a project to register its agent skill."
}
