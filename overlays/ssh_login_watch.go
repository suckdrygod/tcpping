package server

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	v2 "github.com/komari-monitor/komari-agent/protocol/v2"
)

var acceptedSSHLoginPattern = regexp.MustCompile(`sshd(?:\[[0-9]+\])?: Accepted ([^ ]+) for ([A-Za-z0-9._-]+) from ([0-9A-Fa-f:.]+) port ([0-9]+)`)

type sshLogState struct {
	path   string
	offset int64
	info   os.FileInfo
}

// StartSSHLoginWatcher tails only successful OpenSSH authentication records.
// It never writes SSH configuration and never executes a command. Existing
// log contents are skipped on startup so an agent restart cannot replay old
// login events.
func StartSSHLoginWatcher(ctx context.Context) {
	paths := []string{"/var/log/auth.log", "/var/log/secure"}
	states := make(map[string]*sshLogState, len(paths))
	for _, path := range paths {
		if state := openSSHLogAtEnd(path); state != nil {
			states[path] = state
			log.Printf("SSH login notifier watching %s", path)
		}
	}
	if len(states) == 0 {
		log.Printf("SSH login notifier waiting for /var/log/auth.log or /var/log/secure")
		go watchSSHLoginJournal(ctx)
	}

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			for _, path := range paths {
				state := states[path]
				if state == nil {
					if next := openSSHLogAtEnd(path); next != nil {
						states[path] = next
						log.Printf("SSH login notifier watching %s", path)
					}
					continue
				}
				if err := pollSSHLog(state); err != nil && !os.IsNotExist(err) {
					log.Printf("SSH login notifier failed to read %s: %v", path, err)
				}
			}
		}
	}
}

func watchSSHLoginJournal(ctx context.Context) {
	if _, err := exec.LookPath("journalctl"); err != nil {
		log.Printf("SSH login notifier journal fallback unavailable: journalctl not found")
		return
	}
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		if err := runSSHLoginJournal(ctx); err != nil && ctx.Err() == nil {
			log.Printf("SSH login notifier journal fallback stopped: %v", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
			}
		}
	}
}

func runSSHLoginJournal(ctx context.Context) error {
	cmd := exec.CommandContext(ctx, "journalctl", "-f", "-n", "0", "-o", "cat")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return err
	}
	log.Printf("SSH login notifier watching systemd journal")

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 4096), 64*1024)
	for scanner.Scan() {
		if event, ok := parseAcceptedSSHLogin(scanner.Text()); ok {
			if err := reportAcceptedSSHLogin(event); err != nil {
				log.Printf("failed to report successful SSH login: %v", err)
			}
		}
	}
	scanErr := scanner.Err()
	waitErr := cmd.Wait()
	if scanErr != nil {
		return scanErr
	}
	return waitErr
}

func openSSHLogAtEnd(path string) *sshLogState {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return nil
	}
	return &sshLogState{path: path, offset: info.Size(), info: info}
}

func pollSSHLog(state *sshLogState) error {
	info, err := os.Stat(state.path)
	if err != nil {
		return err
	}
	if !os.SameFile(state.info, info) || info.Size() < state.offset {
		state.offset = 0
		state.info = info
	}
	if info.Size() == state.offset {
		return nil
	}

	file, err := os.Open(state.path)
	if err != nil {
		return err
	}
	defer file.Close()
	if _, err := file.Seek(state.offset, io.SeekStart); err != nil {
		return err
	}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 64*1024)
	for scanner.Scan() {
		if event, ok := parseAcceptedSSHLogin(scanner.Text()); ok {
			if err := reportAcceptedSSHLogin(event); err != nil {
				log.Printf("failed to report successful SSH login: %v", err)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	state.offset, err = file.Seek(0, io.SeekCurrent)
	return err
}

type acceptedSSHLogin struct {
	user       string
	remoteIP   string
	remotePort int
	authMethod string
	occurredAt time.Time
}

func parseAcceptedSSHLogin(line string) (acceptedSSHLogin, bool) {
	match := acceptedSSHLoginPattern.FindStringSubmatch(line)
	if len(match) != 5 || net.ParseIP(match[3]) == nil {
		return acceptedSSHLogin{}, false
	}
	port, err := strconv.Atoi(match[4])
	if err != nil || port < 1 || port > 65535 {
		return acceptedSSHLogin{}, false
	}
	method := strings.ToLower(strings.SplitN(match[1], "/", 2)[0])
	switch method {
	case "publickey", "password", "keyboard-interactive", "hostbased":
	default:
		return acceptedSSHLogin{}, false
	}
	return acceptedSSHLogin{user: match[2], remoteIP: match[3], remotePort: port, authMethod: method, occurredAt: time.Now().UTC()}, true
}

func reportAcceptedSSHLogin(event acceptedSSHLogin) error {
	id := fmt.Sprintf("ssh-login-%d", event.occurredAt.UnixNano())
	payload := v2.NewRequest(id, v2.MethodAgentSSHLogin, map[string]interface{}{
		"user":        event.user,
		"remote_ip":   event.remoteIP,
		"remote_port": event.remotePort,
		"auth_method": event.authMethod,
		"occurred_at": event.occurredAt.Format(time.RFC3339Nano),
	})
	_, err := postV2Request(payload)
	return err
}
