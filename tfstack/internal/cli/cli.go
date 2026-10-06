// Package cli parses the command line and wires discovery to the runner.
package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"slices"
	"strings"
	"syscall"

	"github.com/meshkat632/sandbox-with-k0s/tfstack/internal/runner"
	"github.com/meshkat632/sandbox-with-k0s/tfstack/internal/stack"
	"github.com/meshkat632/sandbox-with-k0s/tfstack/internal/version"
)

// ExitUsage is returned for a bad command line or an invalid stacks folder.
// It is kept apart from 1 and 2, which describe what Terraform did.
const ExitUsage = 64

const usage = `tfstack runs Terraform across a folder of stacks, one stack at a time.

Usage:
  tfstack [flags] <command> [terraform args]

Commands:
  list       show the stacks in run order, with their dependencies
  init       terraform init -input=false
  validate   terraform validate
  plan       terraform plan
  apply      terraform apply
  destroy    terraform destroy, in reverse order
  output     terraform output
  refresh    terraform refresh
  fmt        terraform fmt (no init)
  version    print the tfstack version

Flags (must come before the command):
  -dir path            folder holding the stacks (default "stacks", env TFSTACK_DIR)
  -bin name            terraform binary, e.g. tofu (default "terraform", env TFSTACK_BIN)
  -only a,b            run only these stacks
  -from stack          start at this stack, skipping the ones ordered before it
  -continue-on-error   keep going after a stack fails
  -no-init             do not run terraform init before the command
  -dry-run             print the terraform commands without running them
  -no-color            plain progress lines (also set by NO_COLOR)
  -version             print the tfstack version

Everything after the command is passed to terraform unchanged; a leading "--"
is optional:
  tfstack apply -auto-approve
  tfstack -bin tofu destroy -- -var-file=../../prod.tfvars

Exit codes: 0 success, 1 a stack failed, 2 changes pending (plan
-detailed-exitcode), 64 usage error, 130 interrupted.
`

// initFirst lists the commands that need an initialised working directory.
var commands = map[string]struct{ initFirst bool }{
	"init":     {false},
	"validate": {true},
	"plan":     {true},
	"apply":    {true},
	"destroy":  {true},
	"output":   {true},
	"refresh":  {true},
	"fmt":      {false},
}

type options struct {
	dir, bin, only, from            string
	continueOnError, noInit, dryRun bool
	noColor, showVersion            bool
}

// Run executes tfstack with the given arguments and returns the exit code.
func Run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	var o options
	fs := flag.NewFlagSet("tfstack", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() { fmt.Fprint(stderr, usage) }
	fs.StringVar(&o.dir, "dir", envOr("TFSTACK_DIR", "stacks"), "")
	fs.StringVar(&o.bin, "bin", envOr("TFSTACK_BIN", "terraform"), "")
	fs.StringVar(&o.only, "only", "", "")
	fs.StringVar(&o.from, "from", "", "")
	fs.BoolVar(&o.continueOnError, "continue-on-error", false, "")
	fs.BoolVar(&o.noInit, "no-init", false, "")
	fs.BoolVar(&o.dryRun, "dry-run", false, "")
	fs.BoolVar(&o.noColor, "no-color", false, "")
	fs.BoolVar(&o.showVersion, "version", false, "")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return runner.ExitOK
		}
		return ExitUsage
	}
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "tfstack: "+format+"\n", a...)
		return ExitUsage
	}

	rest := fs.Args()
	if o.showVersion || (len(rest) > 0 && rest[0] == "version") {
		fmt.Fprintln(stdout, version.String())
		return runner.ExitOK
	}
	if len(rest) == 0 {
		fs.Usage()
		return ExitUsage
	}
	if rest[0] == "help" {
		fmt.Fprint(stdout, usage)
		return runner.ExitOK
	}
	command, tfArgs := rest[0], rest[1:]
	spec, known := commands[command]
	if !known && command != "list" {
		return fail("unknown command %q (run tfstack -h for the list)", command)
	}
	if len(tfArgs) > 0 && tfArgs[0] == "--" {
		tfArgs = tfArgs[1:]
	} else if name := misplacedFlag(fs, tfArgs); name != "" {
		return fail("flag -%s must come before the command: tfstack -%s ... %s", name, name, command)
	}

	stacks, err := stack.Discover(o.dir)
	if err != nil {
		return fail("%v", err)
	}
	if len(stacks) == 0 {
		return fail("no stacks found in %s (a stack is a subfolder with .tf files)", o.dir)
	}
	stacks, err = stack.Order(stacks)
	if err != nil {
		return fail("%v", err)
	}
	if command == "destroy" {
		stacks = stack.Reverse(stacks)
	}
	stacks, err = stack.Select(stacks, splitList(o.only), o.from)
	if err != nil {
		return fail("%v", err)
	}

	if command == "list" {
		if len(tfArgs) > 0 {
			return fail("list takes no arguments")
		}
		width := 0
		for _, s := range stacks {
			width = max(width, len(s.Name))
		}
		for _, s := range stacks {
			if len(s.DependsOn) == 0 {
				fmt.Fprintln(stdout, s.Name)
				continue
			}
			fmt.Fprintf(stdout, "%-*s   depends on %s\n", width, s.Name, strings.Join(s.DependsOn, ", "))
		}
		return runner.ExitOK
	}

	if !o.dryRun {
		if _, err := exec.LookPath(o.bin); err != nil {
			return fail("%v", err)
		}
	}
	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sigs)

	r := &runner.Runner{
		Bin:             o.bin,
		Command:         command,
		Args:            tfArgs,
		Init:            spec.initFirst && !o.noInit,
		ContinueOnError: o.continueOnError,
		DryRun:          o.dryRun,
		Stdin:           stdin,
		Stdout:          stdout,
		Stderr:          stderr,
		Log:             stderr,
		Color:           !o.noColor && os.Getenv("NO_COLOR") == "" && isTerminal(stderr),
		Signals:         sigs,
		Interactive:     isTerminal(stdin),
	}
	sum := r.Run(stacks)
	if !o.dryRun {
		sum.Write(stderr)
	}
	return sum.ExitCode()
}

// misplacedFlag returns the name of a tfstack flag found among the terraform
// arguments, where it would otherwise be handed to terraform and rejected
// with a confusing message. -no-color is exempt: terraform has it too.
func misplacedFlag(fs *flag.FlagSet, tfArgs []string) string {
	for _, a := range tfArgs {
		if a == "--" {
			break
		}
		if !strings.HasPrefix(a, "-") {
			continue
		}
		name, _, _ := strings.Cut(strings.TrimLeft(a, "-"), "=")
		if name != "no-color" && fs.Lookup(name) != nil {
			return name
		}
	}
	return ""
}

func splitList(s string) []string {
	var out []string
	for _, f := range strings.Split(s, ",") {
		if f = strings.TrimSpace(f); f != "" && !slices.Contains(out, f) {
			out = append(out, f)
		}
	}
	return out
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// isTerminal reports whether v is a character device other than the null
// device, which is as close as the standard library gets to "a terminal".
func isTerminal(v any) bool {
	f, ok := v.(*os.File)
	if !ok || f == nil {
		return false
	}
	fi, err := f.Stat()
	if err != nil || fi.Mode()&os.ModeCharDevice == 0 {
		return false
	}
	if null, err := os.Stat(os.DevNull); err == nil && os.SameFile(fi, null) {
		return false
	}
	return true
}
