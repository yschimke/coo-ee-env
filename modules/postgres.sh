# ===========================================================================
#  module: postgres
#    software : a running local PostgreSQL server + its client tools
#    params   : postgres[16] picks the major version; default: the newest the
#               box already has (e.g. the cloud image's postgresql-16), else the
#               nixpkgs default
#    hosts    : cache.nixos.org (install, only when the box has no PostgreSQL)
#  The server is the part that needs care, not the binaries. A cloud image may
#  ship PostgreSQL yet leave its bin dir off PATH and the cluster stopped, and
#  the server refuses to run as root — the usual sandbox user. So this module
#  owns a dev cluster of its own: initdb'd once (as the `postgres` OS user when
#  we are root), trust auth on localhost only, superuser roles for both the
#  invoking user and `postgres`, and started on EVERY run — including the
#  already-provisioned fast path, because no server process survives a fresh
#  container. It exports PGHOST/PGPORT (never DATABASE_URL, which Rails would
#  apply to every environment, test included). See README "PostgreSQL".
# ===========================================================================
register_module postgres
provides_tool postgres pg_ctl
# Pre-approve the client tools a session uses against the local server.
provides_perms postgres "Bash(psql:*)" "Bash(pg_ctl:*)" "Bash(pg_isready:*)" "Bash(createdb:*)" "Bash(dropdb:*)" "Bash(createuser:*)" "Bash(pg_dump:*)" "Bash(pg_restore:*)"
need_host cache.nixos.org "PostgreSQL from the Nix cache (only when the box has none)"

COOEE_PG_PORT="${COOEE_PG_PORT:-5432}"

# The requested major version, from the module's params (postgres[16]).
cooee_pg_requested() {
  local p="${_MODULE_PARAMS[postgres]:-}"
  printf '%s' "${p%%[.,]*}"
}

