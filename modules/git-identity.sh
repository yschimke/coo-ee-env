
# ===========================================================================
#  module: git-identity — commit as the account owner, not the agent
#    type     : configuration (NOT a Nix package) — writes user.name/user.email
#               to the global git config and installs nothing
#    params   : none — the identity comes from COOEE_GIT_NAME / COOEE_GIT_EMAIL,
#               else the GitHub account `gh` is authenticated as
#    software : nothing installed; needs git (and gh for the default)
#    hosts    : api.github.com (only for the gh default)
# ===========================================================================
# A cloud agent sandbox commits as whatever the harness wrote to ~/.gitconfig,
# and Claude Code on the web writes `Claude <noreply@anthropic.com>` there when
# the container starts. A repository that rejects an agent author/committer
# (commit-msg / pre-push hooks, an attribution CI gate) then fails the first
# commit — or, worse, a rebase silently restamps every commit with the agent as
# committer. This module runs after the harness has written its file and sets
# the account owner's identity instead.
#
# Resolution, per field:
#   1. COOEE_GIT_NAME / COOEE_GIT_EMAIL, when set (the explicit override — put
#      them in the cloud environment's variables);
#   2. else the GitHub account `gh api user` reports: its name (falling back to
#      the login) and its public email (falling back to the account's
#      <id>+<login>@users.noreply.github.com address, which GitHub attributes
#      to the account just the same).
# A field that resolves to nothing leaves the existing config alone, with a
# warning — the module never writes a half-made identity.
#
# Only the GLOBAL config is written. A repository's own `git config user.*`
# (e.g. a CI job committing as github-actions[bot]) still wins, which is why
# this does not export GIT_AUTHOR_* / GIT_COMMITTER_*: those would override
# every repo-local identity too. Because the harness can rewrite ~/.gitconfig
# when a container resumes, the fast path re-applies it every session.
register_module git-identity
want_host api.github.com "the GitHub account's name/email via gh (only without COOEE_GIT_NAME/EMAIL)"

# Never pulls in Nix: there is nothing to install, and with no git on the box
# there is nothing to configure either.
cooee_present_git-identity() { return 0; }

# Print "<name>\t<email>" for the authenticated GitHub account, or nothing.
cooee_git_identity_from_gh() {
  command -v gh >/dev/null 2>&1 || return 0
  local out
  out="$(timeout 15 gh api user \
    --jq '[.name // .login, .email // "\(.id)+\(.login)@users.noreply.github.com"] | @tsv' \
    2>/dev/null)" || return 0
  printf '%s' "$out"
}

cooee_git_identity_apply() {
  command -v git >/dev/null 2>&1 || { warn "git-identity: git not on PATH; nothing to configure."; return 0; }

  local name="${COOEE_GIT_NAME:-}" email="${COOEE_GIT_EMAIL:-}" src="COOEE_GIT_NAME/COOEE_GIT_EMAIL"
  if [[ -z "$name" || -z "$email" ]]; then
    local gh_name="" gh_email=""
    IFS=$'\t' read -r gh_name gh_email <<< "$(cooee_git_identity_from_gh)" || true
    [[ -z "$name" ]] && name="$gh_name"
    [[ -z "$email" ]] && email="$gh_email"
    src="the GitHub account (gh api user)"
    [[ -n "${COOEE_GIT_NAME:-}${COOEE_GIT_EMAIL:-}" ]] && src="COOEE_GIT_* + the GitHub account"
  fi

  if [[ -z "$name" || -z "$email" || "$name$email" == *$'\n'* ]]; then
    warn "git-identity: could not resolve a name and email (set COOEE_GIT_NAME and COOEE_GIT_EMAIL); git identity left as $(git config --global user.name 2>/dev/null || echo '<unset>') <$(git config --global user.email 2>/dev/null || echo '<unset>')>."
    return 0
  fi

  if [[ "$(git config --global user.name 2>/dev/null)" == "$name" \
     && "$(git config --global user.email 2>/dev/null)" == "$email" ]]; then
    ok "git-identity: already $name <$email>."
    return 0
  fi
  git config --global user.name "$name" && git config --global user.email "$email" \
    || { warn "git-identity: could not write the global git config."; return 0; }
  ok "git-identity: commits are now authored as $name <$email> (from $src)."
}

module_git-identity() { cooee_git_identity_apply; }
