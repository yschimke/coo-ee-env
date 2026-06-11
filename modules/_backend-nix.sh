
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

# Hook: build a complete Android SDK from the request the android module assembled
# in the _COOEE_ANDROID_* globals, and set COOEE_ANDROID_SDK_DIR to its SDK dir
# (…/libexec/android-sdk). The nix backend builds an androidenv expression
# directly with `nix build`. die()s on failure (call it directly, not in a
# command substitution, so the die exits the whole script).
cooee_backend_android_sdk() {
  local -a levels=("${_COOEE_ANDROID_LEVELS[@]}")
  local -a img_types=("${_COOEE_ANDROID_IMG_TYPES[@]}")
  local want_emu="${_COOEE_ANDROID_WANT_EMU:-0}"

  # Compose the Nix expression. Quote each level / image type as a list element.
  local platforms_nix="" img_types_nix="" l t
  for l in "${levels[@]}"; do platforms_nix+="\"$l\" "; done
  for t in "${img_types[@]}"; do img_types_nix+="\"$t\" "; done
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
    systemImageTypes    = [ ${img_types_nix}];
    abiVersions         = [ \"x86_64\" ];
  }).androidsdk"

  log "android: building the SDK via Nix androidenv (platforms: ${levels[*]}; build-tools ${COOEE_ANDROID_BUILD_TOOLS})..."
  export NIXPKGS_ALLOW_UNFREE=1

  # --out-link doubles as a GC root so the SDK survives `nix store gc`; the store
  # path is printed to stdout for us to anchor ANDROID_HOME at.
  local link="$HOME/.cache/coo-ee/android-sdk"
  mkdir -p "$(dirname "$link")"
  local out
  if ! out=$(nix build --impure --print-out-paths --out-link "$link" --expr "$expr"); then
    die "android: SDK build failed. Common causes: dl.google.com unreachable; the requested platform/build-tools versions are absent from nixpkgs (override COOEE_ANDROID_BUILD_TOOLS / COOEE_ANDROID_DEFAULT_PLATFORM); or the build tried to compile 32-bit (i686) ncurses on a kernel without 32-bit x86 support ('Exec format error' — keep the default COOEE_ANDROID_NCURSES5_STUB=1 that stubs it out)."
  fi
  COOEE_ANDROID_SDK_DIR="$out/libexec/android-sdk"
}

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
