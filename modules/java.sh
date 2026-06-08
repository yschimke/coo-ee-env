
# ===========================================================================
#  module: java
#    software : Temurin JDK 17 + 21 (via Nix), JAVA_HOME, JDK TLS fix
#    hosts    : cache.nixos.org (install)
#             : Gradle / Maven / toolchain registries (build, advisory)
#  Host set mirrors skills/compose-preview/references/agent-cloud.md.
# ===========================================================================
register_module java
provides_tool java java   # adopt an existing JDK (warm box or cloud base image)
need_host cache.nixos.org      "prebuilt Temurin JDK from the Nix cache"
want_host services.gradle.org  "Gradle distributions (wrapper download)"
want_host repo.gradle.org      "Gradle libraries / tooling artifacts"
want_host central.sonatype.com "Maven Central artifacts"
want_host api.foojay.io        "Java distro metadata for Gradle toolchains"
want_host api.adoptium.net     "JDK/toolchain provisioning API"
want_host jitpack.io           "dependencies published via JitPack"

module_java() {
  # Already provisioned (warm box) or provided by the cloud base image? Adopt
  # the existing JDK — set JAVA_HOME from it and skip the redundant Nix install.
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v java >/dev/null 2>&1; then
    add_env JAVA_HOME "$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    cooee_trust_cas_in_jdk "$JAVA_HOME"
    ok "java: adopted existing $(java -version 2>&1 | head -1) (JAVA_HOME=$JAVA_HOME)."
    return 0
  fi

  log "Installing Temurin JDK 17 + 21 via Nix..."
  # Both JDKs ship colliding files (e.g. lib/modules), so a single profile can't
  # hold both at the same priority — `nix profile add` aborts. Give them distinct
  # priorities (lower wins): 17 at 5 owns the `java`/`javac` symlinks (the
  # toolchain most repos here pin to), 21 at 6 installs alongside and stays
  # discoverable by Gradle toolchain resolution.
  nix_ensure temurin-bin-17 nixpkgs#temurin-bin-17 --accept-flake-config --priority 5
  nix_ensure temurin-bin-21 nixpkgs#temurin-bin-21 --accept-flake-config --priority 6

  # JAVA_HOME -> the active (priority-winning) JDK, i.e. 17.
  command -v java >/dev/null 2>&1 || die "java not on PATH after install."
  add_env JAVA_HOME "$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"

  # Cloud fix: a Nix JDK ignores the system trust store, so teach it about the
  # sandbox proxy CA now (otherwise Gradle HTTPS fails with PKIX errors).
  cooee_trust_cas_in_jdk "$JAVA_HOME"

  ok "java ready: $(java -version 2>&1 | head -1)"
}
