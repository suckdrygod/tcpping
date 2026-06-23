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
cp "$ROOT/overlays/ssh_login_watch.go" server/ssh_login_watch.go
if grep -R --line-number --include='*.go' -E '^[[:space:]]*func[[:space:]]+(establishTerminalConnection|StartTerminal)[[:space:]]*\(' .; then
  echo "Unexpected remote-control function found; refusing to build."
  exit 1
fi
if grep -R --line-number --include='*.go' -E 'case[[:space:]]+v2\.MethodAgent(Exec|Terminal)' server; then
  echo "Unexpected command-execution path found in the server package; refusing to build."
  exit 1
fi
exec_hits="$(grep -R --line-number --include='*.go' -E '"os/exec"|exec\.Command' server || true)"
if [ -n "$exec_hits" ]; then
  unexpected_exec_hits="$(printf '%s\n' "$exec_hits" | grep -v 'server/vnstat.go:.*"os/exec"' | grep -v 'server/vnstat.go:.*exec.CommandContext(ctx, "vnstat", "--json")' | grep -v 'server/ssh_login_watch.go:.*"os/exec"' | grep -v 'server/ssh_login_watch.go:.*exec.CommandContext(ctx, "journalctl", "-f", "-n", "0", "-o", "cat")' | grep -v 'server/ssh_auth_guard.go:.*"os/exec"' | grep -v 'server/ssh_auth_guard.go:.*exec.CommandContext(ctx, "journalctl", "-u", "ssh", "-u", "sshd", "-f", "-o", "short-iso")' || true)"
  if [ -n "$unexpected_exec_hits" ]; then
    printf '%s\n' "$unexpected_exec_hits"
    echo "Unexpected command-execution path found in the server package; refusing to build."
    exit 1
  fi
fi
grep -q 'capabilities.*\[\]string{"ping"}' server/websocket.go || {
  echo "Agent capability list is broader than the reviewed TCP-ping-only policy."
  exit 1
}
gofmt -w cmd server
go test ./server ./cmd/flags
go build ./...

echo 'Patch applies and the TCP-safe agent builds successfully.'
