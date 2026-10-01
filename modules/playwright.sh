
# ===========================================================================
#  module: playwright — Playwright agent CLI (@playwright/cli) + browsers
#    software : Playwright CLI (the `playwright-cli` agent CLI) via npm -g, plus
#               the Playwright browsers: the box's own when it has them (e.g.
#               Claude Code's /opt/pw-browsers), else Chromium/Firefox/WebKit
#               from Nix
#    params   : playwright[0.1.13] pins the @playwright/cli version; bare
#               `playwright` installs @latest.
#    hosts    : cache.nixos.org (browsers + their library closure),
#               registry.npmjs.org (the @playwright/cli package)
#  The agent CLI is NOT in nixpkgs, so it comes from npm — which is why this
#  module implies `node`. The browsers DO come from nixpkgs
#  (playwright-driver.browsers): a self-contained closure (Chromium et al. with
#  their shared libraries), so there is nothing to apt-install and nothing to
#  fetch from the Playwright CDN. PLAYWRIGHT_BROWSERS_PATH points at a view over
#  them that also serves the browser revision the project's own Playwright pins
#  (cooee_playwright_align). See README "Playwright".
# ===========================================================================
# coo.ee:implies node
register_module playwright
provides_tool playwright playwright-cli   # adopt an existing CLI if present
# Pre-approve the Playwright CLIs for Claude Code sessions.
provides_perms playwright "Bash(playwright:*)" "Bash(playwright-cli:*)" "Bash(npx playwright:*)"
need_host cache.nixos.org    "Playwright browsers (and their library closure) from the Nix cache"
need_host registry.npmjs.org "the @playwright/cli npm package"
want_host cdn.playwright.dev "the exact browser build a project's pinned Playwright expects (else a nearby build is aliased)"

# Presence for the framework: the CLI lives in our npm prefix, which is only on
# PATH once the persisted env is replayed — after the fast-path check runs — so
# look there too, or every session would miss the fast path.
cooee_present_playwright() {
  command -v playwright-cli >/dev/null 2>&1 \
    || [[ -x "${NPM_CONFIG_PREFIX:-$HOME/.npm-global}/bin/playwright-cli" ]]
}