# The bin dir holding pg_ctl/initdb/postgres for <major> (any major when empty),
# or nothing. Debian/Ubuntu packages keep the server under
# /usr/lib/postgresql/<major>/bin and only put client wrappers on PATH, so look
# there as well as on PATH. Newest major wins.
cooee_pg_bindir() {  # cooee_pg_bindir [major]
  local want=${1:-} d v best="" bestv=-1
  if command -v pg_ctl >/dev/null 2>&1; then
    d=$(dirname "$(readlink -f "$(command -v pg_ctl)")")
    v=$("$d/pg_ctl" --version 2>/dev/null | sed -n 's/.*(PostgreSQL) \([0-9]*\).*/\1/p')
    if [[ -n "$v" && ( -z "$want" || "$v" == "$want" ) ]]; then best=$d; bestv=$v; fi
  fi
  for d in "${COOEE_PG_SYSTEM_ROOT:-/usr/lib/postgresql}"/*/bin; do
    [[ -x "$d/pg_ctl" && -x "$d/initdb" ]] || continue
    v=$(basename "$(dirname "$d")")
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    [[ -n "$want" && "$v" != "$want" ]] && continue
    (( v > bestv )) && { best=$d; bestv=$v; }
  done
  printf '%s' "$best"
}

cooee_present_postgres() { [[ -n "$(cooee_pg_bindir "$(cooee_pg_requested)")" ]]; }

# Where the cluster lives. Root's $HOME is mode 700, which the `postgres` OS user
# cannot traverse, so a root-run cluster goes under /var/lib instead.
cooee_pg_base() {
  if [[ -n "${COOEE_PG_BASE:-}" ]]; then printf '%s' "$COOEE_PG_BASE"
  elif [[ "${EUID:-$(id -u)}" -eq 0 ]]; then printf '/var/lib/coo-ee/postgres'
  else printf '%s' "$HOME/.local/share/coo-ee/postgres"; fi
}

# The OS user the server runs as: `postgres` when we are root (the server will
# not run as root; created if the image lacks it), else ourselves.
cooee_pg_os_user() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then id -un; return; fi
  if ! id postgres >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /var/lib/postgresql --shell /bin/sh postgres >/dev/null 2>&1 \
      || adduser --system --group --home /var/lib/postgresql postgres >/dev/null 2>&1 \
      || die "postgres: running as root and couldn't create a 'postgres' OS user for the server."
  fi
  printf 'postgres'
}

# Run a command as the server's OS user.
cooee_pg_as() {  # cooee_pg_as <user> <cmd...>
  local u=$1; shift
  if [[ "$u" == "$(id -un)" ]]; then "$@"
  elif command -v runuser >/dev/null 2>&1; then runuser -u "$u" -- "$@"
  else su -s /bin/sh "$u" -c "$(printf '%q ' "$@")"; fi
}

# The unix-socket dir: the distro's (libpq clients there look in it by default)
# when it exists, else one beside the cluster.
cooee_pg_socket_dir() {  # cooee_pg_socket_dir <os user>
  local d
  for d in /var/run/postgresql /run/postgresql; do
    [[ -d "$d" ]] && cooee_pg_as "$1" test -w "$d" && { printf '%s' "$d"; return; }
  done
  printf '%s' "$(cooee_pg_base)/run"
}

# A superuser role — and a database — named after the invoking OS user, so a bare
# `psql`, `createdb` and a database.yml without a username work as-is (the cluster's bootstrap role is
# `postgres`, which stays a superuser for configs that name it). Connects as the
# server's OS user, which our trust cluster and a distro cluster's peer auth both
# let in.
cooee_pg_ensure_role() {  # cooee_pg_ensure_role <bindir> <os user> <socket dir>
  local me; me=$(id -un)
  [[ "$me" == postgres ]] && return 0
  local -a psql=("$1/psql" -h "$3" -p "$COOEE_PG_PORT" -U postgres -d postgres -qtAX -v ON_ERROR_STOP=1)
  cooee_pg_as "$2" "${psql[@]}" \
      -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$me') THEN CREATE ROLE \"$me\" SUPERUSER LOGIN; END IF; END \$\$;" >&2 \
    || { warn "postgres: couldn't create a superuser role for '$me'."; return 0; }
  # CREATE DATABASE can't run inside DO, so check first.
  if [[ -z "$(cooee_pg_as "$2" "${psql[@]}" -c "SELECT 1 FROM pg_database WHERE datname = '$me'")" ]]; then
    cooee_pg_as "$2" "${psql[@]}" -c "CREATE DATABASE \"$me\" OWNER \"$me\"" >&2 \
      || warn "postgres: couldn't create a '$me' database."
  fi
}

# Start (initdb'ing first if needed) the dev cluster with <bindir>'s server.
# Idempotent: a server already answering on the port is left alone. Also called
# from the footer's fast path, since a fresh container has no server running, so
# it never calls add_env (the fast path replays the persisted env instead; an
# add_env there would append to the profile on every session) and returns
# non-zero rather than dying — the caller decides how fatal a failure is.
cooee_postgres_start() {  # cooee_postgres_start [bindir]
  local bin=${1:-} user base data sock log v
  [[ -n "$bin" ]] || bin=$(cooee_pg_bindir "$(cooee_pg_requested)")
  [[ -n "$bin" ]] || { warn "postgres: no PostgreSQL server binaries found; not starting."; return 1; }
  v=$("$bin/pg_ctl" --version 2>/dev/null | sed -n 's/.*(PostgreSQL) \([0-9]*\).*/\1/p')
  [[ -n "$v" ]] || { warn "postgres: couldn't read the server version from $bin/pg_ctl."; return 1; }
  user=$(cooee_pg_os_user)
  base=$(cooee_pg_base); data="$base/$v"; log="$base/$v.log"
  mkdir -p "$base"
  [[ "$user" != "$(id -un)" ]] && chown "$user" "$base"
  sock=$(cooee_pg_socket_dir "$user")
  mkdir -p "$sock" 2>/dev/null || true
  [[ "$user" != "$(id -un)" && "$sock" == "$base/run" ]] && chown "$user" "$sock"

  if "$bin/pg_isready" -q -h "$sock" -p "$COOEE_PG_PORT" 2>/dev/null; then
    ok "postgres: a server is already running on port $COOEE_PG_PORT (socket $sock)."
    cooee_pg_ensure_role "$bin" "$user" "$sock"
    return 0
  fi

  if [[ ! -s "$data/PG_VERSION" ]]; then
    log "postgres: initializing a dev cluster in $data (PostgreSQL $v, trust auth on localhost)..."
    cooee_pg_as "$user" "$bin/initdb" -D "$data" -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >&2 \
      || cooee_pg_as "$user" "$bin/initdb" -D "$data" -U postgres --auth=trust -E UTF8 --no-locale >&2 \
      || { warn "postgres: initdb failed for $data."; return 1; }
  fi

  # A container restart leaves postmaster.pid behind; its PID can be reused by
  # an unrelated process, which makes the server refuse to start. Nothing is
  # answering (checked above), so a pid file whose process isn't a postgres is stale.
  local pidf="$data/postmaster.pid" pid
  if [[ -f "$pidf" ]]; then
    pid=$(head -1 "$pidf" 2>/dev/null)
    if [[ -z "$pid" ]] || ! grep -qs postgres "/proc/$pid/comm"; then rm -f "$pidf"; fi
  fi

  log "postgres: starting PostgreSQL $v on port $COOEE_PG_PORT (log: $log)..."
  : >> "$log"; [[ "$user" != "$(id -un)" ]] && chown "$user" "$log"
  cooee_pg_as "$user" "$bin/pg_ctl" -D "$data" -l "$log" -w -t 60 \
      -o "-p $COOEE_PG_PORT -k $sock -c listen_addresses=localhost" start >&2 \
    || { tail -n 20 "$log" >&2 2>/dev/null; warn "postgres: server failed to start (log: $log)."; return 1; }

  cooee_pg_ensure_role "$bin" "$user" "$sock"
  ok "postgres ready: PostgreSQL $v on port $COOEE_PG_PORT (PGHOST=$sock; superuser roles: postgres, $(id -un); trust auth on localhost)."
}

