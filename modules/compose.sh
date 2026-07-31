
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
# against the same glibc the JDK uses) and put them on LD_LIBRARY_PATH; the Nix
# `java` wrapper preserves a pre-set LD_LIBRARY_PATH, so the value survives into
# the JVM. See cooee_compose_desktop_gl.
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
  local expr="let
    pkgs = import (builtins.getFlake \"nixpkgs\").outPath { system = builtins.currentSystem; };
  in pkgs.buildEnv { name = \"cooee-desktop-gl\"; paths = [ ${paths_nix}]; }"

  local link="$HOME/.cache/coo-ee/desktop-gl"
  mkdir -p "$(dirname "$link")"

  log "compose: provisioning Compose Desktop native GL libs (${COOEE_DESKTOP_GL_PACKAGES}) via Nix..."
  local out errf; errf=$(mktemp "${TMPDIR:-/tmp}/cooee-desktop-gl.XXXXXX" 2>/dev/null)
  if ! out=$(nix build --impure --print-out-paths --out-link "$link" --expr "$expr" 2>"$errf"); then
    [[ -n "$errf" ]] && { cat "$errf" >&2; rm -f "$errf"; }
    warn "compose: couldn't build the desktop GL libs; Compose Desktop renders may fail to load skiko. Set COOEE_NO_DESKTOP_GL=1 to silence, or COOEE_DESKTOP_GL_PACKAGES to adjust the set."
    return 0
  fi
  [[ -n "$errf" ]] && rm -f "$errf"

  local gllib="$link/lib"
  if [[ ! -e "$gllib/libGL.so.1" ]]; then
    warn "compose: desktop GL env built ($out) but libGL.so.1 is missing under $gllib; not touching LD_LIBRARY_PATH."
    return 0
  fi
  cooee_prepend_ld_library_path "$gllib"
  COOEE_DESKTOP_GL_LIB="$gllib"
  ok "compose: desktop GL libs ready — $gllib on LD_LIBRARY_PATH (skiko can load libGL/libX11/fontconfig/libstdc++)."
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
# JAVA_HOME (and Gradle's own org.gradle.java.home) at it.
#
# ONE wrapper is enough, and it has to be the JDK that launches the Gradle
# *daemon*: every worker the daemon forks inherits the daemon's environment,
# whatever toolchain JDK that worker runs on. Wrapping each installed major would
# be pointless — a JVM reports `java.home` from where its libjli lives, i.e. the
# real JDK, not the wrapper, so Gradle canonicalises a detected toolchain back to
# the real path and would fork the store binary directly, straight past the shim.
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

# Pin <java_home> as org.gradle.java.home in the user-dir gradle.properties —
# Gradle's own channel for choosing the daemon JVM, and the one path that needs no
# environment inheritance at all. Same merge-safety contract as
# cooee_gradle_props_utf8: a value the user already set is never overwritten.
# Opt out with COOEE_NO_GRADLE_PROPS=1.
cooee_gradle_props_java_home() {  # <java_home>
  local home="$1"
  [[ "${COOEE_NO_GRADLE_PROPS:-0}" == 1 ]] && {
    log "compose: skipping org.gradle.java.home write (COOEE_NO_GRADLE_PROPS=1)."; return 0; }

  local guh="${GRADLE_USER_HOME:-$HOME/.gradle}"
  local props="$guh/gradle.properties"
  mkdir -p "$guh" 2>/dev/null || {
    warn "compose: can't create $guh; skipping org.gradle.java.home write."; return 0; }

  if [[ -f "$props" ]] && grep -Eq '^[[:space:]]*org\.gradle\.java\.home[[:space:]]*=' "$props"; then
    # Ours from a previous run -> refresh it (the wrapper path can change with a
    # JDK upgrade). Anyone else's -> their deliberate choice, leave it alone.
    if grep -Eq "^[[:space:]]*org\.gradle\.java\.home[[:space:]]*=[[:space:]]*${COOEE_JDK_GL_DIR}/" "$props"; then
      local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/cooee-gradle-props.XXXXXX") || return 0
      grep -Ev '^[[:space:]]*org\.gradle\.java\.home[[:space:]]*=' "$props" > "$tmp" 2>/dev/null || true
      printf 'org.gradle.java.home=%s\n' "$home" >> "$tmp"
      mv -f "$tmp" "$props" && ok "compose: refreshed org.gradle.java.home -> $home in $props."
    else
      log "compose: $props already pins org.gradle.java.home; leaving it as-is."
    fi
    return 0
  fi

  if printf 'org.gradle.java.home=%s\n' "$home" >> "$props"; then
    ok "compose: set org.gradle.java.home=$home in $props (daemon JVM carries the GL libs)."
  else
    warn "compose: couldn't write $props; the Gradle daemon may not find the GL libs."
  fi
}

# Footer hook: run after every module, so $JAVA_HOME is whatever the `java`
# module settled on regardless of module order. No-op unless the GL libs were
# provisioned and the render JDK actually needs the help.
cooee_compose_wrap_render_jdk() {
  [[ -n "$COOEE_DESKTOP_GL_LIB" ]] || return 0
  local real="${JAVA_HOME:-}"
  [[ -n "$real" && -x "$real/bin/java" ]] || {
    warn "compose: no usable JAVA_HOME; skipping the GL-aware render JDK."; return 0; }

  if cooee_jdk_loader_reads_system_cache "$real"; then
    log "compose: $real is not a store JDK — its loader finds the system libs itself; no wrapper needed."
    return 0
  fi

  local major; major=$(cooee_jdk_major "$real")
  [[ -n "$major" ]] || major=unknown

  local wrapper
  if ! wrapper=$(cooee_build_gl_jdk_wrapper "$real" "$COOEE_DESKTOP_GL_LIB" "$major") \
     || [[ -z "$wrapper" || ! -x "$wrapper/bin/java" ]]; then
    warn "compose: couldn't build the GL-aware render JDK under $COOEE_JDK_GL_DIR; Compose Desktop renders will depend on LD_LIBRARY_PATH being inherited."
    return 0
  fi

  # Prove it before advertising it: a JDK that can't start is worse than none.
  if ! "$wrapper/bin/java" -version >/dev/null 2>&1; then
    warn "compose: the GL-aware render JDK at $wrapper doesn't run; leaving JAVA_HOME at $real."
    return 0
  fi

  add_env JAVA_HOME "$wrapper"
  cooee_gradle_props_java_home "$wrapper"
  ok "compose: render JDK $major wraps $real and carries $COOEE_DESKTOP_GL_LIB (skiko loads without LD_LIBRARY_PATH being inherited)."
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
