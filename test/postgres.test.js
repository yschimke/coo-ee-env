// Tests for the `postgres` module: finding server binaries a distro keeps off
// PATH, the fast-path restart, and — when this machine has PostgreSQL and isn't
// running as root — a real initdb + start + connect against a throwaway port.
//
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

function scratch(name) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `cooee-${name}-`));
}

function run(seg, snippet, env = {}) {
  const body = render(seg).body.replace(/^main "\$@"$/m, ":");
  const dir = scratch("pg");
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${body}\n${snippet}\n`);
  return execFileSync("bash", ["-c", `bash "${file}" 2>&1`], {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: dir,
      COOEE_PROFILE: path.join(dir, "env.sh"),
      COOEE_HARNESS_ENV: path.join(dir, "env.harness"),
      CLAUDE_ENV_FILE: "",
      ...env,
    },
  }).trim();
}

// /usr/lib/postgresql/<major>/bin-style tree of stub binaries.
function fakeSystemRoot(majors) {
  const root = scratch("pgroot");
  for (const m of majors) {
    const bin = path.join(root, String(m), "bin");
    fs.mkdirSync(bin, { recursive: true });
    for (const tool of ["pg_ctl", "initdb"]) {
      fs.writeFileSync(path.join(bin, tool), `#!/bin/sh\necho "${tool} (PostgreSQL) ${m}.3 (Ubuntu ${m}.3-1)"\n`);
      fs.chmodSync(path.join(bin, tool), 0o755);
    }
  }
  return root;
}

// PATH without any real pg_ctl, so only the stub tree is visible.
const cleanPath = process.env.PATH.split(":")
  .filter((d) => !fs.existsSync(path.join(d, "pg_ctl")))
  .join(":");

test("server binaries off PATH are found, newest major first or as requested", () => {
  const root = fakeSystemRoot([14, 16]);
  const env = { COOEE_PG_SYSTEM_ROOT: root, PATH: cleanPath };
  assert.equal(run("postgres", "cooee_pg_bindir", env), path.join(root, "16", "bin"));
  assert.equal(run("postgres", "cooee_pg_bindir 14", env), path.join(root, "14", "bin"));
  assert.equal(run("postgres", "cooee_pg_bindir 17", env), "");
  assert.equal(run("postgres", "cooee_present_postgres && echo yes || echo no", env), "yes");
  assert.equal(
    run("postgres", "set_params postgres 17; cooee_present_postgres && echo yes || echo no", env),
    "no",
    "a requested major the box lacks is not present (so Nix installs it)",
  );
});

test("the server is (re)started on the already-provisioned fast path", () => {
  const body = render("postgres").body;
  const fast = body.slice(body.indexOf("if cooee_already_provisioned"), body.indexOf("cooee_builtin_pass\n"));
  assert.match(fast, /cooee_postgres_start/, "a fresh container has no server process");
});

test("postgres exports PGHOST/PGPORT and never DATABASE_URL", () => {
  const body = render("postgres").body;
  assert.match(body, /add_env PGHOST/);
  assert.match(body, /add_env PGPORT/);
  assert.doesNotMatch(body, /add_env DATABASE_URL/, "Rails would apply it to the test env too");
});

test("postgres pre-approves the client tools", () => {
  const perms = JSON.parse(run("postgres", "cooee_perms_json", { COOEE_NO_CHECKOUT_PERMS: "1" }));
  for (const rule of ["Bash(psql:*)", "Bash(createdb:*)", "Bash(pg_ctl:*)"]) assert.ok(perms.includes(rule), rule);
});

// The real thing, when this machine has a PostgreSQL server to drive. As root
// the module runs the server as the `postgres` OS user, which can't reach a
// root-owned temp dir — so this only runs unprivileged (CI runners, laptops).
const realBin = (() => {
  try {
    const out = execFileSync("bash", ["-c", "ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1"], { encoding: "utf8" }).trim();
    return out && fs.existsSync(path.join(out, "initdb")) ? out : "";
  } catch { return ""; }
})();
const isRoot = process.getuid && process.getuid() === 0;

test("a real dev cluster initdbs, starts, restarts and accepts the invoking user", {
  skip: !realBin ? "no PostgreSQL server on this machine" : isRoot ? "runs unprivileged only" : false,
}, () => {
  const base = scratch("pgdata");
  const port = String(55000 + Math.floor(Math.random() * 1000));
  const env = { COOEE_PG_BASE: base, COOEE_PG_PORT: port, PATH: `${realBin}:${process.env.PATH}` };
  try {
    const out = run("postgres", [
      "cooee_init_profile",
      "module_postgres",
      'psql -tAc "select current_user"',
      // a fresh container: server gone, stale pid file left behind
      'data=$(ls -d "$(cooee_pg_base)"/[0-9]*/)',
      'pg_ctl -D "$data" -m immediate stop >/dev/null',
      'echo 1 > "$data/postmaster.pid"',
      "cooee_postgres_start",
      'psql -tAc "select 42"',
    ].join("\n"), env);
    assert.match(out, /postgres ready/);
    assert.match(out, new RegExp(`^${os.userInfo().username}$`, "m"), "a role (and db) named after the user");
    assert.match(out, /^42$/m, "came back after a restart with a stale pid file");
  } finally {
    try {
      execFileSync("bash", ["-c", `for d in "${base}"/[0-9]*/; do "${realBin}/pg_ctl" -D "$d" -m immediate stop; done`], { stdio: "ignore" });
    } catch {}
  }
});
