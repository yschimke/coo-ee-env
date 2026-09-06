
# ===========================================================================
#  module: compose — set up for Jetpack Compose @Preview rendering
#    type     : curated target. Pulls in the runtimes the compose-preview
#               workflow needs and installs the agent skill that drives it:
#               renders @Preview composables to PNG without Android Studio or
#               an emulator (the skill self-bootstraps its CLI/Gradle plugin).
#    software : Compose @Preview rendering — the compose-preview skill plus a
#               JDK + Android SDK (implies java, android). git is the only
#               direct dependency (from Nix only if the box lacks it).
#    hosts    : github.com (clone of the skill repo), cache.nixos.org (git +
#               the desktop-render native GL libs, from the Nix cache)
#  `compose` takes no params — it's a fixed bundle. To pick skills à la carte,
#  use `skills[yschimke/skills/<skill>]` instead.
# ===========================================================================
# compose-preview's `doctor` wants Java 17+ and, for Android projects, the SDK
# (Robolectric native graphics). It explicitly does NOT need an emulator, so we
# pull in java + android but not android-emulator.
#
# Compose Multiplatform *Desktop* previews render through Skia (skiko), whose
# native lib (libskiko-linux-x64.so) has load-time DT_NEEDED deps on
# libGL.so.1, libX11.so.6, libfontconfig.so.1 and libstdc++.so.6. On the Nix
# backend the render JVM is a Nix-store Temurin whose glibc loader searches the
# Nix store, not the system /usr/lib — so those libs are invisible and the
# forked render worker dies at load with "libGL.so.1: cannot open shared object
# file". We provision them from the Nix cache (a self-consistent closure built
# against the same glibc the JDK uses) and hand them to that JVM *through the JDK
# itself* — a wrapper JDK whose bin/java sets LD_LIBRARY_PATH before exec'ing the
# real launcher. Not through the session environment: these libraries carry the
# store's own glibc, so a JVM linked against the system one dies at dlopen if it
# ever sees them (compose-ai-tools#3690), and a conventional JDK doesn't need
# them anyway. The wrapper reaches only the JVM it launches, so a Gradle init
# script covers the JVMs that one *forks* — a toolchain worker runs on whatever
# JDK `jvmToolchain(N)` resolved, which on a mixed fleet is not the daemon's.
# See cooee_compose_desktop_gl, cooee_compose_wrap_render_jdk and
# cooee_gradle_init_desktop_gl.
# coo.ee:implies java android
register_module compose
need_host github.com      "git clone of the compose-preview skill repo"
want_host cache.nixos.org "git + the Compose Desktop native GL libs (libGL/libX11/fontconfig/libstdc++), from the Nix cache"

# The skill source is overridable for forks/pins, but defaults to the canonical
# repo + skill name.
COOEE_COMPOSE_SKILL_REPO="${COOEE_COMPOSE_SKILL_REPO:-yschimke/skills}"
COOEE_COMPOSE_SKILL="${COOEE_COMPOSE_SKILL:-compose-preview}"

# The Nix packages whose libraries skiko (Compose Desktop's Skia backend) needs
# at load time, beyond the glibc the JVM already provides. skiko's
# libskiko-linux-x64.so declares DT_NEEDED for libGL.so.1, libX11.so.6,
# libfontconfig.so.1 and libstdc++.so.6 (libm/libc/ld-linux come from glibc):
#   libglvnd          -> libGL.so.1 (+ libGLX/libGLdispatch/libEGL)
#   xorg.libX11       -> libX11.so.6
#   fontconfig.lib    -> libfontconfig.so.1
#   stdenv.cc.cc.lib  -> libstdc++.so.6
# Each lib carries its own RUNPATH, so its transitive deps (libxcb, freetype, …)
# resolve from the Nix store without being listed here. Override the set with
# COOEE_DESKTOP_GL_PACKAGES (space-separated nixpkgs attr paths) if a project
# needs more; set COOEE_NO_DESKTOP_GL=1 to skip GL provisioning entirely (e.g.
# an Android-only checkout that never renders desktop previews).
COOEE_DESKTOP_GL_PACKAGES="${COOEE_DESKTOP_GL_PACKAGES:-libglvnd xorg.libX11 fontconfig.lib stdenv.cc.cc.lib}"

