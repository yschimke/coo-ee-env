
# ===========================================================================
#  module: android
#    software : full Android SDK (Nix androidenv; under ?devenv, devenv's native
#               android integration over the same androidenv) — platform-tools
#               (adb), cmdline-tools, the requested platforms + build-tools (and,
#               when android-emulator is also requested, the emulator + system
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
#  Pulls in `android-cli` automatically — Google's official Android CLI agent
#  tool (the `android` command) — so any box with the SDK also has the
#  agent-first CLI on PATH. The CLI is a lightweight standalone binary and does
#  not pull the SDK back; request `android-cli` on its own for just the tool.
# ===========================================================================
# coo.ee:implies android-cli
register_module android
provides_tool android adb   # adopt a complete existing SDK (adb on PATH, or discovered on disk)
need_host cache.nixos.org        "prebuilt androidenv dependencies from the Nix cache"
want_host dl.google.com          "Android SDK components (platforms, build-tools, system images)"
want_host maven.google.com       "AndroidX / AGP artifacts"
want_host androidx.dev            "AndroidX snapshot builds (androidx.dev/snapshots)"
want_host packages.jetbrains.team "JetBrains-hosted Compose/tooling artifacts"
want_host cache-redirector.jetbrains.com "Kotlin Gradle plugin CDN redirector (Kotlin/Native, compiler artifacts)"
want_host download.jetbrains.com "Kotlin/Native dependencies (LLVM, sysroots, toolchains)"
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

# Locate a complete SDK already on the box, echoing its path (nothing on miss).
# An explicit pointer wins and *suppresses* probing: when ANDROID_HOME /
# ANDROID_SDK_ROOT is set we consider only that location — adopt it if complete,
# otherwise install — and never second-guess an explicit choice by hunting
# elsewhere (this is what lets an emptied ANDROID_HOME force the Nix build path).
# When neither is set we recover an SDK the image shipped but never exported:
# adb's own tree first, then the conventional install locations. Discovery does
# NOT require adb on PATH — an image shipping the SDK without exporting anything
# is precisely the case this rescues.
cooee_android_discover_sdk() {
  local c adb_path
  if [[ -n "${ANDROID_HOME:-}" || -n "${ANDROID_SDK_ROOT:-}" ]]; then
    c="${ANDROID_HOME:-${ANDROID_SDK_ROOT}}"
    cooee_sdk_is_complete "$c" && { printf '%s\n' "$c"; return 0; }
    return 1
  fi
  if adb_path=$(command -v adb 2>/dev/null); then
    c=${adb_path%/platform-tools/adb}
    [[ "$c" != "$adb_path" ]] && cooee_sdk_is_complete "$c" && { printf '%s\n' "$c"; return 0; }
  fi
  for c in /opt/android-sdk "$HOME/.android-sdk" "$HOME/Android/Sdk" \
           /usr/lib/android-sdk /usr/local/lib/android/sdk "$HOME/.android/sdk"; do
    cooee_sdk_is_complete "$c" && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# Presence hook for the framework (module_present): android counts as already
# provided not only when adb is on PATH, but whenever a complete SDK can be
# discovered on disk — so a box that ships the SDK isn't forced through a
# redundant Nix install / host preflight just because nothing exported it yet.
cooee_present_android() {
  command -v adb >/dev/null 2>&1 || cooee_android_discover_sdk >/dev/null 2>&1
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

  # Adopt a complete SDK already on the box — one an image both installed and
  # exported (ANDROID_HOME/adb), OR one it shipped at a conventional location but
  # never exported (discovery recovers it). Bare `android` (no requested levels)
  # adopts as-is; an explicit level request only adopts when every requested
  # platform is already present — otherwise we install a known-good SDK below.
  # Independent of COOEE_FORCE: a ready SDK is the right answer whether or not
  # we're re-provisioning.
  local sdk
  if sdk=$(cooee_android_discover_sdk); then
    local missing=() l
    for l in "${levels[@]}"; do
      [[ -d "$sdk/platforms/android-$l" ]] || missing+=("$l")
    done
    if (( ${#missing[@]} == 0 )); then
      add_env ANDROID_HOME "$sdk"
      add_env ANDROID_SDK_ROOT "$sdk"
      # The SDK may have been on disk with nothing on PATH (the image exported
      # neither the vars nor the tools). Wire platform-tools + cmdline-tools in so
      # adb/sdkmanager resolve here and in every later shell — the missing piece
      # that had the agent complaining about ANDROID_HOME.
      command -v adb >/dev/null 2>&1 \
        || add_env PATH "$sdk/platform-tools:$sdk/cmdline-tools/latest/bin:$PATH"
      cooee_android_pin_sdk_dir "$sdk"
      (( ${#params[@]} )) && warn "requested Android platforms: ${params[*]} (already present in $sdk)."
      ok "android: adopted complete SDK at $sdk ($(adb --version 2>/dev/null | head -1 || echo adb))."
      return 0
    fi
    warn "android: existing SDK at $sdk lacks platform(s): ${missing[*]} — installing a complete SDK via Nix."
  fi

  # Build a complete SDK. The backend decides HOW: the nix backend builds an
  # androidenv expression directly; the ?devenv backend writes a native `android`
  # integration into its devenv project and lets devenv build it. Both fetch the
  # SDK components from dl.google.com (fixed-output derivations) over the Nix
  # closure from cache.nixos.org, both honor the i686/ncurses5 stub, and both
  # return the SDK dir (…/libexec/android-sdk) — so everything below is shared.
  command -v nix >/dev/null 2>&1 || die "android: nix is required to install the SDK but isn't on PATH — re-run with COOEE_FORCE=1 so the base module installs it first."

  # Default to one platform when none was requested. The build needs every level
  # that either a platform or a system image targets.
  (( ${#levels[@]} )) || levels=("$COOEE_ANDROID_DEFAULT_PLATFORM")
  (( want_emu && ${#img_levels[@]} == 0 )) && img_levels=("${levels[@]}")
  local -a all_levels=()
  local l; for l in "${levels[@]}" "${img_levels[@]}"; do
    [[ " ${all_levels[*]:-} " == *" $l "* ]] || all_levels+=("$l")
  done

  # System image types: Google APIs always, plus Wear OS when a wear-NN platform
  # was requested. Only consulted when the emulator (hence system images) is
  # installed, but computed unconditionally so the backend always has them.
  local -a img_types=(google_apis)
  cooee_android_wants_wear "${params[@]}" && img_types+=(android-wear)

  # Hand the structured, backend-neutral request to the backend hook via the
  # agreed _COOEE_ANDROID_* globals, then let it provision. The hook sets
  # COOEE_ANDROID_SDK_DIR (and die()s on failure — called directly, NOT in a
  # command substitution, so the die exits the whole script rather than a subshell).
  _COOEE_ANDROID_LEVELS=("${all_levels[@]}")
  _COOEE_ANDROID_IMG_TYPES=("${img_types[@]}")
  _COOEE_ANDROID_WANT_EMU=$want_emu

  log "Installing Android SDK (platforms: ${all_levels[*]}; build-tools ${COOEE_ANDROID_BUILD_TOOLS}$( (( want_emu )) && printf '; emulator + system images' )) ..."
  cooee_backend_android_sdk
  sdk="${COOEE_ANDROID_SDK_DIR:-}"
  [[ -n "$sdk" && -d "$sdk" ]] || die "android: backend did not return a valid SDK dir (got: '${sdk}')."

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
