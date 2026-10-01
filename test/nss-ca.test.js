// Tests for cooee_trust_cas_in_nss, the browser half of the proxy-CA fix.
//
// Chromium on Linux ignores SSL_CERT_FILE / NODE_EXTRA_CA_CERTS and the system
// store and trusts only its built-in roots plus ~/.pki/nssdb, so behind Claude
// Code's TLS-terminating proxy every Playwright navigation failed with
// net::ERR_CERT_AUTHORITY_INVALID. The fix imports the extra CAs there. These
// tests drive it with a fake certutil that records what it was asked to do, so
// they need neither NSS nor Nix.
//
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

const BODY = render("base").body.replace(/^main "\$@"$/m, ":");

function scratch(name) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `cooee-${name}-`));
}

/** A PEM block whose base64 body is unique to `tag` (certutil is fake, so it need not parse). */
function pem(tag) {
  const body = Buffer.from(`fake certificate ${tag}`).toString("base64");
  return `-----BEGIN CERTIFICATE-----\n${body}\n-----END CERTIFICATE-----\n`;
}

/**
 * A fake certutil on PATH: `-N` creates cert9.db, `-L` lists the nicknames
 * imported so far, `-A -n <nick>` records one. Every call is appended to calls.log.
 */
function fakeCertutil(dir) {
  const bin = path.join(dir, "bin");
  fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(
    path.join(bin, "certutil"),
    `#!/bin/bash
log="${dir}/calls.log"; state="${dir}/nicks"
echo "$*" >> "$log"
db=""; nick=""; mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) db="\${2#sql:}"; shift ;;
    -n) nick="$2"; shift ;;
    -N|-L|-A) mode="$1" ;;
  esac
  shift
done
case "$mode" in
  -N) touch "$db/cert9.db" ;;
  -L) printf 'Certificate Nickname   Trust Attributes\\n'; [[ -f "$state" ]] && sed 's/$/   C,,/' "$state" ;;
  -A) echo "$nick" >> "$state" ;;
esac
exit 0
`,
    { mode: 0o755 },
  );
  return bin;
}

function run(dir, cas, env = {}) {
  const home = path.join(dir, "home");
  fs.mkdirSync(home, { recursive: true });
  const file = path.join(dir, "reg.sh");
  // The real cooee_extra_ca_files also reads /usr/local/share/ca-certificates,
  // which differs per machine; pin the inputs so the test sees only its own.
  const list = cas.map((c) => `printf '%s\\n' ${JSON.stringify(c)}`).join("; ") || ":";
  fs.writeFileSync(
    file,
    `${BODY}\ncooee_extra_ca_files() { ${list}; }\ncooee_trust_cas_in_nss\n`,
  );
  const res = spawnSync("bash", [file], {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: home,
      PATH: `${fakeCertutil(dir)}:${process.env.PATH}`,
      GRADLE_USER_HOME: path.join(dir, "gradle-user-home"),
      ...env,
    },
  });
  assert.equal(res.status, 0, res.stderr);
  const out = res.stdout + res.stderr; // log/ok/warn write to stderr
  const log = path.join(dir, "calls.log");
  return { out, calls: fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n") : [], home };
}

const imports = (calls) => calls.filter((c) => c.includes(" -A "));

test("splits a bundle, dedupes across files, and creates the NSS db", () => {
  const dir = scratch("nss");
  const bundle = path.join(dir, "bundle.crt");
  fs.writeFileSync(bundle, pem("root-a") + pem("root-b") + pem("proxy"));
  const single = path.join(dir, "proxy.crt");
  fs.writeFileSync(single, pem("proxy")); // also inside the bundle

  const { calls, home } = run(dir, [bundle, single]);

  assert.ok(fs.existsSync(path.join(home, ".pki/nssdb/cert9.db")), "db created");
  assert.equal(calls.filter((c) => c.includes(" -N ")).length, 1);
  const added = imports(calls);
  assert.equal(added.length, 3, `one import per distinct certificate:\n${added.join("\n")}`);
  for (const c of added) assert.match(c, /-t C,, -n cooee-[0-9a-f]{16} -i /);
  assert.equal(fs.statSync(path.join(home, ".pki/nssdb")).mode & 0o777, 0o700);
});

test("a re-run imports nothing that is already in the db", () => {
  const dir = scratch("nss");
  const ca = path.join(dir, "proxy.crt");
  fs.writeFileSync(ca, pem("proxy") + pem("proxy-next"));

  run(dir, [ca]);
  fs.rmSync(path.join(dir, "calls.log"));
  const { calls, out } = run(dir, [ca]);

  assert.equal(imports(calls).length, 0);
  assert.equal(calls.filter((c) => c.includes(" -N ")).length, 0, "existing db is reused");
  assert.match(out, /0 new, 2 total/);
});

test("no extra CAs: certutil is never touched", () => {
  const dir = scratch("nss");
  const { calls, home } = run(dir, []);
  assert.deepEqual(calls, []);
  assert.ok(!fs.existsSync(path.join(home, ".pki")));
});

test("COOEE_NO_NSS_CA=1 opts out", () => {
  const dir = scratch("nss");
  const ca = path.join(dir, "proxy.crt");
  fs.writeFileSync(ca, pem("proxy"));
  const { calls } = run(dir, [ca], { COOEE_NO_NSS_CA: "1" });
  assert.deepEqual(calls, []);
});

test("the footer runs it on both the full and the fast path", () => {
  const footer = fs.readFileSync(path.join(__dirname, "../modules/_footer.sh"), "utf8");
  assert.equal((footer.match(/^\s*cooee_trust_cas_in_nss\b/gm) || []).length, 2);
});
