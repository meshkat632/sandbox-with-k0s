package runner

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/meshkat632/sandbox-with-k0s/tfstack/internal/stack"
)

// The test binary doubles as a fake terraform when FAKE_TF_LOG is set. It
// appends "<stack> <args>" to that file and takes its behaviour from
// FAKE_TF_EXIT ("<stack>:<subcommand>:<code>") and FAKE_TF_WAIT (a stack whose
// plan blocks until interrupted).
func TestMain(m *testing.M) {
	if log := os.Getenv("FAKE_TF_LOG"); log != "" {
		os.Exit(fakeTerraform(log))
	}
	os.Exit(m.Run())
}

func fakeTerraform(log string) int {
	wd, _ := os.Getwd()
	name := filepath.Base(wd)
	args := os.Args[1:]
	record := func(line string) {
		f, err := os.OpenFile(log, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			panic(err)
		}
		defer f.Close()
		fmt.Fprintln(f, line)
	}
	if os.Getenv("FAKE_TF_WAIT") == name && args[0] == "plan" {
		c := make(chan os.Signal, 1)
		signal.Notify(c, os.Interrupt)
		record(name + " waiting")
		select {
		case <-c:
			record(name + " interrupted")
			return 1
		case <-time.After(30 * time.Second):
			return 3
		}
	}
	record(name + " " + strings.Join(args, " "))
	var stackName, sub string
	var code int
	if spec := strings.ReplaceAll(os.Getenv("FAKE_TF_EXIT"), ":", " "); spec != "" {
		if _, err := fmt.Sscan(spec, &stackName, &sub, &code); err != nil {
			panic(err)
		}
		if stackName == name && sub == args[0] {
			return code
		}
	}
	return 0
}

type fixture struct {
	stacks []stack.Stack
	log    string
	runner *Runner
}

func newFixture(t *testing.T, command string, env ...string) *fixture {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	f := &fixture{log: filepath.Join(root, "calls.log")}
	for _, n := range []string{"a", "b", "c"} {
		dir := filepath.Join(root, n)
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		f.stacks = append(f.stacks, stack.Stack{Name: n, Dir: dir})
	}
	f.runner = &Runner{
		Bin: self, Command: command, Init: true,
		Env:    append([]string{"FAKE_TF_LOG=" + f.log}, env...),
		Stdout: io.Discard, Stderr: io.Discard, Log: io.Discard,
	}
	return f
}

