
# ===========================================================================
#  module: tools — install arbitrary CLI tools from nixpkgs, by name
#    type     : on-demand Nix packages — one module, any number of tools, with
#               no per-tool fragment. The long tail of "I just need rg/jq/gh".
#    params   : tools[ripgrep, jq, gh, ...]   (each a nixpkgs attribute name,
#               e.g. ripgrep, jq, gh, nodePackages.prettier)
#    software : whatever you ask for, via Nix
#    hosts    : cache.nixos.org (install)
#  Each tool goes through nix_ensure, so a re-run only installs what's missing.
# ===========================================================================
register_module tools
need_host cache.nixos.org "prebuilt CLI tools from the Nix cache"

module_tools() {
  local -a want=("$@")
  if (( ${#want[@]} == 0 )); then
    warn "tools: nothing requested — use tools[name,...], e.g. tools[ripgrep,jq,gh]."
    return 0
  fi

  local installed=0 failed=0 tool match
  for tool in "${want[@]}"; do
    # nixpkgs attribute names are letters/digits with . _ - (dots for nested
    # sets like nodePackages.prettier). Reject anything else before it reaches
    # the shell command line rather than feeding Nix a surprise.
    if [[ ! "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      warn "tools: skipping invalid package name '$tool'."; continue
    fi
    match=${tool##*.}   # match the leaf name against `nix profile list`
    log "Installing $tool via Nix..."
    if nix_ensure "$match" "nixpkgs#$tool" --accept-flake-config; then
      installed=$((installed + 1))
    else
      warn "tools: could not install '$tool' (is it a valid nixpkgs attribute?)."
      failed=$((failed + 1))
    fi
  done

  ok "tools: ${installed} installed/present, ${failed} failed (requested ${#want[@]})."
  (( failed == 0 )) || warn "tools: some packages failed; see the messages above."
}
