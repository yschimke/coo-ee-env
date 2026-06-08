
# ===========================================================================
#  module: android-emulator
#    software : Android emulator runtime + system images (project androidenv)
#               images from the path (android-emulator[34,wear-33]) -> recorded
#               in COOEE_ANDROID_EMULATOR_IMAGES for the project's androidenv flake
#    hosts    : cache.nixos.org (install)
#             : dl.google.com (emulator binaries + system images, advisory)
#    implies  : android (adb / ANDROID_HOME) — pulled in automatically
#  An emulator needs KVM acceleration. When /dev/kvm exists but isn't accessible
#  (the GitHub-hosted runner case) we apply the documented 99-kvm4all.rules to
#  grant access; when KVM is absent we warn rather than fail.
# ===========================================================================
# coo.ee:implies android
register_module android-emulator
provides_tool android-emulator emulator   # adopt an existing emulator binary
need_host cache.nixos.org   "prebuilt emulator dependencies from the Nix cache"
want_host dl.google.com     "Android emulator binaries and system images"

# Make /dev/kvm usable for the emulator. GitHub-hosted Linux runners ship
# /dev/kvm but don't grant the runner user access; the documented fix is a udev
# rule that opens it up. See GitHub's emulator guidance and
# https://github.com/reactivecircus/android-emulator-runner. We apply it only
# when /dev/kvm exists but isn't accessible to this user (the runner case);
# already-accessible or absent are both no-ops.
cooee_configure_kvm() {
  if [[ ! -e /dev/kvm ]]; then
    warn "android-emulator: /dev/kvm absent — no KVM on this host. Emulators need"
    warn "a KVM-capable runner (a GitHub larger runner or bare-metal/VM host)."
    return 0
  fi
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ok "android-emulator: /dev/kvm already accessible (hardware acceleration ready)."
    return 0
  fi

  command -v udevadm >/dev/null 2>&1 || {
    warn "android-emulator: /dev/kvm present but not accessible and udevadm is"
    warn "missing — cannot configure KVM access here."
    return 0
  }

  log "android-emulator: granting /dev/kvm access via the documented udev rule..."
  local rule='KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"'
  if printf '%s\n' "$rule" | cooee_sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null \
     && cooee_sudo udevadm control --reload-rules \
     && cooee_sudo udevadm trigger --name-match=kvm; then
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
      ok "android-emulator: /dev/kvm configured (99-kvm4all.rules; emulator ready)."
    else
      warn "android-emulator: applied 99-kvm4all.rules but /dev/kvm still isn't"
      warn "writable — a fresh login or 'kvm' group membership may be needed."
    fi
  else
    warn "android-emulator: could not configure /dev/kvm (need root/sudo + udev)."
    warn "On GitHub runners, apply the documented 99-kvm4all.rules manually."
  fi
}

module_android-emulator() {
  # Record requested system-image API levels (android-emulator[34,wear-33]) for
  # the project's androidenv flake, regardless of where the emulator comes from.
  local images="${COOEE_VERSIONS[android-emulator]:-}"
  [[ -n "$images" ]] && add_env COOEE_ANDROID_EMULATOR_IMAGES "$images"

  # An emulator is only usable with KVM acceleration — configure it whether we
  # adopt an existing emulator or delegate provisioning to the androidenv flake.
  cooee_configure_kvm

  # Adopt an existing emulator (warm box / base image) when present.
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v emulator >/dev/null 2>&1; then
    ok "android-emulator: adopted existing $(emulator -version 2>/dev/null | head -1 || echo emulator) ($(command -v emulator))."
    [[ -n "$images" ]] && warn "requested system images: $images (COOEE_ANDROID_EMULATOR_IMAGES)."
    return 0
  fi

  # Like the SDK platforms, the emulator and its system images are licensed and
  # large, and the versions belong to the project, not this bootstrap. We record
  # the request and let the repo's androidenv flake provision the emulator and
  # AVDs from it (adb / ANDROID_HOME come from the implied `android` module).
  warn "android-emulator: the emulator and system images are provisioned by the"
  warn "project's androidenv flake (see README.md), not installed here."
  if [[ -n "$images" ]]; then
    warn "requested system images: $images"
    warn "(exported as COOEE_ANDROID_EMULATOR_IMAGES for the androidenv flake)."
  fi
}
