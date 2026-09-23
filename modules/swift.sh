
# ===========================================================================
#  module: swift
#    software : Swift toolchain (swift.org build via swiftly) — swiftc, SwiftPM, swift-format, sourcekit-lsp
#    params   : swift[6.3] picks the release (default: .swift-version, else latest); swift[nix] uses nixpkgs' older 5.10 instead
#    hosts    : www.swift.org + download.swift.org (install, official toolchain)
#             : cache.nixos.org (install, swift[nix] only)
#             : github.com (build, advisory — SwiftPM resolves packages by git)
#  Prefer the cloud base image when present (Codex: CODEX_ENV_SWIFT_VERSION).
#
#  Two sources, because neither is enough on its own:
#   - swiftly (the default) is swift.org's own toolchain manager and the
#     documented Linux install path. It tracks current releases (Swift 6.x,
#     Swift Testing, the 6 language mode) and honours .swift-version. But the
#     toolchain is a prebuilt tarball linked against the *system* libraries
#     (libcurl, libxml2, libz3, ...), so the box needs those from its own
#     package manager, and download.swift.org must be allowlisted — it is not
#     in the default allowlists of the cloud sandboxes.
#   - nixpkgs (swift[nix]) needs nothing beyond cache.nixos.org and no system
#     packages, but nixpkgs' Swift lags far behind: 5.10.1 while swift.org
#     ships 6.x. Right for a Swift 5 package on a locked-down network, wrong for
#     anything that uses Swift 6 features.
# ===========================================================================
register_module swift
provides_tool swift swift CODEX_ENV_SWIFT_VERSION
# Pre-approve the Swift toolchain for Claude Code sessions.
provides_perms swift "Bash(swift:*)" "Bash(swiftc:*)" "Bash(swiftly:*)" "Bash(swift-format:*)"

# The source is known at source time (params are injected before fragments), so
# only the hosts the chosen source will actually touch are probed. The renderer
# still lists all of them for the picker.
if [[ ",${_MODULE_PARAMS[swift]:-}," == *,nix,* ]]; then
  need_host cache.nixos.org      "prebuilt Swift toolchain from the Nix cache (swift[nix])"
else
  need_host www.swift.org        "swiftly release list and the toolchain signing keys"
  need_host download.swift.org   "the swiftly binary and the official Swift toolchain"
fi
want_host github.com             "Swift Package Manager dependencies (resolved by git clone)"
want_host swiftpackageindex.com  "Swift Package Index (package search / docs, optional)"

# Where swiftly lives. These are swiftly's own defaults, pinned so the env
# profile can export them and a later shell finds the same install.
COOEE_SWIFTLY_HOME="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"
COOEE_SWIFTLY_BIN="${SWIFTLY_BIN_DIR:-$COOEE_SWIFTLY_HOME/bin}"

# The toolchain the project asks for, when the request doesn't: .swift-version
# at the project root (the file swiftly itself reads to select a toolchain).
cooee_swift_marker_version() {
  local f; f="$(cooee_project_dir)/.swift-version"
  [[ -f "$f" ]] || return 0
  local v; v="$(tr -d '[:space:]' < "$f")"
  [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]] && printf '%s' "$v"
}

# Requested toolchain: the first non-`nix` param, else the marker, else empty
# (= swiftly's latest release).
cooee_swift_requested_version() {
  local p
  for p in "$@"; do [[ "$p" != nix ]] && { printf '%s' "$p"; return 0; }; done
  cooee_swift_marker_version
}

# `swift --version` -> the bare version (6.4.0, 5.10.1, ...).
cooee_swift_version_of() {  # cooee_swift_version_of <swift binary>
  "$1" --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+)*).*/\1/p' | head -1
}

# A requested version is satisfied by an installed one when every component it
# names matches: 6 by anything 6.x, 6.4 by 6.4.x. `swift --version` drops a zero
# patch ("Swift version 6.4" for 6.4.0), so a component the installed version
# leaves out counts as 0 — 6.4.0 is satisfied by 6.4, 6.0 is not by 6.4.
cooee_swift_version_matches() {  # <requested> <installed>
  [[ -z "$1" ]] && return 0
  local -a want have
  IFS=. read -r -a want <<< "$1"
  IFS=. read -r -a have <<< "$2"
  local i
  for i in "${!want[@]}"; do
    [[ "${want[$i]}" == "${have[$i]:-0}" ]] || return 1
  done
}

# Present = a swift on PATH that satisfies the request (so a Swift 5 image does
# not short-circuit a swift[6.4] request past the host preflight).
cooee_present_swift() {
  command -v swift >/dev/null 2>&1 || return 1
  local -a params=()
  [[ -n "${_MODULE_PARAMS[swift]:-}" ]] && IFS=',' read -r -a params <<< "${_MODULE_PARAMS[swift]}"
  local want; want="$(cooee_swift_requested_version "${params[@]}")"
  cooee_swift_version_matches "$want" "$(cooee_swift_version_of "$(command -v swift)")"
}

