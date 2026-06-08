
# ===========================================================================
#  module: android-emulator
#    software : Android emulator runtime + system images. The implied `android`
#               module installs the emulator and system images into the SDK
#               (it reads this module's params); here we make KVM usable and
#               record/verify the request.
#    params   : android-emulator[36,wear-33] selects the system-image API levels
#               (also recorded in COOEE_ANDROID_EMULATOR_IMAGES)
#    hosts    : cache.nixos.org (install)
#             : dl.google.com (emulator binaries + system images)
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
  # (android-emulator[36,wear-33]); default to API 36 when none are given. The
  # implied `android` module reads these same params and builds the emulator +
  # matching system images into the SDK, so by the time we run here the emulator
  # is already installed. Record them for reference / the androidenv flake.
  local -a images=("$@")
  (( ${#images[@]} )) || images=(36)
  add_env COOEE_ANDROID_EMULATOR_IMAGES "${images[*]}"

  # An emulator is only usable with KVM acceleration — configure it regardless
  # of where the emulator binary came from.
  cooee_configure_kvm

  # The `android` module installed (or adopted) the emulator. Verify it's on
  # PATH and report; warn if it isn't (e.g. an adopted SDK without the emulator).
  if command -v emulator >/dev/null 2>&1; then
    ok "android-emulator: $(emulator -version 2>/dev/null | head -1 || echo emulator) ready ($(command -v emulator))."
    (( ${#images[@]} )) && ok "android-emulator: system images for ${images[*]} installed with the SDK."
  else
    warn "android-emulator: no 'emulator' on PATH — the adopted SDK may not include"
    warn "it. Re-run with COOEE_FORCE=1 to build a complete SDK (emulator + system"
    warn "images) via Nix, or add the emulator to your existing SDK."
  fi
}
