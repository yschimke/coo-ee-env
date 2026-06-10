
# ===========================================================================
#  module: base — install Nix (Determinate Systems installer)
#    For a `?devenv` request, also install devenv.sh on top of Nix and provision
#    every module's packages through one ad-hoc devenv environment instead of
#    the default Nix profile. See cooee_devenv_* in _header.sh.
# ===========================================================================
register_module base
need_host install.determinate.systems   "Determinate Nix installer + binaries"
need_host cache.nixos.org                "Nix binary cache (substituter)"
need_host channels.nixos.org            "nixpkgs channel / flake source"
need_host github.com                     "nixpkgs + flake inputs"
need_host objects.githubusercontent.com  "GitHub release assets for flake inputs"

# Determinate's installer always lays down a root-owned (multi-user) store.
# - As root (typical agent sandbox) we read/write that store directly, so a
#   daemonless `--init none` install is enough.
# - As a non-root user (e.g. a CI runner) the store is only reachable through
#   the nix-daemon, which `--init none` never starts. So when we're not root we
#   either let the installer manage the daemon via systemd, or start it
#   ourselves afterwards.
cooee_nix_daemon_socket=/nix/var/nix/daemon-socket/socket

cooee_is_root()     { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }
cooee_has_systemd() { [[ -d /run/systemd/system ]]; }

cooee_start_nix_daemon() {  # bring up nix-daemon when there is no init to do it
  [[ -S "$cooee_nix_daemon_socket" ]] && return 0
  command -v sudo >/dev/null 2>&1 || { warn "non-root Nix install but no sudo to start nix-daemon; installs may fail."; return 0; }
  local daemon=/nix/var/nix/profiles/default/bin/nix-daemon
  [[ -x "$daemon" ]] || daemon=$(command -v nix-daemon 2>/dev/null || true)
  [[ -n "$daemon" && -x "$daemon" ]] || { warn "nix-daemon binary not found; cannot start it."; return 0; }
  log "Starting nix-daemon (non-root install without an init system)..."
  sudo --background "$daemon" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 50); do [[ -S "$cooee_nix_daemon_socket" ]] && break; sleep 0.2; done
  [[ -S "$cooee_nix_daemon_socket" ]] && ok "nix-daemon is up." \
    || warn "nix-daemon socket still absent; non-root nix commands may fail."
}

module_base() {
  if command -v nix >/dev/null 2>&1; then
    ok "Nix already installed: $(nix --version)"
  else
    # Pick the daemon strategy from who we are and whether systemd is around.
    local -a init_flags=(--init none)
    local manage_daemon=0
    if cooee_is_root; then
      log "Installing Nix (Determinate Systems installer, daemonless — running as root)..."
    elif cooee_has_systemd; then
      init_flags=(--init systemd)     # let the installer start nix-daemon.service
      log "Installing Nix (Determinate, systemd daemon — non-root host)..."
    else
      manage_daemon=1                 # no init: we'll start the daemon ourselves
      log "Installing Nix (Determinate, daemon started manually — non-root, no systemd)..."
    fi
    # flakes: needed for nix#pkgs references used by the modules.
    curl -fsSL https://install.determinate.systems/nix \
      | sh -s -- install linux \
          --no-confirm \
          "${init_flags[@]}" \
          --extra-conf "experimental-features = nix-command flakes"
    ok "Nix installed."
    [[ "$manage_daemon" == 1 ]] && cooee_start_nix_daemon
  fi

  # Put nix on PATH for the rest of THIS script...
  if [[ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi
  export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
  command -v nix >/dev/null 2>&1 || die "Nix not on PATH after install."

  # ...and for future shells (a PATH prepend, not a frozen snapshot). Recorded
  # in both persisted files so the short-circuit can replay it next session.
  echo 'export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"' \
    >> "$COOEE_PROFILE"
  printf 'PATH=%s\n' "$PATH" >> "$COOEE_HARNESS_ENV"
  cooee_forward_to_harness "PATH=$PATH"

  # devenv backend (?devenv): install devenv on top of Nix now, so the module
  # fragments' nix_ensure calls provision through an ad-hoc devenv.sh
  # environment instead of the default Nix profile. No-op for a plain request.
  cooee_devenv_enabled && cooee_devenv_install

  ok "base ready: $(nix --version)"
}