# The lib dir cooee_compose_desktop_gl provisioned, or empty when it didn't run /
# failed. Read by cooee_compose_wrap_render_jdk, which the footer calls after ALL
# modules have run — the wrap needs $JAVA_HOME, and module order isn't guaranteed
# to put `java` before `compose`.
COOEE_DESKTOP_GL_LIB=""

# Prepend <dir> to LD_LIBRARY_PATH for this shell and persist it for future
# shells + the harness env files, so a Gradle-forked render JVM inherits it.
# Dedup-guarded so repeated provisions or a re-sourced profile never stack
# duplicates. The Nix JDK's own `java` wrapper only *prepends* its GTK/glib dirs
# to an existing LD_LIBRARY_PATH (it never clears it), so the value set here
# survives into the render JVM.
#
# FALLBACK ONLY, since the GL-aware render JDK below took over the job. A
# session-wide LD_LIBRARY_PATH reaches *every* process the session starts, not
# just the store JVM the store libraries belong to, and a store lib loaded into
# a JVM linked against the system glibc is a hard failure, not a fallback:
#
#   /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_ABI_DT_X86_64_PLT' not found
#     (required by /nix/store/…-glibc-2.42-67/lib/libpthread.so.0)
#
# That is compose-ai-tools#3690 — an Ubuntu JDK 21 picked by `jvmToolchain(21)`
# inheriting this variable, and every preview in the module dying at dlopen. So
# the libraries now travel with the JDK that can use them (see
# cooee_compose_wrap_render_jdk) and this is only used when that wrapper could
# not be built, where a *possibly* mismatched search path still beats a
# certainly-missing libGL.
cooee_prepend_ld_library_path() {  # <dir>
  local dir="$1"
  case ":${LD_LIBRARY_PATH:-}:" in
    *":$dir:"*) : ;;                                  # already active this shell
    *) export LD_LIBRARY_PATH="$dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
  esac
  # Future shells: a guarded block that prepends only when absent, so sourcing
  # the profile more than once is idempotent.
  {
    printf '# coo.ee/env: Compose Desktop native GL libs on LD_LIBRARY_PATH\n'
    printf 'case ":${LD_LIBRARY_PATH:-}:" in\n'
    printf '  *":%s:"*) : ;;\n' "$dir"
    printf '  *) export LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;\n' "$dir"
    printf 'esac\n'
  } >> "$COOEE_PROFILE"
  # Harness env files want a concrete KEY=value (they don't re-source the
  # profile) — forward the resolved value so every Bash command and the Gradle
  # daemon it spawns inherit it. cooee_forward_to_harness upserts, so the line
  # never accumulates across SessionStart re-fires.
  printf 'LD_LIBRARY_PATH=%s\n' "$LD_LIBRARY_PATH" >> "$COOEE_HARNESS_ENV"
  cooee_forward_to_harness "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
}

