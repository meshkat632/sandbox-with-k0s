//go:build !unix

package runner

import (
	"os"
	"os/exec"
)

// On Windows the console delivers Ctrl-C to every attached process, and a
// process cannot be sent an interrupt, so there is nothing to set up or relay.

func isolate(*exec.Cmd, bool) {}

func relay(*os.Process, os.Signal, bool) {}