module_playwright() {
  # The single optional param pins the npm version of @playwright/cli; bare
  # `playwright` tracks @latest.
  local version="${1:-latest}"

  command -v npm >/dev/null 2>&1 || die "playwright: npm is required but not on PATH — the implied 'node' module should have provided it. Re-run with COOEE_FORCE=1."

  # npm's default global prefix is the (read-only) Nix store when node came from
  # Nix, so a plain `npm install -g` would fail with EACCES/EROFS. Point npm at a
  # writable prefix under $HOME and put its bin on PATH — for this run and every
  # later shell (persisted via add_env).
  local prefix="$HOME/.npm-global"
  mkdir -p "$prefix"
  add_env NPM_CONFIG_PREFIX "$prefix"
  case ":$PATH:" in *":$prefix/bin:"*) : ;; *) add_env PATH "$prefix/bin:$PATH" ;; esac

  # --- browsers --------------------------------------------------------------
  # Order of preference:
  #   1. browsers the box already has — a provider image that exports
  #      PLAYWRIGHT_BROWSERS_PATH (Claude Code's ships /opt/pw-browsers): adopt,
  #      no Nix build, no download;
  #   2. the Playwright browsers from nixpkgs. Their runtime libraries are in the
  #      Nix closure, so there's no apt step and no Playwright-CDN download; we
  #      anchor a GC root (so they survive `nix store gc`);
  #   3. COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS=1 (or a failed Nix build): let the CLI
  #      download its own (needs cdn.playwright.dev + OS libraries).
  # Either way Playwright is pointed at a coo.ee *view* of those browsers (see
  # cooee_playwright_align), so a project pinning a different Playwright than
  # the one the browsers were built for still finds a browser.
  local download="${COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS:-0}" src="" from_nix=0
  if [[ "$download" == 1 ]]; then
    warn "playwright: COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS=1 — the CLI will download its own browsers (needs cdn.playwright.dev and OS libraries)."
    src="$HOME/.cache/coo-ee/playwright-browsers"
  elif [[ "${COOEE_FORCE:-0}" != 1 ]] && src=$(cooee_playwright_existing_browsers); then
    ok "playwright: adopted existing browsers at $src ($(cooee_playwright_list "$src"))."
    [[ "$(readlink -f "$src")" == /nix/store/* ]] && from_nix=1   # an earlier run's Nix build
  else
    command -v nix >/dev/null 2>&1 || die "playwright: nix is required to install the browsers but isn't on PATH — re-run with COOEE_FORCE=1 so 'base' installs it first, or set COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS=1."
    log "Installing Playwright browsers via Nix (playwright-driver.browsers)..."
    local link="$HOME/.cache/coo-ee/playwright-browsers"
    mkdir -p "$(dirname "$link")"
    if src=$(nix build --print-out-paths --out-link "$link" nixpkgs#playwright-driver.browsers --accept-flake-config); then
      from_nix=1
      ok "playwright: browsers from Nix at $src."
    else
      warn "playwright: Nix browser build failed; falling back to the CLI's own download (needs cdn.playwright.dev + OS libraries)."
      download=1
      src="$HOME/.cache/coo-ee/playwright-browsers"
    fi
  fi
  mkdir -p "$src" 2>/dev/null || true
  cooee_playwright_view_init "$src"
  add_env PLAYWRIGHT_BROWSERS_PATH "$COOEE_PW_VIEW"
  # Never let an npm install fetch browsers behind our back; the Nix browsers
  # carry their libraries in their closure, not on the host Playwright checks.
  [[ "$download" != 1 ]] && add_env PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD 1
  [[ "$from_nix" == 1 ]] && add_env PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS 1
  # The agent CLI defaults to the branded Google Chrome channel
  # (/opt/google/chrome), which neither the images nor Nix ship; send it to the
  # Playwright Chromium in the view instead.
  if [[ -z "${PLAYWRIGHT_MCP_BROWSER:-}" && ! -x /opt/google/chrome/chrome ]]; then
    add_env PLAYWRIGHT_MCP_BROWSER chromium
  fi
  # Ruby system tests driven by Ferrum/Cuprite find Chrome through BROWSER_PATH;
  # point it at a stable link to the newest Chromium in the view.
  if cooee_module_requested ruby && [[ -z "${BROWSER_PATH:-}" ]]; then
    add_env BROWSER_PATH "$COOEE_PW_VIEW/.cooee-chrome"
  fi

  # --- the CLI ---------------------------------------------------------------
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v playwright-cli >/dev/null 2>&1; then
    ok "playwright: adopted existing $(playwright-cli --version 2>/dev/null || echo playwright-cli) ($(command -v playwright-cli))."
  else
    log "Installing @playwright/cli@${version} via npm (global prefix $prefix)..."
    npm install -g "@playwright/cli@${version}" 1>&2 || die "playwright: 'npm install -g @playwright/cli@${version}' failed."
    command -v playwright-cli >/dev/null 2>&1 || die "playwright: playwright-cli not on PATH after install (expected under $prefix/bin)."
    ok "playwright ready: $(playwright-cli --version 2>/dev/null || echo playwright-cli)"
  fi

  # With the Nix browsers we set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD; otherwise fetch
  # the browsers through the CLI now (into the persistent PLAYWRIGHT_BROWSERS_PATH).
  if [[ "$download" == 1 ]]; then
    log "Downloading Playwright browsers via the CLI (into $src)..."
    PLAYWRIGHT_BROWSERS_PATH="$src" playwright-cli install-browser 1>&2 || warn "playwright: 'playwright-cli install-browser' failed — install the missing OS libraries and re-run."
    cooee_playwright_view_init "$src"
  fi

  # The project's own Playwright (@playwright/test, playwright, or the npm
  # driver playwright-ruby-client shells out to) wants its own browser revision.
  cooee_playwright_align

  log "playwright: agent skills are per-project — run 'playwright-cli install --skills' inside a repo to add them for a coding agent."
}

# ---- browser view + project alignment --------------------------------------
# Every Playwright release expects one exact browser build per browser
# (chromium-1223, chromium_headless_shell-1223, ...) and fails to launch when
# that directory is missing — even though an adjacent Chromium drives fine. On a
# sandbox the browsers come from the image or Nix (one fixed revision each) and
# the Playwright CDN is often not allowlisted, so a project that pins any other
# Playwright version can't run a single browser test.
#
# So PLAYWRIGHT_BROWSERS_PATH points at a coo.ee-owned view: a directory of
# symlinks to every browser in the real source dir, plus — per the project's
# pinned Playwright — the exact revision it wants: downloaded beside the view and
# linked in when the CDN is reachable, otherwise aliased to the nearest Chromium on the box
# (with a warning naming both versions). Opt out of aliasing with
# COOEE_PLAYWRIGHT_ALIAS=0. The source dir itself (an image's /opt/pw-browsers,
# a Nix store path) is never written to.
COOEE_PW_VIEW="${COOEE_PW_VIEW:-$HOME/.cache/coo-ee/playwright-browsers-view}"
# Exact builds downloaded for a pinned Playwright. Kept out of the view because
# `playwright install` garbage-collects every browser dir its registry doesn't
# know — in the view, that would be the links to the source browsers.
COOEE_PW_DOWNLOADS="${COOEE_PW_DOWNLOADS:-$HOME/.cache/coo-ee/playwright-browsers-downloads}"

# A browsers dir the box already has, if PLAYWRIGHT_BROWSERS_PATH names one with
# at least one complete Chromium in it (and it isn't our own view).
cooee_playwright_existing_browsers() {
  local p="${PLAYWRIGHT_BROWSERS_PATH:-}"
  if [[ "$p" == "$COOEE_PW_VIEW" && -f "$COOEE_PW_VIEW/.cooee-source" ]]; then
    p=$(cat "$COOEE_PW_VIEW/.cooee-source")
  fi
  [[ -n "$p" && -d "$p" ]] || return 1
  compgen -G "$p/chromium-*/INSTALLATION_COMPLETE" >/dev/null || return 1
  printf '%s' "$p"
}

cooee_playwright_list() {  # <dir> -> "chromium-1194, ffmpeg-1011"
  local d out=""
  for d in "$1"/*/; do d=${d%/}; out+="${out:+, }${d##*/}"; done
  printf '%s' "${out:-empty}"
}