func (f *fixture) calls(t *testing.T) []string {
	t.Helper()
	data, err := os.ReadFile(f.log)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

func statuses(s Summary) []Status {
	out := make([]Status, len(s.Results))
	for i, r := range s.Results {
		out[i] = r.Status
	}
	return out
}

func check(t *testing.T, f *fixture, sum Summary, wantStatus []Status, wantExit int, wantCalls []string) {
	t.Helper()
	if got := statuses(sum); !slices.Equal(got, wantStatus) {
		t.Errorf("statuses = %v, want %v", got, wantStatus)
	}
	if got := sum.ExitCode(); got != wantExit {
		t.Errorf("exit code = %d, want %d", got, wantExit)
	}
	if got := f.calls(t); !slices.Equal(got, wantCalls) {
		t.Errorf("calls =\n  %s\nwant\n  %s", strings.Join(got, "\n  "), strings.Join(wantCalls, "\n  "))
	}
}

func TestRunInitsThenRunsEachStack(t *testing.T) {
	f := newFixture(t, "apply")
	f.runner.Args = []string{"-auto-approve"}
	sum := f.runner.Run(f.stacks)
	check(t, f, sum, []Status{StatusOK, StatusOK, StatusOK}, ExitOK, []string{
		"a init -input=false", "a apply -auto-approve",
		"b init -input=false", "b apply -auto-approve",
		"c init -input=false", "c apply -auto-approve",
	})
}

func TestRunInitCommandAndNoInit(t *testing.T) {
	f := newFixture(t, "init")
	f.runner.Args = []string{"-upgrade"}
	check(t, f, f.runner.Run(f.stacks[:1]), []Status{StatusOK}, ExitOK, []string{"a init -input=false -upgrade"})

	f = newFixture(t, "fmt")
	f.runner.Init = false
	check(t, f, f.runner.Run(f.stacks[:1]), []Status{StatusOK}, ExitOK, []string{"a fmt"})
}

func TestRunStopsAtFirstFailure(t *testing.T) {
	f := newFixture(t, "plan", "FAKE_TF_EXIT=b:plan:1")
	sum := f.runner.Run(f.stacks)
	check(t, f, sum, []Status{StatusOK, StatusFailed, StatusSkipped}, ExitFailed, []string{
		"a init -input=false", "a plan", "b init -input=false", "b plan",
	})
	if sum.Results[1].Err == nil {
		t.Error("failed stack has no error")
	}
}

func TestRunInitFailureSkipsCommand(t *testing.T) {
	f := newFixture(t, "plan", "FAKE_TF_EXIT=a:init:1")
	check(t, f, f.runner.Run(f.stacks[:1]), []Status{StatusFailed}, ExitFailed, []string{"a init -input=false"})
}

func TestRunContinueOnError(t *testing.T) {
	f := newFixture(t, "plan", "FAKE_TF_EXIT=b:plan:1")
	f.runner.ContinueOnError = true
	check(t, f, f.runner.Run(f.stacks), []Status{StatusOK, StatusFailed, StatusOK}, ExitFailed, []string{
		"a init -input=false", "a plan", "b init -input=false", "b plan", "c init -input=false", "c plan",
	})
}

func TestRunDetailedExitCode(t *testing.T) {
	f := newFixture(t, "plan", "FAKE_TF_EXIT=b:plan:2")
	f.runner.Args = []string{"-detailed-exitcode"}
	f.runner.Init = false
	check(t, f, f.runner.Run(f.stacks), []Status{StatusOK, StatusChanges, StatusOK}, ExitChanges, []string{
		"a plan -detailed-exitcode", "b plan -detailed-exitcode", "c plan -detailed-exitcode",
	})

	// Without the flag, exit code 2 is an ordinary failure.
	f = newFixture(t, "plan", "FAKE_TF_EXIT=a:plan:2")
	f.runner.Init = false
	check(t, f, f.runner.Run(f.stacks[:1]), []Status{StatusFailed}, ExitFailed, []string{"a plan"})
}

func TestRunDryRun(t *testing.T) {
	f := newFixture(t, "destroy")
	var log bytes.Buffer
	f.runner.DryRun, f.runner.Log = true, &log
	check(t, f, f.runner.Run(f.stacks[:2]), []Status{StatusOK, StatusOK}, ExitOK, nil)
	for _, want := range []string{"[1/2] a:", "init -input=false", "[2/2] b:", " destroy"} {
		if !strings.Contains(log.String(), want) {
			t.Errorf("dry-run output lacks %q:\n%s", want, log.String())
		}
	}
}

func TestRunMissingBinary(t *testing.T) {
	f := newFixture(t, "plan")
	f.runner.Bin = filepath.Join(t.TempDir(), "no-such-terraform")
	check(t, f, f.runner.Run(f.stacks), []Status{StatusFailed, StatusSkipped, StatusSkipped}, ExitFailed, nil)
}

func TestRunSignalBetweenStacks(t *testing.T) {
	f := newFixture(t, "plan")
	sigs := make(chan os.Signal, 1)
	sigs <- os.Interrupt
	f.runner.Signals = sigs
	check(t, f, f.runner.Run(f.stacks), []Status{StatusSkipped, StatusSkipped, StatusSkipped}, ExitInterrupted, nil)
}

func TestRunRelaysInterruptAndStops(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("interrupts cannot be relayed on Windows")
	}
	f := newFixture(t, "plan", "FAKE_TF_WAIT=b")
	f.runner.Init = false
	sigs := make(chan os.Signal, 1)
	f.runner.Signals = sigs
	go func() {
		// Interrupt once terraform is running in stack b.
		for !slices.Contains(f.calls(t), "b waiting") {
			time.Sleep(10 * time.Millisecond)
		}
		sigs <- os.Interrupt
	}()
	sum := f.runner.Run(f.stacks)
	check(t, f, sum, []Status{StatusOK, StatusInterrupted, StatusSkipped}, ExitInterrupted, []string{
		"a plan", "b waiting", "b interrupted",
	})
}

func TestSummaryWrite(t *testing.T) {
	var buf bytes.Buffer
	Summary{Results: []Result{
		{Stack: "01-network", Status: StatusOK, Duration: 1234 * time.Millisecond},
		{Stack: "02-iam", Status: StatusFailed, Duration: time.Second},
		{Stack: "03-db", Status: StatusSkipped},
	}}.Write(&buf)
	for _, want := range []string{"STACK", "01-network   ok", "1.2s", "02-iam       failed", "03-db        skipped   -", "3 stacks: 1 ok, 1 failed, 1 skipped"} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("summary lacks %q:\n%s", want, buf.String())
		}
	}
}
