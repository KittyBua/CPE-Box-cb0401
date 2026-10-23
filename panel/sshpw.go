package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	gossh "golang.org/x/crypto/ssh"
)

// runSSHPassword runs cmd against the router over SSH using the saved password
// (routerPass). Uses the Go SSH client directly so we don't need sshpass on the
// host - that binary isn't on Windows at all and isn't in minimal Linux
// containers either. Return shape matches runSSHRaw: stdout, stderr, exit code,
// and the timed-out flag.
func runSSHPassword(cmd string, timeout time.Duration) (stdout, stderr string, exitCode int, timedOut, notFound bool, err error) {
	if routerPass == "" {
		return "", "", -1, false, false, errors.New("no router password on file to retry the SSH login with")
	}
	cfg := &gossh.ClientConfig{
		User:            "root",
		Auth:            []gossh.AuthMethod{gossh.Password(routerPass)},
		HostKeyCallback: gossh.InsecureIgnoreHostKey(), // same posture as the shell path (ssh -o StrictHostKeyChecking=no)
		Timeout:         timeout,
		// Match what sshOpts() negotiates with the router's old dropbear:
		// SHA-1 host key + SHA-1 pubkey algorithms, legacy KEX and ciphers.
		HostKeyAlgorithms: []string{"ssh-rsa", "ssh-dss"},
		Config: gossh.Config{
			KeyExchanges: []string{
				"curve25519-sha256", "curve25519-sha256@libssh.org",
				"ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521",
				"diffie-hellman-group14-sha256", "diffie-hellman-group14-sha1",
				"diffie-hellman-group-exchange-sha256", "diffie-hellman-group-exchange-sha1",
				"diffie-hellman-group1-sha1",
			},
			Ciphers: []string{
				"aes128-ctr", "aes192-ctr", "aes256-ctr",
				"aes128-gcm@openssh.com", "aes256-gcm@openssh.com",
				"aes128-cbc", "aes192-cbc", "aes256-cbc", "3des-cbc",
			},
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	// dial honours the context deadline so a stuck SSH handshake doesn't
	// outlive our timeout.
	type dialResult struct {
		c   *gossh.Client
		err error
	}
	done := make(chan dialResult, 1)
	go func() {
		d := net.Dialer{Timeout: timeout}
		tcp, derr := d.DialContext(ctx, "tcp", net.JoinHostPort(routerIP, "22"))
		if derr != nil {
			done <- dialResult{nil, derr}
			return
		}
		conn, chans, reqs, derr := gossh.NewClientConn(tcp, routerIP, cfg)
		if derr != nil {
			tcp.Close()
			done <- dialResult{nil, derr}
			return
		}
		done <- dialResult{gossh.NewClient(conn, chans, reqs), nil}
	}()

	var client *gossh.Client
	select {
	case <-ctx.Done():
		return "", "", -1, true, false, nil
	case r := <-done:
		if r.err != nil {
			// Wrong password surfaces as "unable to authenticate"; a stuck /
			// unreachable modem as a dial / i/o error. The caller
			// (runSSH/retrySSH) only cares that the fallback didn't work.
			if strings.Contains(r.err.Error(), "unable to authenticate") || strings.Contains(r.err.Error(), "ssh: handshake failed") {
				return "", r.err.Error(), 255, false, false, nil
			}
			return "", "", -1, false, false, r.err
		}
		client = r.c
	}
	defer client.Close()

	sess, err := client.NewSession()
	if err != nil {
		return "", "", -1, false, false, fmt.Errorf("ssh session: %w", err)
	}
	defer sess.Close()

	var outb, errb bytes.Buffer
	sess.Stdout = &outb
	sess.Stderr = &errb
	runErr := sess.Run(cmd)
	if runErr != nil {
		var exitErr *gossh.ExitError
		if errors.As(runErr, &exitErr) {
			return outb.String(), errb.String(), exitErr.ExitStatus(), false, false, nil
		}
		if ctx.Err() == context.DeadlineExceeded {
			return outb.String(), errb.String(), -1, true, false, nil
		}
		return outb.String(), errb.String(), -1, false, false, runErr
	}
	return outb.String(), errb.String(), 0, false, false, nil
}