# (Re)build the view over <source> and the downloads dir: link every browser of
# theirs in (a real download replaces an alias of the same name), drop links to
# entries that are gone, and keep the aliases align added.
cooee_playwright_view_init() {  # cooee_playwright_view_init <source dir>
  local src=$1 e name
  mkdir -p "$COOEE_PW_VIEW"
  printf '%s\n' "$src" > "$COOEE_PW_VIEW/.cooee-source"
  for e in "$COOEE_PW_VIEW"/*; do
    [[ -L "$e" && ! -e "$e" ]] && rm -f "$e"
  done
  for e in "$src"/* "$COOEE_PW_DOWNLOADS"/*; do
    name=${e##*/}
    [[ -d "$e" && "$name" == *-[0-9]* ]] || continue
    [[ -f "$COOEE_PW_VIEW/$name/.cooee-alias-of" && -f "$e/INSTALLATION_COMPLETE" ]] && rm -rf "${COOEE_PW_VIEW:?}/$name"
    [[ -e "$COOEE_PW_VIEW/$name" ]] || ln -s "$e" "$COOEE_PW_VIEW/$name"
  done
  cooee_playwright_link_chrome
}

# The Chromium (full browser, not the headless shell) executable inside a
# browser dir, whichever layout its Playwright version used.
cooee_playwright_exe() {  # cooee_playwright_exe <dir> <kind>
  local n
  case "$2" in
    chromium) for n in chrome-linux64/chrome chrome-linux/chrome; do [[ -x "$1/$n" ]] && { printf '%s' "$1/$n"; return 0; }; done ;;
    chromium_headless_shell) for n in chrome-headless-shell-linux64/chrome-headless-shell chrome-linux/headless_shell; do [[ -x "$1/$n" ]] && { printf '%s' "$1/$n"; return 0; }; done ;;
  esac
  return 1
}

# The newest real (not aliased) complete <kind>-<rev> dir in the view.
cooee_playwright_newest() {  # cooee_playwright_newest <kind>
  local d rev best="" bestrev=-1
  for d in "$COOEE_PW_VIEW/$1"-*; do
    rev=${d##*-}
    [[ "$rev" =~ ^[0-9]+$ && -f "$d/INSTALLATION_COMPLETE" && ! -f "$d/.cooee-alias-of" ]] || continue
    (( rev > bestrev )) && { best=$d; bestrev=$rev; }
  done
  [[ -n "$best" ]] && printf '%s' "$best"
}

# $COOEE_PW_VIEW/.cooee-chrome -> the newest Chromium, for tools that take a
# Chrome binary path (BROWSER_PATH for Ferrum/Cuprite).
cooee_playwright_link_chrome() {
  local d exe
  d=$(cooee_playwright_newest chromium) || return 0
  exe=$(cooee_playwright_exe "$d" chromium) || return 0
  ln -sfn "$(readlink -f "$exe")" "$COOEE_PW_VIEW/.cooee-chrome"
}

# Alias <kind>-<rev> to the newest same-kind build in the view. Playwright
# resolves the executable by a layout that changed across versions, so the alias
# carries both layouts; the link targets the real binary, which finds its
# resources next to itself.
cooee_playwright_alias() {  # cooee_playwright_alias <kind> <rev> -> prints the aliased dir
  local kind=$1 rev=$2 from exe dst="$COOEE_PW_VIEW/$1-$2"
  case "$kind" in
    ffmpeg)
      from=$(cooee_playwright_newest ffmpeg) || return 1
      ln -sfn "$(readlink -f "$from")" "$dst"; printf '%s' "${from##*/}"; return 0 ;;
    chromium|chromium_headless_shell) ;;
    *) return 1 ;;
  esac
  from=$(cooee_playwright_newest "$kind") || return 1
  exe=$(cooee_playwright_exe "$from" "$kind") || return 1
  exe=$(readlink -f "$exe")
  rm -rf "$dst"; mkdir -p "$dst"
  if [[ "$kind" == chromium ]]; then
    mkdir -p "$dst/chrome-linux64" "$dst/chrome-linux"
    ln -s "$exe" "$dst/chrome-linux64/chrome"; ln -s "$exe" "$dst/chrome-linux/chrome"
  else
    mkdir -p "$dst/chrome-headless-shell-linux64" "$dst/chrome-linux"
    ln -s "$exe" "$dst/chrome-headless-shell-linux64/chrome-headless-shell"; ln -s "$exe" "$dst/chrome-linux/headless_shell"
  fi
  : > "$dst/DEPENDENCIES_VALIDATED"; : > "$dst/INSTALLATION_COMPLETE"
  printf '%s\n' "${from##*/}" > "$dst/.cooee-alias-of"
  printf '%s' "${from##*/}"
}