# swift[nix]. nixpkgs' Swift is built to be used *inside a Nix build*: its
# compiler wrapper takes the include/link flags for Foundation, Dispatch and
# XCTest from the NIX_* variables that stdenv setup hooks export, and SwiftPM's
# compiled manifest finds libdispatch.so only through them. Installed plainly
# into a profile, `swift build` dies at the manifest ("libdispatch.so: cannot
# open shared object file"), then at `import Foundation`.
#
# So: build the toolchain as one buildEnv behind a GC root, capture the flags a
# swift-stdenv mkShell would export (nix print-dev-env) once, and put shims in
# front of every toolchain binary that load them and exec the real one. The
# flags (and LD_LIBRARY_PATH, which carries store libraries) stay inside Swift's
# own processes and never reach the session environment, where a store library
# would break any system binary that loads it (see the compose module).
COOEE_SWIFT_NIX_DIR="${COOEE_SWIFT_NIX_DIR:-$HOME/.local/share/coo-ee/swift-nix}"

cooee_swift_via_nix() {
  local dir="$COOEE_SWIFT_NIX_DIR" ref
  ref="$(cooee_nixpkgs_ref)"
  mkdir -p "$dir"
  local pkgs="import (builtins.getFlake \"${ref}\").outPath { }"
  local list="swift swiftpm swift-format sourcekit-lsp swiftPackages.Foundation swiftPackages.Dispatch swiftPackages.XCTest"

  log "Installing Swift via Nix (nixpkgs' toolchain trails swift.org's)..."
  nix build --impure --accept-flake-config --out-link "$dir/toolchain" --expr \
      "let pkgs = ${pkgs}; in pkgs.buildEnv { name = \"cooee-swift\"; paths = with pkgs; [ ${list} ]; }" >&2 \
    || die "swift: nix build of the Swift toolchain failed. $(cooee_nixpkgs_hint)"

  local devenv; devenv="$(mktemp)"
  nix print-dev-env --impure --accept-flake-config --expr \
      "let pkgs = ${pkgs}; in pkgs.mkShell.override { stdenv = pkgs.swift.stdenv; } { packages = with pkgs; [ ${list} ]; }" \
      > "$devenv" || die "swift: couldn't compute the Swift compiler flags (nix print-dev-env)."

  # Keep only the wrapper inputs: NIX_* minus the per-build and per-user ones.
  # The rpath mkShell adds for its own (unbuilt) $out is dropped: it points into
  # whatever directory this ran from.
  local tmp; tmp="$(mktemp -d)"
  ( export TMPDIR="$tmp"
    # shellcheck disable=SC1090
    . "$devenv" >/dev/null 2>&1
    NIX_LDFLAGS="$(sed -E 's#-rpath [^ ]*/outputs/out/lib##' <<<"${NIX_LDFLAGS:-}")"
    local v
    for v in $(compgen -e | grep '^NIX_' | grep -vE '^NIX_(BUILD_TOP|BUILD_CORES|STORE|PROFILES|PATH|SSL_CERT_FILE|REMOTE|CONF_DIR|USER_CONF_FILES|CONFIG)$'); do
      printf 'export %s=%q\n' "$v" "${!v}"
    done
  ) > "$dir/env.sh"
  rm -rf "$tmp" "$devenv"
  grep -q '^export NIX_SWIFTFLAGS_COMPILE=' "$dir/env.sh" \
    || die "swift: the Nix Swift shell exported no NIX_SWIFTFLAGS_COMPILE; can't wrap the toolchain."
  # The manifest (and test runner) link libdispatch/Foundation/XCTest by soname.
  printf 'export LD_LIBRARY_PATH=%q"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' \
    "$dir/toolchain/lib:$dir/toolchain/lib/swift/linux" >> "$dir/env.sh"

  rm -rf "${dir:?}/bin"; mkdir -p "$dir/bin"
  local b
  for b in "$dir"/toolchain/bin/*; do
    [[ -x "$b" ]] || continue
    printf '#!/usr/bin/env bash\n. %q\nexec %q "$@"\n' "$dir/env.sh" "$b" > "$dir/bin/${b##*/}"
    chmod +x "$dir/bin/${b##*/}"
  done

  add_env PATH "$dir/bin:$PATH"
  export PATH="$dir/bin:$PATH"
  hash -r
  command -v swift >/dev/null 2>&1 || die "swift not on PATH after install."
  ok "swift ready (nixpkgs): Swift $(cooee_swift_version_of "$(command -v swift)") ($(command -v swift))"
  warn "swift: nixpkgs' toolchain has no libIndexStore, so 'swift test' can't discover tests;"
  warn "'swift build' / 'swift run' work. Allow download.swift.org and drop [nix] for the full toolchain."
}

