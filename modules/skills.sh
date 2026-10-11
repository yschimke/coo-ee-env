
# ===========================================================================
#  module: skills — install agent skills from one or more repos
#    type     : agent skills (NOT a Nix package) — the first "other kind of
#               dependency": clones skill repo(s) and links each skill into
#               ~/.claude/skills/, plus ~/.agents/skills/ when Codex or Gemini
#               is on the box (see cooee_skill_dirs), so every agent picks
#               them up.
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

  local cache_dir="$HOME/.cache/coo-ee/skills"
  mkdir -p "$cache_dir"

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

    # A skill is any directory containing SKILL.md; each name is linked once,
    # into every agent's skills dir (symlink so a re-run that re-pulls the repo
    # updates it).
    local skilldir n=0
    while IFS= read -r skilldir; do
      cooee_link_skill "$skilldir"
      ok "skill: $(basename "$skilldir")  ($repo)"
      n=$((n + 1)); installed=$((installed + 1))
    done < <(cooee_find_skills "$dest" "${skill##*/}")

    if (( n == 0 )); then
      [[ -n "$skill" ]] && warn "skill '${skill##*/}' not found in $repo" \
                        || warn "no SKILL.md found in $repo"
    fi
  done

  if (( installed )); then
    ok "skills ready: $installed skill(s) linked into $(cooee_skill_dirs | sed "s|^$HOME|~|" | paste -sd, -)"
  else
    warn "no skills installed (check the source repo(s) and network)."
  fi
}
