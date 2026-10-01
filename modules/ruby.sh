# ===========================================================================
#  module: ruby
#    software : Ruby + RubyGems + Bundler; the project's gems (bundle install)
#    params   : ruby[3] picks the major series; ruby[3.4.9] pins major.minor;
#               default: the project's .ruby-version, else its Gemfile's
#               `ruby "x.y.z"`, else Ruby 3
#    hosts    : cache.nixos.org (install, only when no suitable Ruby is present)
#             : RubyGems (build; the best-effort bundle install, advisory —
#               opt out COOEE_NO_DEPS=1)
#             : the distro mirror (headers for native gems like pg, advisory)
#  Order of preference for the Ruby itself: one already on PATH that matches the
#  wanted major.minor (cloud base image, warm box); one of the image's rbenv
#  versions that matches (Claude Code's image ships several under /opt/rbenv,
#  but ruby-build can't download more behind its proxy); else Nix.
#  Prefer the cloud base image when present (Codex: CODEX_ENV_RUBY_VERSION).
#  See README "Ruby".
# ===========================================================================
register_module ruby
provides_tool ruby ruby CODEX_ENV_RUBY_VERSION
# Pre-approve the Ruby toolchain for Claude Code sessions.
provides_perms ruby "Bash(ruby:*)" "Bash(gem:*)" "Bash(bundle:*)" "Bash(bundler:*)" "Bash(rake:*)" "Bash(rspec:*)" "Bash(bin/rails:*)" "Bash(bin/rake:*)" "Bash(bin/rspec:*)" "Bash(bundle exec:*)" "Bash(rails:*)"
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

# The Ruby version the project asks for, or nothing: .ruby-version (as rbenv,
# asdf and chruby read it — a "ruby-" prefix is dropped), else the Gemfile's
# `ruby "x.y.z"` directive. A .tool-versions `ruby` line counts too.
cooee_ruby_project_version() {
  local dir; dir=$(cooee_project_dir)
  local v=""
  if [[ -f "$dir/.ruby-version" ]]; then
    v=$(head -1 "$dir/.ruby-version" | tr -d '[:space:]')
  elif [[ -f "$dir/.tool-versions" ]]; then
    v=$(awk '$1 == "ruby" { print $2; exit }' "$dir/.tool-versions")
  elif [[ -f "$dir/Gemfile" ]]; then
    v=$(sed -n "s/^[[:space:]]*ruby[[:space:]]*(\{0,1\}[[:space:]]*[\"']\([0-9][0-9.]*\)[\"'].*/\1/p" "$dir/Gemfile" | head -1)
  fi
  v=${v#ruby-}
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] && printf '%s' "$v"
  return 0
}

# The wanted version: the explicit param, else the project's pin, else nothing.
cooee_ruby_wanted() {  # cooee_ruby_wanted [param]
  local p="${1:-${_MODULE_PARAMS[ruby]:-}}"
  p=${p%%,*}
  if [[ -n "$p" ]]; then printf '%s' "$p"; else cooee_ruby_project_version; fi
}

# True when Ruby <have> satisfies <want>: same major (want "3"), same
# major.minor (want "3.4" or "3.4.9" — a patch difference doesn't change the
# ABI or the gems, and Nix can't pin patch levels anyway), or anything when no
# version is wanted.
cooee_ruby_satisfies() {  # cooee_ruby_satisfies <have> <want>
  local have=$1 want=$2
  [[ -z "$want" ]] && return 0
  case "$want" in
    *.*) local wmm; wmm=$(printf '%s' "$want" | cut -d. -f1-2)
         [[ "$(printf '%s' "$have" | cut -d. -f1-2)" == "$wmm" ]] ;;
    *)   [[ "${have%%.*}" == "$want" ]] ;;
  esac
}

cooee_ruby_version_of() {  # <ruby binary>
  "$1" -e 'print RUBY_VERSION' 2>/dev/null
}

