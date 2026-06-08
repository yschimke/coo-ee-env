
# ===========================================================================
#  module: android
#    software : full Android SDK via Nix androidenv — platform-tools (adb),
#               cmdline-tools, the requested platforms + build-tools (and, when
#               android-emulator is also requested, the emulator + system
#               images). ANDROID_HOME / ANDROID_SDK_ROOT point at it.
#    params   : android[36] selects the platform API level(s) to install
#               (e.g. android[30,36,wear-33]); bare `android` installs the
#               default (API 36).
#    hosts    : cache.nixos.org (install), dl.google.com (SDK component sources)
#             : Google / JetBrains / fonts registries (build, advisory)
#  Host set mirrors skills/compose-preview/references/agent-cloud.md.
#  Assumes `java` is also requested (Android builds need a JDK).
# ===========================================================================
register_module android
provides_tool android adb   # adopt a complete existing SDK (adb on PATH)
need_host cache.nixos.org        "prebuilt androidenv dependencies from the Nix cache"
want_host dl.google.com          "Android SDK components (platforms, build-tools, system images)"
want_host maven.google.com       "AndroidX / AGP artifacts"
want_host packages.jetbrains.team "JetBrains-hosted Compose/tooling artifacts"
want_host "*.jetbrains.com"       "JetBrains downloads, plugins, Compose artifacts"
want_host fonts.googleapis.com   "downloadable font metadata (Compose)"
want_host fonts.gstatic.com      "downloadable font binaries (Compose)"

# Defaults (overridable from the environment). The platform level used when a
# bare `android` is requested, and the build-tools revision to install. Pinning
# them keeps a param-less install reproducible; override for a different target.
COOEE_ANDROID_DEFAULT_PLATFORM="${COOEE_ANDROID_DEFAULT_PLATFORM:-36}"
COOEE_ANDROID_BUILD_TOOLS="${COOEE_ANDROID_BUILD_TOOLS:-36.0.0}"

# Map request params (e.g. 30, 37, wear-33) to numeric platform API levels,
# deduped in input order. A `wear-NN` param contributes level NN (the wear
# system image type is added separately). Anything non-numeric is dropped.
cooee_android_levels() {  # cooee_android_levels <param>...
  local p lvl seen=" "
  for p in "$@"; do
    if [[ "$p" =~ ^wear-([0-9]+)$ || "$p" =~ ^([0-9]+)$ ]]; then
      lvl="${BASH_REMATCH[1]}"
      [[ "$seen" == *" $lvl "* ]] || { printf '%s\n' "$lvl"; seen+="$lvl "; }
    fi
  done
}

# True if any requested param names a Wear OS platform (wear-NN).
cooee_android_wants_wear() {  # cooee_android_wants_wear <param>...
  local p; for p in "$@"; do [[ "$p" =~ ^wear- ]] && return 0; done; return 1
}

# An SDK is "complete" (worth adopting as-is) when it already carries at least
# one installed platform and one build-tools revision — i.e. it can build, not
# just run adb. A platform-tools-only tree (adb but no platforms) is not.
cooee_sdk_is_complete() {  # cooee_sdk_is_complete <sdk dir>
  local s=$1
  [[ -d "$s/platforms"   ]] && compgen -G "$s/platforms/android-*" >/dev/null 2>&1 \
  && [[ -d "$s/build-tools" ]] && compgen -G "$s/build-tools/*"    >/dev/null 2>&1
}

