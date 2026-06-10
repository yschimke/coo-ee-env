
# ===========================================================================
#  module: android-cli — install the Android CLI agent skill
#    type     : agent skill (NOT a Nix package). Clones the skill repo and links
#               the `android-cli` skill into ~/.claude/skills/ so the agent can
#               drive the Android command-line tools (adb, sdkmanager, avdmanager,
#               gradle) without Android Studio. The Android SDK it drives comes
#               from the `android` module, which this implies — and which implies
#               this back, so the skill and the SDK always travel together.
#    software : the android-cli agent skill + git (from Nix only if the box lacks
#               it). The SDK itself is installed by the implied `android` module.
#    hosts    : github.com (clone of the skill repo), cache.nixos.org (git, if absent)
#  `android-cli` takes no params — it's a fixed skill. To pick skills à la carte,
#  use `skills[yschimke/skills/<skill>]` instead.
# ===========================================================================
# coo.ee:implies android
register_module android-cli
need_host github.com      "git clone of the android-cli skill repo"
want_host cache.nixos.org "git from the Nix cache, only if git is not already present"

# The skill source is overridable for forks/pins, but defaults to the canonical
# repo + skill name.
COOEE_ANDROID_CLI_SKILL_REPO="${COOEE_ANDROID_CLI_SKILL_REPO:-yschimke/skills}"
COOEE_ANDROID_CLI_SKILL="${COOEE_ANDROID_CLI_SKILL:-android-cli}"

module_android-cli() {
  # git is the only direct dependency; grab it from Nix if the box lacks it.
  if ! command -v git >/dev/null 2>&1; then
    log "git not found; installing via Nix..."
    nix_ensure git nixpkgs#git --accept-flake-config
  fi
  command -v git >/dev/null 2>&1 || die "git not on PATH; cannot install the android-cli skill."

  local repo="$COOEE_ANDROID_CLI_SKILL_REPO" skill="$COOEE_ANDROID_CLI_SKILL"
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
      || { warn "android-cli: clone failed for $repo (is github.com reachable?)"; return 0; }
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
    ok "android-cli ready: '$skill' skill linked; the Android SDK comes from the android module."
  else
    warn "android-cli: skill '$skill' not found in $repo — nothing linked."
  fi
}