# An rbenv-managed Ruby matching <want>: the exact version when installed, else
# the newest of the same series. Prints its bin dir.
cooee_ruby_rbenv_match() {  # cooee_ruby_rbenv_match <want>
  local want=$1 root="${RBENV_ROOT:-/opt/rbenv}" d v best="" bestv=""
  [[ -d "$root/versions" ]] || return 1
  if [[ -x "$root/versions/$want/bin/ruby" ]]; then printf '%s' "$root/versions/$want/bin"; return 0; fi
  for d in "$root"/versions/*/bin; do
    [[ -x "$d/ruby" ]] || continue
    v=$(basename "$(dirname "$d")")
    cooee_ruby_satisfies "$v" "$want" || continue
    if [[ -z "$bestv" ]] || [[ "$(printf '%s\n%s\n' "$bestv" "$v" | sort -V | tail -1)" == "$v" ]]; then
      best=$d; bestv=$v
    fi
  done
  [[ -n "$best" ]] && printf '%s' "$best"
}

# Presence for the framework (fast path / adopt pass): a Ruby on PATH that
# satisfies the wanted version, or an rbenv one we can select without a download.
cooee_present_ruby() {
  local want; want=$(cooee_ruby_wanted)
  if command -v ruby >/dev/null 2>&1 && cooee_ruby_satisfies "$(cooee_ruby_version_of ruby)" "$want"; then
    return 0
  fi
  [[ -n "$want" ]] && [[ -n "$(cooee_ruby_rbenv_match "$want")" ]]
}

# A Ruby whose default gem dir we can't write — the Nix store, or a distro Ruby's
# /var/lib/gems for a non-root user — makes `gem install` / `bundle install`
# fail with EACCES (or reach for sudo). Give it a writable GEM_HOME under $HOME
# and put its bin dir on PATH. A no-op for the usual root sandbox.
cooee_ruby_writable_gem_home() {
  local dir
  dir=$(ruby -e 'print Gem.dir' 2>/dev/null) || return 0
  [[ -w "$dir" ]] && return 0
  local abi; abi=$(ruby -e 'print RbConfig::CONFIG["ruby_version"]' 2>/dev/null)
  local home="$HOME/.local/share/gem/ruby/${abi:-default}"
  mkdir -p "$home/bin"
  add_env GEM_HOME "$home"
  add_env PATH "$home/bin:$PATH"
  log "ruby: $dir is read-only; gems install to GEM_HOME=$home."
}

# Distro packages the common native-extension gems compile against, keyed by the
# gem name as it appears in Gemfile.lock, with the header that proves the
# package is already there. Gems that ship precompiled platform builds
# (nokogiri, sqlite3, ffi on x86_64/aarch64 Linux) aren't listed, and a listed
# gem the lockfile resolves to a precompiled build (pg 1.6+) is skipped.
COOEE_RUBY_NATIVE_DEPS=(
  "pg:libpq-dev:postgresql/libpq-fe.h libpq-fe.h"
  "mysql2:default-libmysqlclient-dev:mysql/mysql.h mariadb/mysql.h"
  "psych:libyaml-dev:yaml.h"
)

# True when the project's bundle includes <gem> as a source build: from the
# lockfile when there is one (a gem resolved to a precompiled build for this
# platform doesn't count), else from a direct `gem "<name>"` in the Gemfile.
cooee_ruby_bundle_has() {  # cooee_ruby_bundle_has <project dir> <gem>
  local dir=$1 gem=$2
  if [[ -f "$dir/Gemfile.lock" ]]; then
    grep -qE "^    ${gem} \(" "$dir/Gemfile.lock" || return 1
    ! grep -qE "^    ${gem} \([^)]*-$(uname -m)-linux" "$dir/Gemfile.lock"
  else
    grep -qE "^[[:space:]]*gem[[:space:](]+[\"']${gem}[\"']" "$dir/Gemfile" 2>/dev/null
  fi
}

# Install the headers the project's native gems need before `bundle install`
# tries to compile them. apt-based images only (that's what the cloud images
# are); elsewhere, say what's missing.
cooee_ruby_native_deps() {
  local dir=$1 entry gem pkg hdrs h found
  local -a missing=()
  for entry in "${COOEE_RUBY_NATIVE_DEPS[@]}"; do
    IFS=: read -r gem pkg hdrs <<< "$entry"
    cooee_ruby_bundle_has "$dir" "$gem" || continue
    found=0
    for h in $hdrs; do [[ -f "${COOEE_INCLUDE_DIR:-/usr/include}/$h" ]] && { found=1; break; }; done
    [[ $found == 1 ]] || missing+=("$pkg")
  done
  ((${#missing[@]})) || return 0
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "ruby: native gems need system headers this box lacks: ${missing[*]} (Debian names). Install them, or 'bundle install' will fail to compile."
    return 0
  fi
  log "ruby: installing headers for native gems (${missing[*]})..."
  if cooee_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >&2 \
     || { cooee_sudo apt-get update -qq >&2 && cooee_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >&2; }; then
    ok "ruby: native-gem headers installed (${missing[*]})."
  else
    warn "ruby: couldn't install ${missing[*]} (no root/sudo, or the distro mirror is blocked); native gems may fail to compile."
  fi
}

# Warm the gem cache: with Ruby ready and RubyGems reachable, `bundle install`
# the project now so a later test run — possibly under tighter egress — has its
# gems. Best-effort and never fatal, like the npm prefetch. Never writes into the
# checkout: options go through BUNDLE_* env vars, not `bundle config --local`.
cooee_prefetch_bundle() {
  cooee_deps_enabled || { log "ruby: skipping bundle install (COOEE_NO_DEPS=1)."; return 0; }
  local dir; dir=$(cooee_project_dir)
  [[ -f "$dir/Gemfile" || -f "$dir/gems.rb" ]] || { log "ruby: no Gemfile in $dir; skipping bundle install."; return 0; }

  cooee_ruby_native_deps "$dir"

  command -v bundle >/dev/null 2>&1 || gem install --no-document bundler >&2 || true
  command -v bundle >/dev/null 2>&1 || { warn "ruby: bundler not available; skipping bundle install."; return 0; }

  log "ruby: installing gems (bundle install)..."
  local out
  if out=$( cd "$dir" && BUNDLE_JOBS="${BUNDLE_JOBS:-$(nproc 2>/dev/null || echo 4)}" BUNDLE_RETRY=3 \
              bundle install </dev/null 2>&1 ); then
    ok "ruby: gems installed (bundle install)."
    return 0
  fi
  printf '%s\n' "$out" | tail -n 25 >&2
  warn "ruby: bundle install failed (continuing). Allowlist rubygems.org, or set COOEE_NO_DEPS=1 to skip."
}

module_ruby() {
  local want; want=$(cooee_ruby_wanted "${1:-}")
  local src="ruby[${1:-}]"; [[ -z "${1:-}" ]] && src="the project"

  # Already provisioned (warm box) or provided by the cloud base image, and the
  # right series? Adopt it and skip the redundant Nix install.
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v ruby >/dev/null 2>&1 \
     && cooee_ruby_satisfies "$(cooee_ruby_version_of ruby)" "$want"; then
    ok "ruby: adopted existing $(ruby --version 2>&1) ($(command -v ruby))."
    cooee_ruby_patch_note "$want"
    cooee_ruby_writable_gem_home
    cooee_prefetch_bundle
    return 0
  fi
  if command -v ruby >/dev/null 2>&1; then
    log "ruby: $(command -v ruby) is Ruby $(cooee_ruby_version_of ruby); ${src} wants ${want}."
  fi

  # The image's rbenv may already have the right series — selecting it is free
  # and offline, where a Nix Ruby is a download (and ruby-build is a compile).
  local rb
  if [[ "${COOEE_FORCE:-0}" != 1 && -n "$want" ]] && rb=$(cooee_ruby_rbenv_match "$want"); then
    add_env PATH "$rb:$PATH"
    hash -r
    ok "ruby: selected rbenv's Ruby $(cooee_ruby_version_of "$rb/ruby") ($rb)."
    cooee_ruby_patch_note "$want"
    cooee_ruby_writable_gem_home
    cooee_prefetch_bundle
    return 0
  fi

  local attr; attr=$(cooee_ruby_attr "$want")
  log "Installing Ruby ${want:-3 (default)} via Nix (nixpkgs#${attr})..."
  nix_ensure "$attr" "nixpkgs#${attr}" --accept-flake-config
  hash -r
  command -v ruby >/dev/null 2>&1 || die "ruby not on PATH after install."
  ok "ruby ready: $(ruby --version 2>&1)"
  cooee_ruby_patch_note "$want"
  cooee_ruby_writable_gem_home
  cooee_prefetch_bundle
}

# A Gemfile `ruby "3.4.1"` is enforced exactly by Bundler, so a patch-level
# difference (allowed by cooee_ruby_satisfies) would still fail `bundle exec`.
cooee_ruby_patch_note() {  # <want>
  local want=$1 have; have=$(cooee_ruby_version_of ruby)
  [[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$have" != "$want" ]] || return 0
  warn "ruby: the project pins Ruby $want but this box has $have (same series). If the Gemfile's"
  warn "'ruby' line pins the patch level, Bundler will refuse to run — relax it to '~> ${want%.*}.0'."
}
