
# ===========================================================================
#  module: dotfiles — clone a config repo and apply it to $HOME
#    type     : git-coordinate dependency (NOT a Nix package) — the same shape
#               as `skills`: clone owner/repo[@ref] into the coo.ee cache, then
#               apply it to the home directory.
#    params   : dotfiles[owner/repo, owner/repo@ref, ...]
#               required — there is no sensible default repo; bare `dotfiles`
#               warns with usage and installs nothing
#    software : git (pulled from Nix only if the box doesn't already have it);
#               GNU Stow is used when already present, never installed
#    hosts    : github.com (clone), cache.nixos.org (git, if absent)
# ===========================================================================
# Applying dotfiles has no single standard, so the module tries three strategies
# in order of specificity — see cooee_dotfiles_apply. The one deliberate
# restriction: a repo-provided install script is NOT run by default. Cloning a
# coordinate someone typed into a URL and executing its `install.sh` is arbitrary
# code execution triggered by a request parameter; symlinking is not. Opt in with
# COOEE_DOTFILES_RUN_INSTALL=1 when the repo is yours.
register_module dotfiles
need_host github.com      "git clone of the requested dotfiles repo(s)"
want_host cache.nixos.org "git from the Nix cache, only if git is not already present"

# Top-level entries never linked into $HOME: repo metadata and documentation,
# which are about the repo rather than part of the configuration it carries.
COOEE_DOTFILES_SKIP="${COOEE_DOTFILES_SKIP:-.git .github .gitignore .gitmodules .gitattributes}"

# Names accepted as a repo-provided installer, in the order they're tried.
COOEE_DOTFILES_INSTALLERS="${COOEE_DOTFILES_INSTALLERS:-install.sh bootstrap setup}"

# True when <name> is in COOEE_DOTFILES_SKIP.
cooee_dotfiles_skipped() {  # <name>
  local n
  for n in $COOEE_DOTFILES_SKIP; do [[ "$1" == "$n" ]] && return 0; done
  return 1
}

# Back up $HOME/<name> before something else takes its place, and echo what
# happened. A symlink we already own is refreshed silently (a re-run must not
# accumulate .cooee.bak copies of our own links); anything else is moved aside
# once — an existing backup is never overwritten, so the ORIGINAL file always
# survives no matter how many times this runs.
cooee_dotfiles_backup() {  # <target> <expected_link_dest>
  local target="$1" want="$2"
  [[ -e "$target" || -L "$target" ]] || return 0
  if [[ -L "$target" && "$(readlink -f "$target" 2>/dev/null)" == "$(readlink -f "$want" 2>/dev/null)" ]]; then
    return 0   # already ours and pointing at the same place
  fi
  local bak="$target.cooee.bak"
  if [[ -e "$bak" || -L "$bak" ]]; then
    rm -rf "$target"
    log "dotfiles: replaced $(basename "$target") (a $(basename "$bak") from an earlier run is kept)."
    return 0
  fi
  mv "$target" "$bak" && log "dotfiles: backed up $(basename "$target") -> $(basename "$bak")."
}

# Symlink every top-level dotfile/dir in <repo_dir> into $HOME. Echoes the number
# applied. Symlinks (not copies) so a later re-pull of the repo takes effect
# without re-running the module.
cooee_dotfiles_symlink() {  # <repo_dir>
  local dest="$1" entry name n=0
  for entry in "$dest"/.*; do
    name=$(basename "$entry")
    [[ "$name" == "." || "$name" == ".." ]] && continue
    cooee_dotfiles_skipped "$name" && continue
    [[ -e "$entry" ]] || continue
    cooee_dotfiles_backup "$HOME/$name" "$entry"
    ln -sfn "$entry" "$HOME/$name" && n=$((n + 1))
  done
  printf '%s' "$n"
}