module_android() {
  # Requested platform API levels come from the params (android[30,36,wear-33]);
  # default to COOEE_ANDROID_DEFAULT_PLATFORM (API 36) when none are given.
  # Recorded in COOEE_ANDROID_PLATFORMS for reference; the module installs them
  # below (independent of where adb comes from, so record before the branch).
  local -a params=("$@")
  (( ${#params[@]} )) || params=("$COOEE_ANDROID_DEFAULT_PLATFORM")
  add_env COOEE_ANDROID_PLATFORMS "${params[*]}"

  local -a levels=()
  mapfile -t levels < <(cooee_android_levels "${params[@]}")

  # Does the request also include android-emulator? It runs *after* us (canonical
  # order), but it's already registered and its params are already injected, so
  # we build the emulator + system images into the same SDK now. Its image levels
  # come from its params; fall back to the platform levels when it has none.
  local want_emu=0
  local -a img_levels=()
  if printf '%s\n' "${MODULES[@]}" | grep -qx android-emulator; then
    want_emu=1
    local emu_params="${_MODULE_PARAMS[android-emulator]:-}"
    mapfile -t img_levels < <(cooee_android_levels ${emu_params//,/ })
  fi

  # Adopt a complete SDK already on the box (a warm box or a CI runner that ships
  # the full SDK). Bare `android` (no requested levels) adopts as-is; an explicit
  # level request only adopts when every requested platform is already present —
  # otherwise we install a known-good SDK below. Independent of COOEE_FORCE: a
  # ready SDK is the right answer whether or not we're re-provisioning.
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/.android/sdk}}"
  if command -v adb >/dev/null 2>&1 && cooee_sdk_is_complete "$sdk"; then
    local missing=() l
    for l in "${levels[@]}"; do
      [[ -d "$sdk/platforms/android-$l" ]] || missing+=("$l")
    done
    if (( ${#missing[@]} == 0 )); then
      add_env ANDROID_HOME "$sdk"
      add_env ANDROID_SDK_ROOT "$sdk"
      (( ${#params[@]} )) && warn "requested Android platforms: ${params[*]} (already present in $sdk)."
      ok "android: adopted complete SDK at $sdk ($(adb --version 2>/dev/null | head -1 || echo adb))."
      return 0
    fi
    warn "android: existing SDK at $sdk lacks platform(s): ${missing[*]} — installing a complete SDK via Nix."
  fi

  # Build a complete SDK with Nix (androidenv). cache.nixos.org provides the Nix
  # closure; the SDK components themselves are fetched from dl.google.com as
  # fixed-output derivations, so that host must be reachable for this step.
  command -v nix >/dev/null 2>&1 || die "android: nix is required to install the SDK but isn't on PATH — re-run with COOEE_FORCE=1 so the base module installs it first."

  # Default to one platform when none was requested. The build needs every level
  # that either a platform or a system image targets.
  (( ${#levels[@]} )) || levels=("$COOEE_ANDROID_DEFAULT_PLATFORM")
  (( want_emu && ${#img_levels[@]} == 0 )) && img_levels=("${levels[@]}")
  local -a all_levels=() seen=()
  local l; for l in "${levels[@]}" "${img_levels[@]}"; do
    [[ " ${all_levels[*]:-} " == *" $l "* ]] || all_levels+=("$l")
  done

  # Compose the Nix expression. Quote each level as a string list element.
  local platforms_nix="" img_types_nix='"google_apis"'
  for l in "${all_levels[@]}"; do platforms_nix+="\"$l\" "; done
  cooee_android_wants_wear "${params[@]}" && img_types_nix+=' "android-wear"'

  local emu_bool="false"; (( want_emu )) && emu_bool="true"
  local expr="let
    pkgs = import (builtins.getFlake \"nixpkgs\").outPath {
      system = builtins.currentSystem;
      config.allowUnfree = true;
      config.android_sdk.accept_license = true;
    };
  in (pkgs.androidenv.composeAndroidPackages {
    platformVersions   = [ ${platforms_nix}];
    buildToolsVersions = [ \"${COOEE_ANDROID_BUILD_TOOLS}\" ];
    includeEmulator     = ${emu_bool};
    includeSystemImages = ${emu_bool};
    systemImageTypes    = [ ${img_types_nix} ];
    abiVersions         = [ \"x86_64\" ];
  }).androidsdk"

  log "Installing Android SDK via Nix androidenv (platforms: ${all_levels[*]}; build-tools ${COOEE_ANDROID_BUILD_TOOLS}$( (( want_emu )) && printf '; emulator + system images' )) ..."
  export NIXPKGS_ALLOW_UNFREE=1

  # --out-link doubles as a GC root so the SDK survives `nix store gc`; the store
  # path is printed to stdout for us to anchor ANDROID_HOME at.
  local link="$HOME/.cache/coo-ee/android-sdk"
  mkdir -p "$(dirname "$link")"
  local out
  if ! out=$(nix build --impure --print-out-paths --out-link "$link" --expr "$expr"); then
    die "android: SDK build failed. Check that dl.google.com is reachable and the requested platform/build-tools versions exist in nixpkgs (override COOEE_ANDROID_BUILD_TOOLS / COOEE_ANDROID_DEFAULT_PLATFORM)."
  fi

  sdk="$out/libexec/android-sdk"
  add_env ANDROID_HOME "$sdk"
  add_env ANDROID_SDK_ROOT "$sdk"

  # Put the SDK's tools on PATH (and persist it) so adb / sdkmanager / emulator
  # resolve in this and every later shell.
  local bins="$sdk/platform-tools:$sdk/cmdline-tools/latest/bin"
  (( want_emu )) && bins+=":$sdk/emulator"
  add_env PATH "$bins:$PATH"

  command -v adb >/dev/null 2>&1 || die "android: adb not on PATH after install ($sdk)."
  ok "android SDK ready at $sdk: $(adb --version 2>/dev/null | head -1 || echo adb)"
  warn "platforms ${all_levels[*]} + build-tools ${COOEE_ANDROID_BUILD_TOOLS} installed (ANDROID_HOME=$sdk)."
}
