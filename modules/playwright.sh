
# ===========================================================================
#  module: playwright — Playwright agent CLI (@playwright/cli) + browsers
#    software : Playwright CLI (the `playwright-cli` agent CLI) via npm -g, plus
#               the Playwright browsers (Chromium/Firefox/WebKit) from Nix
#    params   : playwright[0.1.13] pins the @playwright/cli version; bare
#               `playwright` installs @latest.
#    hosts    : cache.nixos.org (browsers + their library closure),
#               registry.npmjs.org (the @playwright/cli package)
#  The agent CLI is NOT in nixpkgs, so it comes from npm — which is why this
#  module implies `node`. The browsers DO come from nixpkgs
#  (playwright-driver.browsers): a self-contained closure (Chromium et al. with
#  their shared libraries), so there is nothing to apt-install and nothing to
#  fetch from the Playwright CDN. We point PLAYWRIGHT_BROWSERS_PATH at it.
#  See README "Playwright".
# ===========================================================================
# coo.ee:implies node
register_module playwright
provides_tool playwright playwright-cli   # adopt an existing CLI if present
need_host cache.nixos.org    "Playwright browsers (and their library closure) from the Nix cache"
need_host registry.npmjs.org "the @playwright/cli npm package"
want_host cdn.playwright.dev "Playwright-managed browser downloads (only with COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS=1)"

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
  # Default: the Playwright browsers from nixpkgs. Their runtime libraries are in
  # the Nix closure, so there's no apt step and no Playwright-CDN download; we
  # anchor a GC root (so they survive `nix store gc`) and point Playwright at the
  # resulting store path. Opt out with COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS=1 to let
  # the CLI download its own (needs cdn.playwright.dev + OS libraries) — useful if
  # the nixpkgs browser revision ever drifts from the CLI's bundled Playwright.
  local download="${COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS:-0}"
  if [[ "$download" == 1 ]]; then
    warn "playwright: COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS=1 — the CLI will download its own browsers (needs cdn.playwright.dev and OS libraries)."
    add_env PLAYWRIGHT_BROWSERS_PATH "$HOME/.cache/coo-ee/playwright-browsers"
  else
    command -v nix >/dev/null 2>&1 || die "playwright: nix is required to install the browsers but isn't on PATH — re-run with COOEE_FORCE=1 so 'base' installs it first, or set COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS=1."
    log "Installing Playwright browsers via Nix (playwright-driver.browsers)..."
    local link="$HOME/.cache/coo-ee/playwright-browsers"
    mkdir -p "$(dirname "$link")"
    local out
    if out=$(nix build --print-out-paths --out-link "$link" nixpkgs#playwright-driver.browsers --accept-flake-config); then
      add_env PLAYWRIGHT_BROWSERS_PATH "$out"
      add_env PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD 1
      add_env PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS 1
      ok "playwright: browsers from Nix at $out (PLAYWRIGHT_BROWSERS_PATH set)."
    else
      warn "playwright: Nix browser build failed; falling back to the CLI's own download (needs cdn.playwright.dev + OS libraries)."
      download=1
      add_env PLAYWRIGHT_BROWSERS_PATH "$HOME/.cache/coo-ee/playwright-browsers"
    fi
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
    log "Downloading Playwright browsers via the CLI (PLAYWRIGHT_BROWSERS_PATH=$PLAYWRIGHT_BROWSERS_PATH)..."
    playwright-cli install-browser 1>&2 || warn "playwright: 'playwright-cli install-browser' failed — install the missing OS libraries and re-run."
  fi

  log "playwright: agent skills are per-project — run 'playwright-cli install --skills' inside a repo to add them for a coding agent."
}