# Install the packages the official toolchain links against. swiftly writes the
# exact apt/dnf/yum command for this distro into the post-install file; we run
# it as root when we can, and otherwise say what is missing rather than fail —
# the compiler may still work for a subset of packages.
cooee_swift_system_deps() {  # cooee_swift_system_deps <post-install file>
  local f=$1
  [[ -s "$f" ]] || { ok "swift: system libraries already present."; return 0; }
  if [[ "${COOEE_SWIFT_SYSTEM_DEPS:-1}" == 0 ]]; then
    warn "swift: COOEE_SWIFT_SYSTEM_DEPS=0 — not installing the toolchain's system libraries:"
    sed 's/^/    /' "$f" >&2
    return 0
  fi
  log "swift: installing the toolchain's system libraries (distro package manager)..."
  if cooee_sudo bash "$f" >&2; then
    ok "swift: system libraries installed."
  else
    warn "swift: couldn't install the toolchain's system libraries (no root/sudo, or the"
    warn "distro mirror is blocked). Run this as root, or builds may fail to link:"
    sed 's/^/    /' "$f" >&2
  fi
}

module_swift() {
  local want; want="$(cooee_swift_requested_version "$@")"
  local p src=swiftly
  for p in "$@"; do [[ "$p" == nix ]] && src=nix; done

  # Adopt a swift the box already has (warm box, or the provider's base image)
  # when it satisfies the request.
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && cooee_present_swift; then
    ok "swift: adopted existing Swift $(cooee_swift_version_of "$(command -v swift)") ($(command -v swift))."
    return 0
  fi

  if [[ "$src" == nix ]]; then
    [[ -n "$want" ]] && warn "swift: swift[nix] installs the nixpkgs toolchain; ignoring requested version '$want'."
    cooee_swift_via_nix
    return 0
  fi

  case "$(uname -s)" in
    Linux) ;;
    Darwin) die "swift: on macOS, install Xcode or the swift.org package; this module provisions Linux sandboxes." ;;
    *) die "swift: no official Swift toolchain for $(uname -s)." ;;
  esac

  local swiftly="$COOEE_SWIFTLY_BIN/swiftly"
  if [[ ! -x "$swiftly" ]]; then
    local arch tmp
    arch="$(uname -m)"
    case "$arch" in x86_64|aarch64) ;; *) die "swift: no swiftly build for $arch (x86_64 and aarch64 only)." ;; esac
    tmp="$(mktemp -d)"
    log "Downloading swiftly ($arch) from download.swift.org..."
    cooee_fetch "https://download.swift.org/swiftly/linux/swiftly-${arch}.tar.gz" "$tmp/swiftly.tar.gz" \
      || die "swift: swiftly download failed (is download.swift.org reachable?). swift[nix] installs an older toolchain from the Nix cache instead."
    tar -xzf "$tmp/swiftly.tar.gz" -C "$tmp" || die "swift: couldn't unpack swiftly."
    # init: lay down SWIFTLY_HOME_DIR and link swiftly into its bin dir, but
    # neither install a toolchain (we pick the version below) nor edit shell rc
    # files (the env profile carries PATH instead).
    SWIFTLY_HOME_DIR="$COOEE_SWIFTLY_HOME" SWIFTLY_BIN_DIR="$COOEE_SWIFTLY_BIN" \
      "$tmp/swiftly" init --assume-yes --skip-install --no-modify-profile --quiet-shell-followup </dev/null >&2 \
      || die "swift: 'swiftly init' failed."
    rm -rf "$tmp"
  fi

  add_env SWIFTLY_HOME_DIR "$COOEE_SWIFTLY_HOME"
  add_env SWIFTLY_BIN_DIR "$COOEE_SWIFTLY_BIN"
  add_env PATH "$COOEE_SWIFTLY_BIN:$PATH"
  export PATH="$COOEE_SWIFTLY_BIN:$PATH"
  [[ -x "$swiftly" ]] || die "swift: swiftly not found at $swiftly after init."

  # Signature verification needs gpg; without it swiftly refuses to install.
  local -a verify=()
  if ! command -v gpg >/dev/null 2>&1; then
    warn "swift: gpg not found — installing the toolchain without signature verification."
    verify=(--no-verify)
  fi

  local post; post="$(mktemp)"
  log "swift: installing Swift ${want:-(latest release)} with swiftly..."
  # Not `install --use`: inside a git checkout that writes a .swift-version at
  # the repo root, i.e. into the user's project. Select it as the global default
  # instead; a project's own .swift-version still wins per directory.
  "$swiftly" install "${want:-latest}" --assume-yes "${verify[@]}" \
      --post-install-file "$post" </dev/null >&2 \
    || die "swift: 'swiftly install ${want:-latest}' failed."
  "$swiftly" use --global-default --assume-yes "${want:-latest}" </dev/null >&2 \
    || die "swift: 'swiftly use --global-default ${want:-latest}' failed."
  cooee_swift_system_deps "$post"
  rm -f "$post"

  hash -r
  command -v swift >/dev/null 2>&1 || die "swift not on PATH after install."
  ok "swift ready: Swift $(cooee_swift_version_of "$(command -v swift)") ($(command -v swift))"
}
