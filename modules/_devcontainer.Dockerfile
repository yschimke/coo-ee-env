# syntax=docker/dockerfile:1
# coo.ee/env — devcontainer image (option B). NOT an installer fragment; the
# leading underscore keeps it out of the module catalog. It is embedded verbatim
# into the devcontainer apply script and written as .devcontainer/Dockerfile.
#
# This layer adds the egress-firewall tooling to a mainstream base. The
# toolchain itself is provisioned by postCreateCommand (see devcontainer.json),
# so it runs as the remote user with a correct PATH. Baking provisioning into a
# build-cached RUN layer (true per-module layering) is the next iteration — it
# needs the Nix-store / build-user story validated in a live container.
ARG BASE=mcr.microsoft.com/devcontainers/base:ubuntu
FROM ${BASE}

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl iptables ipset dnsutils sudo iproute2 \
 && rm -rf /var/lib/apt/lists/*

# The firewall + its allowlist (default-deny egress, applied at container start).
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY allowed-domains.txt /etc/cooee/allowed-domains.txt
RUN chmod 500 /usr/local/bin/init-firewall.sh
