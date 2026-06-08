
# ===========================================================================
#  module: skills — install Claude Code agent skills from one or more repos
#    type     : agent skills (NOT a Nix package) — the first "other kind of
#               dependency": clones skill repo(s) and links each skill into
#               ~/.claude/skills/ so the agent picks them up.
#    params   : skills[owner/repo, owner/repo/<skill>, owner/repo@ref, ...]
#               a path segment after the repo picks one skill by name;
#               bare `skills` links every skill in yschimke/skills
#    software : git (pulled from Nix only if the box doesn't already have it)
#    hosts    : github.com (clone), cache.nixos.org (git, if absent)
# ===========================================================================
register_module skills
need_host github.com      "git clone of the requested skill repo(s)"
want_host cache.nixos.org "git from the Nix cache, only if git is not already present"

module_skills() {
  local -a sources=("$@")
  (( ${#sources[@]} )) || sources=("yschimke/skills")

  # git is the only hard dependency; grab it from Nix if the box lacks it.
  if ! command -v git >/dev/null 2>&1; then
    log "git not found; installing via Nix..."
    nix_ensure git nixpkgs#git --accept-flake-config
  fi
  command -v git >/dev/null 2>&1 || die "git not on PATH; cannot install skills."

  local skills_dir="$HOME/.claude/skills"
  local cache_dir="$HOME/.cache/coo-ee/skills"
  mkdir -p "$skills_dir" "$cache_dir"

  local installed=0 src spec ref repo slug dest owner rest skill
  for src in "${sources[@]}"; do
    # owner/repo, with an optional @ref (branch/tag/sha) and an optional skill
    # selector — a path segment after the repo that picks a single skill:
    #   owner/repo               -> link every skill in the repo (the default)
    #   owner/repo/<skill>       -> link only the skill directory named <skill>
    #   owner/repo/<skill>@ref   -> ...from a specific branch/tag/sha
    spec=${src%@*}; ref=""
    [[ "$src" == *@* ]] && ref=${src##*@}
    case "$spec" in
      */*) : ;;
      *) warn "skipping '$src' — expected owner/repo[/skill]"; continue ;;
    esac
    # The first two path segments are the GitHub repo; anything after picks a skill.
    owner=${spec%%/*}; rest=${spec#*/}
    repo="$owner/${rest%%/*}"
    skill=""; [[ "$rest" == */* ]] && skill=${rest#*/}
    slug=${repo//\//-}
    dest="$cache_dir/$slug"

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

    # A skill is any directory containing SKILL.md. Link each one into
    # ~/.claude/skills/ (symlink so a re-run that re-pulls the repo updates it).
    local skillmd name n=0
    while IFS= read -r -d '' skillmd; do
      name=$(basename "$(dirname "$skillmd")")
      # When a skill was named, link only that one (match on the directory name).
      [[ -n "$skill" && "$name" != "${skill##*/}" ]] && continue
      ln -sfn "$(dirname "$skillmd")" "$skills_dir/$name"
      ok "skill: $name  ($repo)"
      n=$((n + 1)); installed=$((installed + 1))
    done < <(find "$dest" -name SKILL.md -not -path '*/.git/*' -print0 2>/dev/null)

    if (( n == 0 )); then
      [[ -n "$skill" ]] && warn "skill '${skill##*/}' not found in $repo" \
                        || warn "no SKILL.md found in $repo"
    fi
  done

  if (( installed )); then
    ok "skills ready: $installed skill(s) linked into $skills_dir"
  else
    warn "no skills installed (check the source repo(s) and network)."
  fi
}