module_postgres() {
  local want="${1:-}"; want=${want%%.*}
  local bin; bin=$(cooee_pg_bindir "$want")
  if [[ -z "$bin" && -n "$want" ]] && [[ -n "$(cooee_pg_bindir)" ]]; then
    warn "postgres: the box's PostgreSQL ($(cooee_pg_bindir)) isn't the requested major $want — installing $want via Nix."
  fi
  if [[ -n "$bin" && "${COOEE_FORCE:-0}" != 1 ]]; then
    ok "postgres: adopted existing PostgreSQL $("$bin/pg_ctl" --version 2>/dev/null | sed -n 's/.*(PostgreSQL) \([0-9.]*\).*/\1/p') ($bin)."
  else
    local attr=postgresql
    [[ -n "$want" ]] && attr="postgresql_${want}"
    log "Installing PostgreSQL ${want:-(nixpkgs default)} via Nix (nixpkgs#${attr})..."
    nix_ensure "$attr" "nixpkgs#${attr}" --accept-flake-config
    bin=$(cooee_pg_bindir "$want")
    [[ -n "$bin" ]] || die "postgres: pg_ctl not on PATH after installing nixpkgs#${attr}."
  fi
  # Debian keeps the server binaries off PATH; the session wants pg_ctl & co.
  # PGHOST/PGPORT point libpq clients (psql, the pg gem, a database.yml with no
  # host) at this server. Deliberately not DATABASE_URL: Rails merges it into
  # whichever environment is running, so the test suite would hit the dev DB.
  local user; user=$(cooee_pg_os_user)
  add_env PATH "$bin:$PATH"
  add_env PGHOST "$(cooee_pg_socket_dir "$user")"
  add_env PGPORT "$COOEE_PG_PORT"
  cooee_postgres_start "$bin" || die "postgres: couldn't start the dev server (see above)."
}
