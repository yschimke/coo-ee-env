
# ===========================================================================
#  module: ruby
#    software : Ruby (via Nix) + RubyGems
#    params   : ruby[3] picks the major series; ruby[3.4.9] pins major.minor;
#               default Ruby 3
#    hosts    : cache.nixos.org (install)
#             : RubyGems (build, advisory)
#  Prefer the cloud base image when present (Codex: CODEX_ENV_RUBY_VERSION).
# ===========================================================================
register_module ruby
provides_tool ruby ruby CODEX_ENV_RUBY_VERSION
# Pre-approve the Ruby toolchain for Claude Code sessions.
provides_perms ruby "Bash(ruby:*)" "Bash(gem:*)" "Bash(bundle:*)" "Bash(bundler:*)" "Bash(rake:*)" "Bash(rspec:*)"
need_host cache.nixos.org     "prebuilt Ruby from the Nix cache"
want_host rubygems.org        "RubyGems gem downloads"
want_host index.rubygems.org  "RubyGems compact index"

# Map a requested version to a nixpkgs attribute. nixpkgs ships the unversioned
# default plus major.minor attrs (ruby_3_3, ruby_3_4, ...), but no patch-level
# attrs, so a full version like 3.4.9 resolves to its major.minor series and a
# bare major (3) to the default Ruby for that series.
cooee_ruby_attr() {  # cooee_ruby_attr <version> -> nixpkgs attribute name
  local v=$1
  case "$v" in
    "")  printf 'ruby' ;;                  # no param -> default Ruby 3
    *.*) local major=${v%%.*} rest=${v#*.} # major.minor[.patch] -> ruby_<major>_<minor>
         printf 'ruby_%s_%s' "$major" "${rest%%.*}" ;;
    *)   printf 'ruby' ;;                  # bare major (e.g. 3) -> default series
  esac
}

module_ruby() {
  # A single Ruby version may be requested as ruby[3] (major series) or
  # ruby[3.4.9] (full version). Take the first requested param; bare `ruby`
  # installs the nixpkgs default Ruby 3.
  local version="${1:-}"

  # Already provisioned (warm box) or provided by the cloud base image? Adopt
  # the existing Ruby and skip the redundant Nix install.
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v ruby >/dev/null 2>&1; then
    ok "ruby: adopted existing $(ruby --version 2>&1) ($(command -v ruby))."
    return 0
  fi

  local attr; attr=$(cooee_ruby_attr "$version")
  log "Installing Ruby ${version:-3 (default)} via Nix (nixpkgs#${attr})..."
  nix_ensure "$attr" "nixpkgs#${attr}" --accept-flake-config
  command -v ruby >/dev/null 2>&1 || die "ruby not on PATH after install."
  ok "ruby ready: $(ruby --version 2>&1)"
}
