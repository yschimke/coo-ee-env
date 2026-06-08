
# ===========================================================================
#  module: compose — set up for Jetpack Compose @Preview rendering
#    type     : curated target. Pulls in the runtimes the compose-preview
#               workflow needs and installs the agent skill that drives it:
#               renders @Preview composables to PNG without Android Studio or
#               an emulator (the skill self-bootstraps its CLI/Gradle plugin).
#    software : Compose @Preview rendering — the compose-preview skill plus a
#               JDK + Android SDK (implies java, android). git is the only
#               direct dependency (from Nix only if the box lacks it).
#    hosts    : github.com (clone of the skill repo), cache.nixos.org (git, if absent)
#  `compose` takes no params — it's a fixed bundle. To pick skills à la carte,
#  use `skills[yschimke/skills/<skill>]` instead.
# ===========================================================================
# compose-preview's `doctor` wants Java 17+ and, for Android projects, the SDK
# (Robolectric native graphics). It explicitly does NOT need an emulator, so we
# pull in java + android but not android-emulator.
# coo.ee:implies java android
register_module compose
need_host github.com      "git clone of the compose-preview skill repo"
want_host cache.nixos.org "git from the Nix cache, only if git is not already present"

# The skill source is overridable for forks/pins, but defaults to the canonical
# repo + skill name.
COOEE_COMPOSE_SKILL_REPO="${COOEE_COMPOSE_SKILL_REPO:-yschimke/skills}"
COOEE_COMPOSE_SKILL="${COOEE_COMPOSE_SKILL:-compose-preview}"

module_compose() {
  # git is the only direct dependency; grab it from Nix if the box lacks it.
  if ! command -v git >/dev/null 2>&1; then
    log "git not found; installing via Nix..."
    nix_ensure git nixpkgs#git --accept-flake-config
  fi
  command -v git >/dev/null 2>&1 || die "git not on PATH; cannot install the compose-preview skill."

  local repo="$COOEE_COMPOSE_SKILL_REPO" skill="$COOEE_COMPOSE_SKILL"
  local skills_dir="$HOME/.claude/skills"
  local cache_dir="$HOME/.cache/coo-ee/skills"
  local dest="$cache_dir/${repo//\//-}"
  mkdir -p "$skills_dir" "$cache_dir"

  if [[ -d "$dest/.git" ]]; then
    log "updating $repo..."
    git -C "$dest" fetch --quiet --depth 1 origin HEAD \
      && git -C "$dest" checkout --quiet --force FETCH_HEAD \
      || warn "could not update $repo; using the cached checkout."
  else
    log "cloning $repo..."
    git clone --quiet --depth 1 "https://github.com/$repo" "$dest" \
      || { warn "compose: clone failed for $repo (is github.com reachable?)"; return 0; }
  fi

  # Link just the requested skill — the directory named <skill> holding SKILL.md.
  local skillmd name linked=0
  while IFS= read -r -d '' skillmd; do
    name=$(basename "$(dirname "$skillmd")")
    [[ "$name" == "$skill" ]] || continue
    ln -sfn "$(dirname "$skillmd")" "$skills_dir/$name"
    ok "skill: $name  ($repo)"
    linked=1
  done < <(find "$dest" -name SKILL.md -not -path '*/.git/*' -print0 2>/dev/null)

  if (( linked )); then
    ok "compose ready: '$skill' skill linked; JDK + Android SDK come from the java/android modules."
  else
    warn "compose: skill '$skill' not found in $repo — nothing linked."
  fi
}
