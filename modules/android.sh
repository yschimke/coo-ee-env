
# ===========================================================================
#  module: android
#    software : android-tools (adb/fastboot) via Nix, ANDROID_HOME
#    params   : android[30,37,wear-33] records platform API levels in
#               COOEE_ANDROID_PLATFORMS for the project's androidenv flake;
#               default 36
#    hosts    : cache.nixos.org (install)
#             : Google / JetBrains / fonts registries (build, advisory)
#  Host set mirrors skills/compose-preview/references/agent-cloud.md.
#  Assumes `java` is also requested (Android builds need a JDK).
# ===========================================================================
register_module android
provides_tool android adb   # adopt existing platform-tools (adb on PATH)
need_host cache.nixos.org        "prebuilt android-tools from the Nix cache"
want_host dl.google.com          "Android SDK cmdline-tools, platforms, build-tools"
want_host maven.google.com       "AndroidX / AGP artifacts"
want_host packages.jetbrains.team "JetBrains-hosted Compose/tooling artifacts"
want_host "*.jetbrains.com"       "JetBrains downloads, plugins, Compose artifacts"
want_host fonts.googleapis.com   "downloadable font metadata (Compose)"
want_host fonts.gstatic.com      "downloadable font binaries (Compose)"

module_android() {
  # Requested platform API levels come from the params (android[30,37,wear-33]);
  # default to 36 (current stable API level) when none are given. We don't
  # provision the licensed SDK here; record the request so the project's
  # androidenv flake can pick the platforms up from the environment. Independent
  # of where adb comes from, so record it before the adopt/install branch.
  local -a platforms=("$@")
  (( ${#platforms[@]} )) || platforms=(36)
  add_env COOEE_ANDROID_PLATFORMS "${platforms[*]}"

  # Adopt existing platform-tools (warm box / base image) when adb is already
  # on PATH — just settle ANDROID_HOME and skip the Nix install.
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v adb >/dev/null 2>&1; then
    local sdk="${ANDROID_HOME:-$HOME/.android/sdk}"
    mkdir -p "$sdk"
    add_env ANDROID_HOME "$sdk"
    (( ${#platforms[@]} )) && warn "requested Android platforms: ${platforms[*]} (COOEE_ANDROID_PLATFORMS)."
    ok "android: adopted existing $(adb --version 2>/dev/null | head -1 || echo adb) (ANDROID_HOME=$sdk)."
    return 0
  fi

  log "Installing Android platform-tools (adb, fastboot) via Nix..."
  export NIXPKGS_ALLOW_UNFREE=1
  nix_ensure android-tools nixpkgs#android-tools --impure

  # The full SDK (platforms + build-tools) is licensed and large, and the
  # versions belong to the project, not this bootstrap. We only set a
  # conventional ANDROID_HOME; the repo's own androidenv flake fills it in.
  local sdk="${ANDROID_HOME:-$HOME/.android/sdk}"
  mkdir -p "$sdk"
  add_env ANDROID_HOME "$sdk"
  ok "android tools ready: $(adb --version 2>/dev/null | head -1 || echo 'adb installed')"
  if (( ${#platforms[@]} )); then
    warn "requested Android platforms: ${platforms[*]}"
    warn "(exported as COOEE_ANDROID_PLATFORMS for the androidenv flake)."
  fi
  warn "ANDROID_HOME=$sdk (platform-tools only); run the project's androidenv"
  warn "flake for platforms/build-tools (see README.md)."
}
