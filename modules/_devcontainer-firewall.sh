#!/usr/bin/env bash
# coo.ee/env — default-deny egress firewall for the generated devcontainer
# (option B). NOT an installer fragment — the leading underscore keeps it out of
# the module catalog; it is embedded verbatim into the devcontainer apply script
# and copied to /usr/local/bin/init-firewall.sh in the image.
#
# Model: resolve the allowlist to IPs *first* (the firewall isn't up yet, so
# egress is still open), build an ipset, then flip to default-deny and allow
# only loopback, established traffic, DNS, the local docker network, and the
# resolved allowlist. Mirrors the Claude Code / Codex reference firewalls.
# Requires NET_ADMIN/NET_RAW (set in devcontainer.json runArgs).
set -euo pipefail

ALLOWLIST="${COOEE_ALLOWED_DOMAINS_FILE:-/etc/cooee/allowed-domains.txt}"

command -v iptables >/dev/null 2>&1 || { echo "coo.ee/env: iptables not found" >&2; exit 1; }
command -v ipset    >/dev/null 2>&1 || { echo "coo.ee/env: ipset not found" >&2; exit 1; }
[ -r "$ALLOWLIST" ] || { echo "coo.ee/env: allowlist $ALLOWLIST not readable" >&2; exit 1; }

# 1) Resolve the allowlist while egress is still open. Build the ipset.
ipset destroy allowed-domains 2>/dev/null || true
ipset create allowed-domains hash:net family inet

add_ip() { ipset add allowed-domains "$1" 2>/dev/null || true; }
resolve() {
  local d="$1" ip
  for ip in $(dig +short A "$d" 2>/dev/null); do
    [[ "$ip" =~ ^[0-9.]+$ ]] && add_ip "$ip"
  done
}

# GitHub publishes its IP ranges; pull them so git/gh/raw all work (opt out with
# COOEE_INCLUDE_GITHUB_META=0). Done before the lockdown, so 443 is reachable.
if [ "${COOEE_INCLUDE_GITHUB_META:-1}" = "1" ]; then
  curl -fsS --max-time 10 https://api.github.com/meta 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | sort -u \
    | while read -r cidr; do add_ip "$cidr"; done || true
fi

while IFS= read -r line; do
  line="${line%%#*}"                      # strip comments
  line="$(printf '%s' "$line" | tr -d '[:space:]')"
  [ -z "$line" ] && continue
  resolve "$line"
done < "$ALLOWLIST"

# 2) Lock egress down: default-deny + explicit allowances + the ipset.
iptables -F
iptables -X 2>/dev/null || true
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Let the container reach its own docker network (host gateway, port-forwards).
host_net="$(ip -o -f inet addr show 2>/dev/null | awk '/scope global/ {print $4}' | head -n1)"
[ -n "${host_net:-}" ] && iptables -A OUTPUT -d "$host_net" -j ACCEPT

iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

n="$(ipset list allowed-domains 2>/dev/null | grep -cE '^[0-9]' || true)"
echo "coo.ee/env: egress firewall up — ${n} allowed entries from ${ALLOWLIST}" >&2
