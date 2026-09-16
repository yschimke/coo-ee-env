
# ===========================================================================
#  module: tools — install arbitrary CLI tools from nixpkgs, by name
#    type     : on-demand Nix packages — one module, any number of tools, with
#               no per-tool fragment. The long tail of "I just need rg/jq/gh".
#    params   : tools[ripgrep, jq, gh, ...] or tools[ripgrep@14.1.1]
#               (unversioned entries are nixpkgs attributes, including nested
#               nodePackages.prettier; @version uses Nix Multiverse Fast and
#               therefore requires a top-level attribute on x86_64-linux)
#    software : whatever you ask for, via Nix
#    hosts    : cache.nixos.org (install)
#  Unversioned tools go through nix_ensure; versioned tools use an isolated,
#  idempotent profile managed by the selected backend.
# ===========================================================================
register_module tools
need_host cache.nixos.org "prebuilt CLI tools from the Nix cache"
want_host release-assets.githubusercontent.com "Nix Multiverse Fast index data (only for tools[name@version])"

module_tools() {
  local -a want=("$@")
  if (( ${#want[@]} == 0 )); then
    warn "tools: nothing requested — use tools[name,...], e.g. tools[ripgrep,jq,gh]."
    return 0
  fi

  local installed=0 failed=0 spec tool version match
  for spec in "${want[@]}"; do
    tool=$spec
    version=""
    if [[ "$spec" == *@* ]]; then
      tool=${spec%@*}
      version=${spec##*@}
      if [[ -z "$tool" || -z "$version" || "$tool" == *@* \
            || ! "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ \
            || ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        warn "tools: skipping invalid versioned package '$spec' (use attr@version)."
        failed=$((failed + 1)); continue
      fi
    fi

    # nixpkgs attribute names are letters/digits with . _ - (dots for nested
    # sets like nodePackages.prettier). Reject anything else before it reaches
    # the shell command line rather than feeding Nix a surprise.
    if [[ ! "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      warn "tools: skipping invalid package name '$tool'."; continue
    fi
    match=${tool##*.}   # match the leaf name against `nix profile list`

    if [[ -n "$version" ]]; then
      # The Multiverse index is keyed by top-level nixpkgs attributes. Dotted
      # package sets remain supported on the ordinary, unversioned path above.
      if [[ "$tool" == *.* ]]; then
        warn "tools: ${tool}@${version} is nested, but Multiverse versions only top-level nixpkgs attributes; omit @version."
        failed=$((failed + 1)); continue
      fi
      if cooee_backend_versioned_tool "$tool" "$version" "${match}-${version}"; then
        installed=$((installed + 1))
      else
        failed=$((failed + 1))
      fi
      continue
    fi

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
