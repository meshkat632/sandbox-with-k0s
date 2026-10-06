// Package runner executes Terraform in each stack, one after another.
package runner

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"slices"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/meshkat632/sandbox-with-k0s/tfstack/internal/stack"
)

// Status is the outcome of one stack.
type Status string

// The statuses a stack can end in.
const (
	StatusOK          Status = "ok"
	StatusChanges     Status = "changes" // plan -detailed-exitcode found a diff
	StatusFailed      Status = "failed"
	StatusInterrupted Status = "interrupted"
	StatusSkipped     Status = "skipped"
)

// Exit codes of the tool, derived from a Summary.
const (
	ExitOK          = 0
	ExitFailed      = 1
	ExitChanges     = 2 // same meaning as terraform plan -detailed-exitcode
	ExitInterrupted = 130
)

// Result records what happened in one stack.
type Result struct {
	Stack    string
	Status   Status
	Duration time.Duration
	Err      error
}

// Summary is the outcome of a whole run.
type Summary struct {
	Results     []Result
	Interrupted bool
}

// Runner runs one Terraform command across stacks.
type Runner struct {
	Bin             string   // terraform binary
	Command         string   // terraform subcommand, e.g. "plan"
	Args            []string // extra arguments for the subcommand
	Init            bool     // run "init -input=false" in each stack first
	ContinueOnError bool
	DryRun          bool // print the commands instead of running them
	Env             []string

	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
	Log    io.Writer // progress lines
	Color  bool

	// Signals delivers interrupt and termination signals. After the first one
	// the current stack is left to finish and no further stack starts.
	Signals <-chan os.Signal
	// Interactive says Terraform shares our terminal, which then delivers
	// Ctrl-C to it directly. Otherwise Terraform gets its own process group
	// and each signal is relayed to it as one interrupt.
	Interactive bool

	signalled bool
}

// Run executes the command in every stack, in the order given.
func (r *Runner) Run(stacks []stack.Stack) Summary {
	var sum Summary
	stop := false
	for i, s := range stacks {
		if !stop && r.pendingSignal() {
			stop = true
		}
		if stop {
			sum.Results = append(sum.Results, Result{Stack: s.Name, Status: StatusSkipped})
			continue
		}
		start := time.Now()
		status, err := r.runStack(s, fmt.Sprintf("[%d/%d]", i+1, len(stacks)))
		sum.Results = append(sum.Results, Result{Stack: s.Name, Status: status, Duration: time.Since(start), Err: err})
		switch {
		case r.signalled:
			stop = true
		case status == StatusFailed && !r.ContinueOnError:
			stop = true
		}
	}
	sum.Interrupted = r.signalled
	return sum
}

func (r *Runner) runStack(s stack.Stack, progress string) (Status, error) {
	steps := [][]string{append([]string{r.Command}, r.Args...)}
	switch {
	case r.Command == "init":
		steps[0] = slices.Insert(steps[0], 1, "-input=false")
	case r.Init:
		steps = slices.Insert(steps, 0, []string{"init", "-input=false"})
	}
	for _, args := range steps {
		r.banner(progress, s.Name, args)
		if r.DryRun {
			continue
		}
		code, err := r.exec(s.Dir, args)
		if err == nil {
			continue
		}
		if r.signalled {
			return StatusInterrupted, err
		}
		if code == ExitChanges && r.detailedExitCode() && args[0] == "plan" {
			return StatusChanges, nil
		}
		return StatusFailed, err
	}
	return StatusOK, nil
}

// exec runs one Terraform command and waits for it. It never kills the
// process: an interrupted Terraform must be left to release its state lock.
func (r *Runner) exec(dir string, args []string) (int, error) {
	cmd := exec.Command(r.Bin, args...)
	cmd.Dir = dir
	cmd.Stdin, cmd.Stdout, cmd.Stderr = r.Stdin, r.Stdout, r.Stderr
	cmd.Env = append(os.Environ(), r.Env...)
	isolate(cmd, !r.Interactive)
	if err := cmd.Start(); err != nil {
		return -1, err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	for {
		select {
		case sig := <-r.Signals:
			if !r.signalled {
				r.signalled = true
				fmt.Fprintf(r.Log, "\ntfstack: %v received, letting %s finish; no further stacks will start\n", sig, r.Bin)
			}
			relay(cmd.Process, sig, !r.Interactive)
		case err := <-done:
			if err == nil {
				return 0, nil
			}
			var exit *exec.ExitError
			if errors.As(err, &exit) {
				return exit.ExitCode(), fmt.Errorf("%s %s: %w", r.Bin, args[0], err)
			}
			return -1, err
		}
	}
}

// pendingSignal reports whether a signal arrived, including between stacks.
func (r *Runner) pendingSignal() bool {
	select {
	case <-r.Signals:
		r.signalled = true
	default:
	}
	return r.signalled
}

func (r *Runner) detailedExitCode() bool {
	return slices.ContainsFunc(r.Args, func(a string) bool {
		a = strings.TrimLeft(a, "-")
		return a == "detailed-exitcode" || a == "detailed-exitcode=true"
	})
}

func (r *Runner) banner(progress, name string, args []string) {
	line := fmt.Sprintf("==> %s %s: %s %s", progress, name, r.Bin, strings.Join(args, " "))
	if r.Color {
		line = "\x1b[1;36m" + line + "\x1b[0m"
	}
	fmt.Fprintln(r.Log, line)
}

// ExitCode maps the run to the process exit code.
func (s Summary) ExitCode() int {
	code := ExitOK
	for _, r := range s.Results {
		switch r.Status {
		case StatusFailed:
			return ExitFailed
		case StatusChanges:
			code = ExitChanges
		}
	}
	if s.Interrupted {
		return ExitInterrupted
	}
	return code
}

// Write prints the per-stack table and a one-line total.
func (s Summary) Write(w io.Writer) {
	fmt.Fprintln(w)
	tw := tabwriter.NewWriter(w, 0, 0, 3, ' ', 0)
	fmt.Fprintln(tw, "STACK\tSTATUS\tDURATION")
	counts := map[Status]int{}
	for _, r := range s.Results {
		counts[r.Status]++
		dur := "-"
		if r.Status != StatusSkipped {
			dur = r.Duration.Round(100 * time.Millisecond).String()
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\n", r.Stack, r.Status, dur)
	}
	_ = tw.Flush()
	var parts []string
	for _, st := range []Status{StatusOK, StatusChanges, StatusFailed, StatusInterrupted, StatusSkipped} {
		if counts[st] > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", counts[st], st))
		}
	}
	fmt.Fprintf(w, "\n%d stacks: %s\n", len(s.Results), strings.Join(parts, ", "))
}
