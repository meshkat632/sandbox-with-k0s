//go:build unix

package runner

import (
	"os"
	"os/exec"
	"syscall"
)

// isolate puts the child in its own process group so signals aimed at our
// group do not reach it; relay then decides what it sees.
func isolate(cmd *exec.Cmd, own bool) {
	if own {
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	}
}

// relay passes a signal on to Terraform as an interrupt. A child sharing our
// terminal already got Ctrl-C from it, and a second interrupt would make
// Terraform exit without cleaning up, so that case is not relayed.
func relay(p *os.Process, sig os.Signal, isolated bool) {
	if !isolated && sig == os.Interrupt {
		return
	}
	_ = p.Signal(os.Interrupt)
}
