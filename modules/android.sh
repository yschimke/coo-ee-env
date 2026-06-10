
# ===========================================================================
#  module: android
#    software : full Android SDK via Nix androidenv — platform-tools (adb),
#               cmdline-tools, the requested platforms + build-tools (and, when
#               android-emulator is also requested, the emulator + system
#               images). ANDROID_HOME / ANDROID_SDK_ROOT point at it, and
#               (for a Gradle project rooted here) sdk.dir is pinned in
#               local.properties so AGP finds the SDK even when the env vars
#               don't reach the build.
#    params   : android[36] selects the platform API level(s) to install
#               (e.g. android[30,36,wear-33]); bare `android` installs the
#               default (API 36).
#    hosts    : cache.nixos.org (install), dl.google.com (SDK component sources)
#             : Google / JetBrains / fonts registries (build, advisory)
#  Host set mirrors skills/compose-preview/references/agent-cloud.md.
#  Assumes `java` is also requested (Android builds need a JDK).
#
#  Pulls in the `android-cli` agent skill automatically (and android-cli pulls
#  android back), so the skill that drives adb/sdkmanager/gradle and the SDK it
#  drives always travel together. Opt the skill out with `android` on its own
#  is not possible by design; use `skills`/`tools` for a bespoke setup instead.
# ===========================================================================
# coo.ee:implies android-cli
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

# Pin the SDK location in the project's local.properties. AGP resolves the SDK
# from local.properties' sdk.dir first, and only then from the ANDROID_HOME /
# ANDROID_SDK_ROOT env vars. Some harnesses launch `./gradlew` in a shell that
# never sourced our persisted env, so those vars are absent and the build dies
# with "SDK location not found"; an explicit sdk.dir makes the SDK findable no
# matter how the build is started. local.properties is machine-specific (the
# Nix store path is unique to this container) and conventionally gitignored, so
# we (re)write it on every provision rather than commit it — preserving any
# other entries already in the file.
cooee_android_pin_sdk_dir() {  # cooee_android_pin_sdk_dir <sdk dir>
  local sdk=$1 f=local.properties m found=0
  # Only act for a Gradle project rooted here — the build that reads sdk.dir.
  for m in settings.gradle settings.gradle.kts build.gradle build.gradle.kts gradlew; do
    [[ -e "$m" ]] && { found=1; break; }
  done
  (( found )) || return 0

  if [[ -f "$f" ]] && grep -q '^[[:space:]]*sdk\.dir[[:space:]]*=' "$f"; then
    local cur
    cur=$(sed -n 's/^[[:space:]]*sdk\.dir[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$f" | head -1)
    [[ "$cur" == "$sdk" ]] && { log "android: local.properties already pins sdk.dir=$sdk."; return 0; }
    local tmp; tmp=$(mktemp)
    # Rewrite the stale sdk.dir line in place; keep every other entry untouched.
    sed "s|^[[:space:]]*sdk\.dir[[:space:]]*=.*|sdk.dir=$sdk|" "$f" > "$tmp" && mv "$tmp" "$f"
    ok "android: updated sdk.dir in $PWD/local.properties -> $sdk."
  else
    printf 'sdk.dir=%s\n' "$sdk" >> "$f"
    ok "android: wrote sdk.dir to $PWD/local.properties -> $sdk."
  fi
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
      cooee_android_pin_sdk_dir "$sdk"
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

  # On x86_64 Linux, androidenv unconditionally drags in 32-bit (i686) glibc,
  # zlib and ncurses5 as legacy runtime libs for ancient 32-bit build-tool
  # binaries — the modern 64-bit build-tools we install need none of them.
  # glibc/zlib substitute from the cache, but the niche ncurses5 (an
  # abiVersion=5 override, "ncurses-abi5-compat") usually isn't cached, so Nix
  # *builds* it — and building anything i686 runs a 32-bit builder, which dies
  # with "Exec format error" on kernels without 32-bit x86 support (common in
  # minimal cloud containers). Swap a native, empty stub in its place so the SDK
  # build never needs a 32-bit builder. Off only where you genuinely need the
  # 32-bit legacy build-tools on a 32-bit-capable host: COOEE_ANDROID_NCURSES5_STUB=0.
  local overlays_nix=""
  if [[ "${COOEE_ANDROID_NCURSES5_STUB:-1}" != 0 && "$(uname -m)" == x86_64 ]]; then
    overlays_nix="overlays = [
        (final: prev: {
          pkgsi686Linux = prev.pkgsi686Linux.extend (i686final: i686prev: {
            ncurses5 = prev.runCommand \"ncurses5-stub\" { } \"mkdir -p \$out/lib \$out/include\";
          });
        })
      ];"
  fi

  local expr="let
    pkgs = import (builtins.getFlake \"nixpkgs\").outPath {
      system = builtins.currentSystem;
      config.allowUnfree = true;
      config.android_sdk.accept_license = true;
      ${overlays_nix}
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
    die "android: SDK build failed. Common causes: dl.google.com unreachable; the requested platform/build-tools versions are absent from nixpkgs (override COOEE_ANDROID_BUILD_TOOLS / COOEE_ANDROID_DEFAULT_PLATFORM); or the build tried to compile 32-bit (i686) ncurses on a kernel without 32-bit x86 support ('Exec format error' — keep the default COOEE_ANDROID_NCURSES5_STUB=1 that stubs it out)."
  fi

  sdk="$out/libexec/android-sdk"
  add_env ANDROID_HOME "$sdk"
  add_env ANDROID_SDK_ROOT "$sdk"
  cooee_android_pin_sdk_dir "$sdk"

  # Put the SDK's tools on PATH (and persist it) so adb / sdkmanager / emulator
  # resolve in this and every later shell.
  local bins="$sdk/platform-tools:$sdk/cmdline-tools/latest/bin"
  (( want_emu )) && bins+=":$sdk/emulator"
  add_env PATH "$bins:$PATH"

  command -v adb >/dev/null 2>&1 || die "android: adb not on PATH after install ($sdk)."
  ok "android SDK ready at $sdk: $(adb --version 2>/dev/null | head -1 || echo adb)"
  warn "platforms ${all_levels[*]} + build-tools ${COOEE_ANDROID_BUILD_TOOLS} installed (ANDROID_HOME=$sdk)."
}
