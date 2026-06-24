# TCP-safe Agent Security Review

## Remote-control boundary

The Komari panel contains remote-terminal and remote-execution features for
compatible agents. This derivative agent does not implement their handlers and
does not advertise those capabilities. Its server-supplied capability list is
exactly `ping`, and that handler accepts only allow-listed TCP targets after
DNS pinning, public-IP validation, port validation, timeout enforcement, and
rate limiting.

CI refuses to build if the patched `server` package contains an exec/terminal
handler, unexpected command execution, or a capability broader than constrained
TCP ping. The only permitted command execution paths are `server/vnstat.go`
calling the fixed local command `vnstat --json` with a timeout and the SSH
login watcher calling the fixed read-only command
`journalctl -f -n 0 -o cat` when file-based SSH logs are unavailable. The panel
cannot change those executables, arguments, environment, or targets. Upstream
self-update is forcibly disabled so it cannot replace this reviewed binary with
a different build.

## SSH login notifications

The optional SSH watcher is outbound-only. It reads new successful `sshd`
`Accepted` records from `/var/log/auth.log` or `/var/log/secure`; if those
files do not exist, it follows systemd journal with the fixed command above.
It skips all existing records at startup and sends a fixed JSON structure
containing only:

- username;
- source IP and source port;
- authentication method;
- timestamp.

It does not collect passwords, keys, commands, or session contents. It does
not edit PAM or SSH configuration and contains no remotely controlled
command-execution path.

## vnStat traffic accounting

The optional vnStat reporter is outbound-only. If the local `vnstat` binary is
installed, the agent runs `vnstat --json`, chooses the interface with the
largest total counter, and reports only interface name, cumulative rx/tx
counters, and daily rx/tx buckets. Missing vnStat is treated as unavailable and
does not break normal metric reporting.

## Residual risks

- The agent runs as root to read system metrics and protected authentication
  logs. A vulnerability in its parsers or dependencies would therefore have a
  high local impact.
- Some metric collectors invoke fixed local utilities such as `free`, `uname`,
  or GPU tools. Their executable names and arguments are compiled in and are
  never supplied by the panel.
- GitHub repository or release compromise remains a supply-chain risk. Release
  downloads are checked against the release `SHA256SUMS`, which detects
  corruption but is not an independent signature authority.
- A stolen node token can submit forged metrics and security events for that
  node, but cannot make this agent execute a shell command.

## Operational recommendations

- Protect the panel and GitHub accounts with MFA.
- Rotate a node token if it is exposed.
- Keep TCP probe host and port allow-lists narrow.
- Review release commits before upgrading and retain the automatic binary
  backup made by the upgrade script.