# Whether <repo_dir> looks like a GNU Stow package tree: no top-level dotfiles of
# its own, but at least one top-level directory that isn't skipped. That's the
# layout stow expects (each directory is a package whose contents are mirrored
# into the target), and it's exactly the case plain symlinking would get wrong —
# it would link the package directories themselves into $HOME.
cooee_dotfiles_looks_stowable() {  # <repo_dir>
  local dest="$1" entry name dirs=0
  for entry in "$dest"/.*; do
    name=$(basename "$entry")
    [[ "$name" == "." || "$name" == ".." ]] && continue
    cooee_dotfiles_skipped "$name" && continue
    [[ -e "$entry" ]] && return 1      # a real top-level dotfile -> not stow
  done
  for entry in "$dest"/*; do
    [[ -d "$entry" ]] || continue
    cooee_dotfiles_skipped "$(basename "$entry")" && continue
    dirs=$((dirs + 1))
  done
  (( dirs > 0 ))
}

# The repo's installer, if it has one we'd accept. Empty (rc 1) otherwise.
cooee_dotfiles_installer() {  # <repo_dir>
  local dest="$1" cand
  for cand in $COOEE_DOTFILES_INSTALLERS; do
    [[ -f "$dest/$cand" && -x "$dest/$cand" ]] && { printf '%s' "$dest/$cand"; return 0; }
  done
  return 1
}

# Apply <repo_dir> to $HOME. Three strategies, most specific first:
#   1. the repo's own installer — only with COOEE_DOTFILES_RUN_INSTALL=1, since
#      running it is arbitrary code execution from a request parameter;
#   2. GNU Stow, when it's already installed and the layout is a package tree;
#   3. symlink the top-level dotfiles, backing up whatever they'd clobber.
cooee_dotfiles_apply() {  # <repo_dir> <repo>
  local dest="$1" repo="$2" installer=""

  if installer=$(cooee_dotfiles_installer "$dest"); then
    if [[ "${COOEE_DOTFILES_RUN_INSTALL:-0}" == 1 ]]; then
      log "dotfiles: running ${installer#$dest/} from $repo..."
      if ( cd "$dest" && "$installer" ); then
        ok "dotfiles: $repo applied via ${installer#$dest/}."
        return 0
      fi
      warn "dotfiles: ${installer#$dest/} failed for $repo; falling back to linking."
    else
      log "dotfiles: $repo ships ${installer#$dest/}, not running it (set COOEE_DOTFILES_RUN_INSTALL=1 to allow); linking instead."
    fi
  fi

  if command -v stow >/dev/null 2>&1 && cooee_dotfiles_looks_stowable "$dest"; then
    local -a pkgs=() entry
    for entry in "$dest"/*; do
      [[ -d "$entry" ]] || continue
      cooee_dotfiles_skipped "$(basename "$entry")" && continue
      pkgs+=("$(basename "$entry")")
    done
    # --restow re-links cleanly on a re-run instead of erroring on existing links.
    if stow --restow --dir "$dest" --target "$HOME" "${pkgs[@]}" 2>/dev/null; then
      ok "dotfiles: $repo applied via stow (${#pkgs[@]} package(s): ${pkgs[*]})."
      return 0
    fi
    warn "dotfiles: stow failed for $repo (conflicting files in \$HOME?); falling back to linking."
  fi

  local n; n=$(cooee_dotfiles_symlink "$dest")
  if (( n )); then
    ok "dotfiles: $repo applied — $n entr(ies) linked into \$HOME."
  else
    warn "dotfiles: nothing to apply from $repo (no top-level dotfiles found)."
  fi
}

module_dotfiles() {
  local -a sources=("$@")
  if (( ! ${#sources[@]} )); then
    warn "dotfiles: no repo given and there is no sensible default — request dotfiles[owner/repo] (optionally @ref)."
    return 0
  fi

  # git is the only hard dependency; grab it from Nix if the box lacks it.
  if ! command -v git >/dev/null 2>&1; then
    log "git not found; installing via Nix..."
    nix_ensure git nixpkgs#git --accept-flake-config
  fi
  command -v git >/dev/null 2>&1 || die "git not on PATH; cannot install dotfiles."

  local cache_dir="$HOME/.cache/coo-ee/dotfiles"
  mkdir -p "$cache_dir"

  local applied=0 src spec ref repo slug dest
  for src in "${sources[@]}"; do
    # owner/repo with an optional @ref (branch/tag/sha) — the same coordinate
    # shape `skills` uses, minus the trailing selector (a dotfiles repo is
    # applied whole, so there's nothing to pick out of it).
    spec=${src%@*}; ref=""
    [[ "$src" == *@* ]] && ref=${src##*@}
    case "$spec" in
      */*/*) warn "skipping '$src' — expected owner/repo[@ref], not a path"; continue ;;
      */*) : ;;
      *) warn "skipping '$src' — expected owner/repo[@ref]"; continue ;;
    esac
    repo="$spec"
    slug=${repo//\//-}
    dest="$cache_dir/$slug"

    [[ "${COOEE_FORCE:-0}" == 1 ]] && rm -rf "$dest"

    if [[ -d "$dest/.git" ]]; then
      log "updating $repo..."
      git -C "$dest" fetch --quiet --depth 1 origin "${ref:-HEAD}" \
        && git -C "$dest" checkout --quiet --force FETCH_HEAD \
        || warn "could not update $repo; using the cached checkout."
    else
      log "cloning $repo${ref:+@$ref}..."
      if [[ -n "$ref" ]]; then
        git clone --quiet --depth 1 --branch "$ref" "https://github.com/$repo" "$dest" \
          || git clone --quiet --depth 1 "https://github.com/$repo" "$dest" \
          || { warn "clone failed for $repo"; continue; }
      else
        git clone --quiet --depth 1 "https://github.com/$repo" "$dest" \
          || { warn "clone failed for $repo"; continue; }
      fi
    fi

    cooee_dotfiles_apply "$dest" "$repo"
    applied=$((applied + 1))
  done

  if (( applied )); then
    ok "dotfiles ready: $applied repo(s) applied (cached under ${cache_dir/#$HOME/\~})."
  else
    warn "no dotfiles applied (check the source repo(s) and network)."
  fi
}