# Make every Playwright on the box — the project's pinned one and the agent
# CLI's bundled one — find its Chromium in the view. Cheap and idempotent (also
# run on the already-provisioned fast path); never fatal.
cooee_playwright_align() {
  [[ -f "$COOEE_PW_VIEW/.cooee-source" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  cooee_playwright_view_init "$(cat "$COOEE_PW_VIEW/.cooee-source")"
  local core seen=""
  for core in "$(cooee_project_dir)/node_modules/playwright-core" \
              "${NPM_CONFIG_PREFIX:-$HOME/.npm-global}"/lib/node_modules/@playwright/cli/node_modules/playwright-core; do
    [[ -f "$core/cli.js" ]] || continue
    core=$(readlink -f "$core")
    [[ " $seen " == *" $core "* ]] && continue
    seen+=" $core"
    cooee_playwright_align_one "$core"
  done
}

cooee_playwright_align_one() {  # cooee_playwright_align_one <playwright-core dir>
  local core=$1 cli="$1/cli.js"
  local ver; ver=$(node -p "require('$core/package.json').version" 2>/dev/null) || return 0

  # The browser dirs this Playwright resolves to, from its own installer.
  local -a need=() missing=()
  local loc
  while IFS= read -r loc; do need+=("${loc##*/}"); done < <(
    PLAYWRIGHT_BROWSERS_PATH="$COOEE_PW_VIEW" node "$cli" install --dry-run chromium 2>/dev/null \
      | sed -n 's/^[[:space:]]*Install location:[[:space:]]*//p' | sort -u)
  ((${#need[@]})) || { warn "playwright: couldn't ask Playwright $ver which browsers it needs; skipping alignment."; return 0; }
  for loc in "${need[@]}"; do
    [[ -f "$COOEE_PW_VIEW/$loc/INSTALLATION_COMPLETE" || ( "$loc" == ffmpeg-* && -e "$COOEE_PW_VIEW/$loc" ) ]] || missing+=("$loc")
  done
  if ((${#missing[@]} == 0)); then
    ok "playwright: Playwright $ver has its browsers (${need[*]})."
    return 0
  fi

  # Exact match first: download the missing revision (beside the view, then
  # linked in).
  log "playwright: Playwright $ver needs ${missing[*]}; trying a download..."
  mkdir -p "$COOEE_PW_DOWNLOADS"
  if PLAYWRIGHT_BROWSERS_PATH="$COOEE_PW_DOWNLOADS" timeout 600 node "$cli" install chromium </dev/null >/dev/null 2>&1; then
    cooee_playwright_view_init "$(cat "$COOEE_PW_VIEW/.cooee-source")"
    ok "playwright: downloaded ${missing[*]} for Playwright $ver."
    return 0
  fi

  if [[ "${COOEE_PLAYWRIGHT_ALIAS:-1}" == 0 ]]; then
    warn "playwright: Playwright $ver needs ${missing[*]}, which isn't on this box and couldn't be downloaded"
    warn "(allowlist cdn.playwright.dev), and COOEE_PLAYWRIGHT_ALIAS=0 forbids aliasing a nearby build. Browser tests will fail to launch."
    return 0
  fi
  local m kind rev from
  for m in "${missing[@]}"; do
    kind=${m%-*}; rev=${m##*-}
    if from=$(cooee_playwright_alias "$kind" "$rev"); then
      warn "playwright: aliased $m -> $from for Playwright $ver (cdn.playwright.dev unreachable)."
    else
      warn "playwright: Playwright $ver needs $m and there's no $kind build on this box to stand in for it."
    fi
  done
  if [[ -z "${_COOEE_PW_ALIAS_NOTED:-}" ]]; then
    _COOEE_PW_ALIAS_NOTED=1
    warn "playwright: an aliased Chromium is a different browser version than the Playwright that asked for it — almost"
    warn "always fine for tests; allowlist cdn.playwright.dev for the exact build, or pin Playwright to the box's version."
  fi
}