# Provision the native libraries Compose Desktop's Skia renderer (skiko) loads,
# and put them on LD_LIBRARY_PATH so the Nix render JVM can find them. Best
# effort: any failure warns and returns 0 — it must never fail provisioning, and
# an Android-only checkout that never renders desktop previews still works
# without it. No-op when COOEE_NO_DESKTOP_GL=1 or Nix isn't available.
cooee_compose_desktop_gl() {
  if [[ "${COOEE_NO_DESKTOP_GL:-0}" == 1 ]]; then
    log "compose: skipping desktop GL provisioning (COOEE_NO_DESKTOP_GL=1)."
    return 0
  fi
  if ! command -v nix >/dev/null 2>&1; then
    warn "compose: nix not on PATH; skipping desktop GL libs. Compose Desktop renders may fail with 'libGL.so.1: cannot open shared object file'."
    return 0
  fi

  # A buildEnv over the requested packages: one lib dir holding every soname
  # skiko needs directly, each symlinked into its store path so per-lib RUNPATHs
  # still resolve the transitive deps. --out-link doubles as a GC root so the
  # closure survives `nix store gc`.
  local -a gl_pkgs; read -r -a gl_pkgs <<< "$COOEE_DESKTOP_GL_PACKAGES"
  local paths_nix="" a
  for a in "${gl_pkgs[@]}"; do paths_nix+="pkgs.$a "; done
  cooee_nixpkgs_note_revision
  local nixpkgs_ref; nixpkgs_ref="$(cooee_nixpkgs_ref)"
  local expr="let
    pkgs = import (builtins.getFlake \"${nixpkgs_ref}\").outPath { system = builtins.currentSystem; };
  in pkgs.buildEnv { name = \"cooee-desktop-gl\"; paths = [ ${paths_nix}]; }"

  local link="$HOME/.cache/coo-ee/desktop-gl"
  mkdir -p "$(dirname "$link")"

  log "compose: provisioning Compose Desktop native GL libs (${COOEE_DESKTOP_GL_PACKAGES}) via Nix..."
  local out errf; errf=$(mktemp "${TMPDIR:-/tmp}/cooee-desktop-gl.XXXXXX" 2>/dev/null)
  if ! out=$(nix build --impure --print-out-paths --out-link "$link" --expr "$expr" 2>"$errf"); then
    [[ -n "$errf" ]] && { cat "$errf" >&2; rm -f "$errf"; }
    warn "compose: couldn't build the desktop GL libs; Compose Desktop renders may fail to load skiko. $(cooee_nixpkgs_hint) Set COOEE_NO_DESKTOP_GL=1 to silence, or COOEE_DESKTOP_GL_PACKAGES to adjust the set."
    return 0
  fi
  [[ -n "$errf" ]] && rm -f "$errf"

  local gllib="$link/lib"
  if [[ ! -e "$gllib/libGL.so.1" ]]; then
    warn "compose: desktop GL env built ($out) but libGL.so.1 is missing under $gllib; not touching LD_LIBRARY_PATH."
    return 0
  fi
  # Deliberately NOT put on LD_LIBRARY_PATH here: which JVMs may see these
  # libraries is decided by cooee_compose_wrap_render_jdk, once JAVA_HOME is
  # known. Exporting first and asking later is what handed store libraries to
  # system-glibc JVMs (see cooee_prepend_ld_library_path).
  COOEE_DESKTOP_GL_LIB="$gllib"
  ok "compose: desktop GL libs ready — $gllib (skiko's libGL/libX11/fontconfig/libstdc++)."
}

# ---- the render JVM carries the GL dir itself -------------------------------
#
# LD_LIBRARY_PATH alone is not enough, because it only reaches the render worker
# if every hop *exports* it: this hook -> the agent harness -> the Gradle client
# -> the Gradle daemon -> the forked render JVM. Claude Code's web sessions break
# that chain: they snapshot this hook's environment and replay it as the preamble
# of every Bash call, but as bare `KEY=value` assignments with no `export`. A var
# that already existed in the container env survives (assigning to an exported
# name keeps the export bit — that's why JAVA_HOME and JAVA_TOOL_OPTIONS make it
# through); a NEW one like LD_LIBRARY_PATH becomes shell-local and never reaches
# the daemon. `echo $LD_LIBRARY_PATH` prints it, `env | grep ^LD_LIBRARY_PATH=`
# does not, and every preview dies on "libGL.so.1: cannot open shared object
# file". Sourcing $COOEE_PROFILE doesn't rescue it either — the harness shell is
# non-interactive and non-login, so it reads neither .bashrc nor .profile.
#
# So don't depend on the variable surviving: make the JDK itself set it. We build
# a wrapper JDK — every entry symlinked to the real one, except bin/java, which is
# a shim that prepends the GL dir and execs the real launcher — and point
# JAVA_HOME at it.
#
# ONE wrapper is enough. Wrapping each installed major would be pointless — a JVM
# reports `java.home` from where its libjli lives, i.e. the real JDK, not the
# wrapper, so Gradle canonicalises a detected toolchain back to the real path and
# forks the store binary directly, straight past the shim.
#
# JAVA_HOME only, though: that same canonicalisation is why the wrapper must NOT
# be pinned on org.gradle.java.home, which is what this module used to do. Gradle
# 9 compares the daemon's reported java.home against the path that asked for it,
# the wrapper can never match, and every daemon build in the session dies before
# it configures. See cooee_gradle_props_unpin_java_home, and
# cooee_gradle_init_desktop_gl for where the per-JVM decision lives now.
COOEE_JDK_GL_DIR="${COOEE_JDK_GL_DIR:-$HOME/.cache/coo-ee/jdk-gl}"

# Whether the loader behind <java_home> searches /etc/ld.so.cache and /usr/lib.
# Nix/Guix store JDKs are patchelf'd to their own ld-linux, which does neither —
# so a container can ship a perfectly good /usr/lib/x86_64-linux-gnu/libGL.so.1,
# have `ldd` resolve it (ldd runs the *system* loader), and still fail at render.
# Anything outside a store is assumed conventional: it finds the system libs on
# its own and needs no wrapper.
cooee_jdk_loader_reads_system_cache() {  # <java_home>
  case "$1" in /nix/store/*|/gnu/store/*) return 1 ;; *) return 0 ;; esac
}

# Build (or refresh) the wrapper JDK for <real_home> with <gl_lib> baked in, and
# echo its path. Idempotent: the tree is rebuilt from scratch each run, so a JDK
# upgrade or a changed GL path can never leave a stale symlink behind.
cooee_build_gl_jdk_wrapper() {  # <real_home> <gl_lib> <major>
  local real="$1" gl="$2" major="$3"
  local dest="$COOEE_JDK_GL_DIR/$major"
  rm -rf "$dest" 2>/dev/null
  mkdir -p "$dest/bin" || return 1

  local entry name
  for entry in "$real"/*; do
    name=$(basename "$entry")
    [[ "$name" == bin ]] || ln -sfn "$entry" "$dest/$name" || return 1
  done
  # Every tool but `java` is a plain symlink — only the launcher needs the env.
  for entry in "$real"/bin/*; do
    name=$(basename "$entry")
    [[ "$name" == java ]] || ln -sfn "$entry" "$dest/bin/$name" || return 1
  done

  # Prepend, never replace: the Nix `java` wrapper prepends its own GTK/glib dirs
  # to whatever it inherits, and a caller may have their own entries.
  cat > "$dest/bin/java" <<EOF || return 1
#!/bin/sh
# Generated by coo.ee/env — gives skiko's DT_NEEDED libs to every JVM Gradle
# starts from this JAVA_HOME. Do not edit; regenerated on each provision.
LD_LIBRARY_PATH=${gl}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export LD_LIBRARY_PATH
exec ${real}/bin/java "\$@"
EOF
  chmod +x "$dest/bin/java" || return 1
  printf '%s' "$dest"
}

# Retire a wrapper JDK pinned as org.gradle.java.home in the user-dir
# gradle.properties by an earlier version of this module.
#
# Pinning it there was the original way to make the Gradle daemon carry the GL
# libs, and Gradle 9 rejects it outright: the daemon launched from the wrapper
# reports `java.home` from where its libjli lives — the real store JDK — so the
# context check compares the requested wrapper path against that real one, finds
# them different, and refuses to reconnect:
#
#   The newly created daemon process has a different context than expected.
#   Wanted:  jvmCriteria=~/.cache/coo-ee/jdk-gl/17 (from org.gradle.java.home)
#   Actual:  javaHome=/nix/store/…-temurin-bin-17.0.19
#
# That is not "renders fail", it is *every* daemon build in the session failing,
# on a box where nothing but the provisioner ever asked for a wrapper. A warm box
# still carries the line, so removing it is repair work, not just a code change.
#
# Only ever removes a value of OURS (one under $COOEE_JDK_GL_DIR). A path someone
# else pinned is their deliberate choice and is left exactly as it is — the same
# merge-safety contract as cooee_gradle_props_jvmargs. Opt out with
# COOEE_NO_GRADLE_PROPS=1.
cooee_gradle_props_unpin_java_home() {
  [[ "${COOEE_NO_GRADLE_PROPS:-0}" == 1 ]] && {
    log "compose: skipping the org.gradle.java.home check (COOEE_NO_GRADLE_PROPS=1)."; return 0; }

  local guh="${GRADLE_USER_HOME:-$HOME/.gradle}"
  local props="$guh/gradle.properties"
  [[ -f "$props" ]] || return 0
  grep -Eq "^[[:space:]]*org\.gradle\.java\.home[[:space:]]*=[[:space:]]*${COOEE_JDK_GL_DIR}/" "$props" || return 0

  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/cooee-gradle-props.XXXXXX") || {
    warn "compose: couldn't stage a gradle.properties edit; $props still pins a wrapper JDK on org.gradle.java.home, which Gradle 9 refuses to start a daemon for."
    return 0; }
  # `|| true`: grep exits 1 when it filters everything out, and a gradle.properties
  # holding nothing but our pin is exactly the case that must still be rewritten.
  grep -Ev "^[[:space:]]*org\.gradle\.java\.home[[:space:]]*=[[:space:]]*${COOEE_JDK_GL_DIR}/" "$props" > "$tmp" 2>/dev/null || true
  if mv -f "$tmp" "$props"; then
    ok "compose: dropped the wrapper-JDK org.gradle.java.home pin from $props (Gradle 9 rejects the daemon it produces; the GL libs travel by init script now)."
  else
    warn "compose: couldn't update $props; it still pins a wrapper JDK on org.gradle.java.home."
    rm -f "$tmp"
  fi
}

# ---- the fork boundary: a JVM only sees the store libs if it can use them -----
#
# The wrapper above fixes the JVM it launches, and NOTHING it forks. `exec java`
# with LD_LIBRARY_PATH exported means every descendant of the Gradle daemon
# inherits the store GL dir, whatever JDK that descendant runs on — and Gradle
# forks a *different* JDK all the time, because `jvmToolchain(N)` resolves N
# against every installation on the box. A cloud image that ships a system JDK 21
# and gets its 17 from Nix has a mixed fleet by construction, so a project whose
# render lane pins the major the image already had forks a system-glibc worker
# out of a store-glibc daemon, and skiko dies at load:
#
#   UnsatisfiedLinkError: libskiko-linux-x64.so: /lib/x86_64-linux-gnu/libc.so.6:
#     version `GLIBC_ABI_DT_X86_64_PLT' not found
#     (required by /nix/store/…-glibc-2.42-67/lib/libpthread.so.0)
#
# — the store libX11 pulls the store's own libpthread in beside the system libc
# the worker already runs on, and the newer one demands symbols the older cannot
# supply. That is compose-ai-tools#3690 again, one hop further down: the session
# environment is clean, the daemon's is not, and the daemon is what the worker
# inherits. (Seen on compose-preview-server#460, where all 17 `:ui-builder`
# render tests fail this way on a clean checkout of main.)
#
# The wrapper cannot reach that hop — Gradle canonicalises a detected toolchain
# back to the real JDK (a JVM reports `java.home` from where its libjli lives),
# so the forked launcher is the store binary or the system one, never a shim. The
# fork itself is the only place left that knows *both* the JDK the worker will
# run on and the environment it will get, and Gradle hands that to an init
# script: `$GRADLE_USER_HOME/init.d/*.gradle` is applied to every build, so one
# file retunes LD_LIBRARY_PATH per forked JVM. It cuts both ways —
#
#   * a worker on a system JDK gets the store dir removed (the crash above), and
#   * a worker on a store JDK gets it added, which the wrapper could never do,
#     since Gradle forks that JDK's real launcher straight past the shim.
#
# Opt out with COOEE_NO_GRADLE_INIT=1 (or COOEE_NO_GRADLE_PROPS=1, which turns
# off every Gradle-user-home write this module makes).
COOEE_GRADLE_INIT_FILE="${COOEE_GRADLE_INIT_FILE:-cooee-desktop-gl.init.gradle}"

# Write (or, with an empty <gl_lib>, retire) that init script. The file is ours
# alone — a name no human writes — so it is rewritten wholesale each run and a
# changed GL path or a retired one can never leave a stale rule behind.
cooee_gradle_init_desktop_gl() {  # <gl_lib>
  local gl="$1"
  if [[ "${COOEE_NO_GRADLE_INIT:-0}" == 1 || "${COOEE_NO_GRADLE_PROPS:-0}" == 1 ]]; then
    log "compose: skipping the Gradle fork-boundary init script (COOEE_NO_GRADLE_INIT/COOEE_NO_GRADLE_PROPS=1)."
    return 0
  fi

  local guh="${GRADLE_USER_HOME:-$HOME/.gradle}"
  local dir="$guh/init.d" file="$guh/init.d/$COOEE_GRADLE_INIT_FILE"

  if [[ -z "$gl" ]]; then
    # Nothing to hand out this run. An init script from a previous one would keep
    # pointing at a GC'd store path, so retire it rather than leave it applying.
    [[ -e "$file" ]] && { rm -f "$file" && log "compose: retired the Gradle fork-boundary init script ($file)."; }
    return 0
  fi

  mkdir -p "$dir" 2>/dev/null || {
    warn "compose: can't create $dir; a forked test worker on a system JDK may die loading skiko."
    return 0; }

  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/cooee-gradle-init.XXXXXX") || {
    warn "compose: couldn't stage $file; leaving it unchanged."; return 0; }

  # Groovy, applied to every build in this Gradle user home. Everything is
  # defensive: an init script that throws fails the build, and a render worker
  # that cannot find libGL is a far better outcome than a build that will not
  # configure at all.
  cat > "$tmp" <<EOF
// Generated by coo.ee/env — do not edit; regenerated on each provision.
//
// Hands the Compose Desktop (skiko) native GL libs to each forked JVM that can
// load them, and takes them away from each one that cannot. The dir below holds
// libGL/libX11/libfontconfig/libstdc++ built against the Nix store's glibc: a
// store JVM needs them (its loader never reads /etc/ld.so.cache, so the system
// copies are invisible to it) and a system-glibc JVM is *killed* by them.
def glDir = '${gl}'
def sep = File.pathSeparator

// Only a store JDK's loader is blind to the system libs — anything else finds
// them itself, and must never see the store ones.
def wantsGl = { String home ->
  home != null && (home.startsWith('/nix/store/') || home.startsWith('/gnu/store/'))
}

// Where the worker will actually launch from. The toolchain launcher is the
// truth (Gradle has already canonicalised it to a real JDK); \`executable\` is
// the fallback for a task that pins one by hand.
def jdkHome = { task ->
  try {
    def l = task.javaLauncher
    if (l != null && l.present) return l.get().metadata.installationPath.asFile.absolutePath
  } catch (Throwable ignored) { }
  try {
    def exe = task.executable
    if (exe) return new File(exe as String).parentFile?.parentFile?.absolutePath
  } catch (Throwable ignored) { }
  return null
}

// Rebuild the fork's LD_LIBRARY_PATH: drop our dir unconditionally (an inherited
// one from the daemon, or ours from an earlier run), then put it back only for a
// JVM that can use it. Every other entry keeps its order — someone else's
// library path is not ours to reshuffle.
def retune = { task ->
  try {
    def env = new LinkedHashMap<String, Object>(task.environment)
    def cur = env.get('LD_LIBRARY_PATH')
    def parts = new ArrayList<String>()
    if (cur != null) {
      for (String p : cur.toString().tokenize(sep)) { if (p != glDir) parts.add(p) }
    }
    if (wantsGl(jdkHome(task))) parts.add(0, glDir)
    // '' is a search path of no directories, not a missing variable — but a
    // forked env cannot express "unset", and glibc treats the two the same.
    env.put('LD_LIBRARY_PATH', parts.join(sep))
    task.environment = env
  } catch (Throwable t) {
    task.logger.info("coo.ee/env: leaving LD_LIBRARY_PATH alone for \${task.path}: \${t}")
  }
}

gradle.allprojects { proj ->
  proj.tasks.withType(org.gradle.api.tasks.testing.Test).configureEach { t -> t.doFirst { retune(t) } }
  proj.tasks.withType(org.gradle.api.tasks.JavaExec).configureEach { t -> t.doFirst { retune(t) } }
}
EOF

  if mv -f "$tmp" "$file"; then
    ok "compose: forked JVMs retune LD_LIBRARY_PATH per JDK via $file (store JDKs get $gl; every other JDK is kept clear of it)."
  else
    warn "compose: couldn't write $file; a forked test worker on a system JDK may die loading skiko."
    rm -f "$tmp"
  fi
}

# Footer hook: run after every module, so $JAVA_HOME is whatever the `java`
# module settled on regardless of module order. No-op unless the GL libs were
# provisioned and the render JDK actually needs the help.
cooee_compose_wrap_render_jdk() {
  # Repair first, unconditionally: a warm box provisioned by an older version of
  # this module carries an org.gradle.java.home pin that breaks every daemon build,
  # and it has to come out whether or not this run builds a wrapper at all.
  cooee_gradle_props_unpin_java_home

  # Independent of the wrapper, and of whether JAVA_HOME is a store JDK at all:
  # the init script is about the JDKs *Gradle* forks, and a system-JDK daemon can
  # still fork a store toolchain worker (and vice versa). With no GL dir to hand
  # out it retires an earlier run's file rather than leaving it applying.
  cooee_gradle_init_desktop_gl "$COOEE_DESKTOP_GL_LIB"

  [[ -n "$COOEE_DESKTOP_GL_LIB" ]] || return 0
  local real="${JAVA_HOME:-}"
  # No JAVA_HOME means we cannot tell whether the render JVM is a store one, and store libraries on
  # a system-glibc JVM fail harder (and far more confusingly) than a missing libGL does — so the
  # unknown case gets nothing. The fallback below is taken only where the JDK is known to need it.
  [[ -n "$real" && -x "$real/bin/java" ]] || {
    warn "compose: no usable JAVA_HOME; skipping the GL-aware render JDK (Compose Desktop renders may fail with 'libGL.so.1: cannot open shared object file')."
    return 0; }

  if cooee_jdk_loader_reads_system_cache "$real"; then
    # A conventional JDK finds the system libGL/libX11/fontconfig/libstdc++ through
    # /etc/ld.so.cache on its own, and handing it store libraries would *break* it — they carry the
    # store's glibc. So this box gets no GL environment at all, and any left over from a run of an
    # older version of this module is retired rather than left to poison the session.
    log "compose: $real is not a store JDK — its loader finds the system libs itself; no wrapper needed."
    cooee_unforward_from_harness LD_LIBRARY_PATH
    return 0
  fi

  local major; major=$(cooee_jdk_major "$real")
  [[ -n "$major" ]] || major=unknown

  local wrapper
  if ! wrapper=$(cooee_build_gl_jdk_wrapper "$real" "$COOEE_DESKTOP_GL_LIB" "$major") \
     || [[ -z "$wrapper" || ! -x "$wrapper/bin/java" ]]; then
    warn "compose: couldn't build the GL-aware render JDK under $COOEE_JDK_GL_DIR; falling back to LD_LIBRARY_PATH for the whole session."
    cooee_prepend_ld_library_path "$COOEE_DESKTOP_GL_LIB"
    return 0
  fi

  # Prove it before advertising it: a JDK that can't start is worse than none.
  if ! "$wrapper/bin/java" -version >/dev/null 2>&1; then
    warn "compose: the GL-aware render JDK at $wrapper doesn't run; leaving JAVA_HOME at $real."
    cooee_prepend_ld_library_path "$COOEE_DESKTOP_GL_LIB"
    return 0
  fi

  add_env JAVA_HOME "$wrapper"
  # The wrapper carries the libraries, so nothing else in the session needs to — and must not:
  # a session-wide value reaches system-glibc JVMs too. Retire any entry a previous run of this
  # module left in the harness env file (it is upserted, never rebuilt).
  cooee_unforward_from_harness LD_LIBRARY_PATH
  ok "compose: render JDK $major wraps $real and carries $COOEE_DESKTOP_GL_LIB (only this JDK sees the store libs; LD_LIBRARY_PATH is left alone, and Gradle picks the daemon JVM itself)."
}

module_compose() {
  # Compose Desktop (skiko/Skia) render libs, so the Nix render JVM can load the
  # native renderer. Runs first + independently of the skill link so a skill
  # clone hiccup can't leave desktop renders broken.
  cooee_compose_desktop_gl

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
