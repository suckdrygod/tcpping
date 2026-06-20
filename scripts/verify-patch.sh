#!/usr/bin/env bash
set -Eeuo pipefail

UPSTREAM_URL='https://gitlab.com/mr-potato/komari-agent.git'
UPSTREAM_REV='fc8179e316bd07d710213416d86e884e5c0e2c19'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

git clone --quiet "$UPSTREAM_URL" "$WORKDIR/upstream"
cd "$WORKDIR/upstream"
git checkout --quiet --detach "$UPSTREAM_REV"
git apply --check "$ROOT/patches/0001-enable-constrained-tcp-ping.patch"
git apply "$ROOT/patches/0001-enable-constrained-tcp-ping.patch"
gofmt -w cmd server
go build ./...

echo 'Patch applies and the TCP-safe agent builds successfully.'
