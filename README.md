# Komari TCPing Safe Agent

`Komari TCPing Safe Agent` is a **release-overlay repository** for a constrained Komari Agent build.
It starts from the metric-only agent published by `mr-potato/komari-agent` at a pinned commit, applies one auditable patch, and builds Linux binaries in GitHub Actions.

It keeps system metrics, network traffic accounting, Komari v1/v2 reporting, and **TCP latency tasks only**. It does **not** include Web SSH, interactive terminals, remote shell commands, file transfer, ICMP ping, or HTTP probing.

## Security model

The agent accepts an `agent.ping` task only when all of these conditions hold:

- `ping_type` is exactly `tcp`.
- The target includes an explicit `host:port`.
- The host matches `--safe-tcp-allow-hosts`.
- The destination port matches `--safe-tcp-allow-ports`.
- DNS results are resolved once and pinned for the connection.
- Loopback, RFC1918, CGNAT, link-local, multicast, unspecified, benchmark, documentation, and other reserved IPv4 ranges are rejected.
- The agent has not exceeded `--safe-tcp-max-tasks-per-minute`.

The default policy is deliberately narrow:

```text
Allowed hosts: *.ip.zstaticcdn.com
Allowed ports: 80,443
Timeout:       3 seconds
Rate limit:    30 tasks/minute
```

That default works with targets such as `zj-cm-v4.ip.zstaticcdn.com:80` while blocking panel-supplied private, local, or arbitrary scan targets.

## What is deliberately absent

| Capability | Status |
|---|---:|
| CPU / RAM / disk / traffic monitoring | enabled |
| TCP latency task | enabled, allow-listed |
| ICMP latency task | removed |
| HTTP latency task | removed |
| Web SSH / terminal | removed |
| Remote command execution | removed |
| Agent self-update | forcibly disabled |
| Arbitrary host or port probing | rejected |

## Build provenance

- Base project: `https://gitlab.com/mr-potato/komari-agent`
- Pinned base revision: `fc8179e316bd07d710213416d86e884e5c0e2c19`
- Patch: [`patches/0001-enable-constrained-tcp-ping.patch`](patches/0001-enable-constrained-tcp-ping.patch)

The metric-only base already removed terminal, remote execution, and unrestricted ping handling. This repository reintroduces only the constrained TCP task path. The upstream Komari protocol documents `agent.ping` as the event used for TCP/ICMP/HTTP probes; the patch only handles the TCP branch and returns `-1` for rejected or failed tasks.  

## Releases

After this repository is placed on GitHub, create and push a tag such as:

```bash
git tag v1.2.13-safe.1
git push origin v1.2.13-safe.1
```

GitHub Actions builds and attaches these artifacts to the release:

```text
komari-agent-linux-amd64
komari-agent-linux-arm64
SHA256SUMS
```

## Install on a Linux VPS

Replace `REPO` if you use a different GitHub owner/repository name. The command never needs a GitHub token.

```bash
curl -fsSL https://raw.githubusercontent.com/suckdrygod/tcpping/main/install.sh | \
  sudo bash -s -- \
  -e https://agent.example.com \
  -t YOUR_NODE_TOKEN \
  --month-rotate 15 \
  --timezone Asia/Shanghai
```

The agent reports the configured reset day and effective IANA timezone to a
compatible Komari panel through its existing basic-info heartbeat. No extra
daemon or detection tool is installed.

### Upgrade an existing installation without entering its token again

```bash
curl -fsSL https://raw.githubusercontent.com/suckdrygod/tcpping/main/upgrade.sh | sudo bash
```

The upgrade keeps the existing service arguments, including `--month-rotate`,
and adds a small systemd timezone drop-in so the reported timezone exactly
matches the reset boundary used by the agent.

The installer creates/updates the `komari-agent.service` service, makes a timestamped backup of an existing `/opt/komari/agent`, and uses the safety defaults above.

### Add another approved host or port

For example, to allow only the zstatic domain plus Cloudflare `1.1.1.1:443`:

```bash
sudo sed -i \
  's#--safe-tcp-allow-hosts [^ ]*#--safe-tcp-allow-hosts *.ip.zstaticcdn.com,1.1.1.1#; s#--safe-tcp-allow-ports [^ ]*#--safe-tcp-allow-ports 80,443#' \
  /etc/systemd/system/komari-agent.service
sudo systemctl daemon-reload
sudo systemctl restart komari-agent
```

Prefer exact hosts or `*.suffix` rules. Do not use broad domain patterns merely to make arbitrary panel targets work.

## Verify after installing

```bash
systemctl status komari-agent --no-pager
journalctl -u komari-agent -n 80 --no-pager
systemctl cat komari-agent | grep -E 'safe-tcp|disable-auto-update'
```

For a valid zstatic TCP target, the Komari graph should populate after one or two monitoring intervals. Invalid targets are logged as rejected and are returned to Komari as a failed sample.

## Maintainer update process

The patch is tied to one precise base revision. Update it only after reviewing upstream changes that touch:

- `server/websocket.go`
- `server/task.go`
- `protocol/v2/jsonrpc.go`
- `cmd/root.go`
- `cmd/flags/flag.go`

Run the local verifier before a release:

```bash
./scripts/verify-patch.sh
```

## License

The base project is MIT licensed. This repository preserves the required upstream notice in [`NOTICE`](NOTICE) and ships only an overlay patch plus build/release tooling.
