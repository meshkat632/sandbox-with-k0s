package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func stacksDir(t *testing.T, deps map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, dep := range deps {
		dir := filepath.Join(root, name)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "main.tf"), nil, 0o644); err != nil {
			t.Fatal(err)
		}
		if dep != "" {
			if err := os.WriteFile(filepath.Join(dir, "depends_on.txt"), []byte(dep), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	return root
}

func run(t *testing.T, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	t.Setenv("TFSTACK_DIR", "")
	t.Setenv("TFSTACK_BIN", "")
	var out, errb bytes.Buffer
	code = Run(args, nil, &out, &errb)
	return code, out.String(), errb.String()
}

func TestList(t *testing.T) {
	dir := stacksDir(t, map[string]string{"01-network": "", "02-iam": "", "03-db": "01-network", "04-app": "03-db 02-iam"})
	code, out, _ := run(t, "-dir", dir, "list")
	want := "01-network\n02-iam\n03-db        depends on 01-network\n04-app       depends on 03-db, 02-iam\n"
	if code != 0 || out != want {
		t.Errorf("code %d, output:\n%s\nwant:\n%s", code, out, want)
	}
	code, out, _ = run(t, "-dir", dir, "-only", "04-app, 01-network", "-from", "04-app", "list")
	if code != 0 || !strings.HasPrefix(out, "04-app") || strings.Contains(out, "01-network\n") {
		t.Errorf("code %d, filtered output:\n%s", code, out)
	}
}

func TestDryRunOrder(t *testing.T) {
	dir := stacksDir(t, map[string]string{"a": "b", "b": "", "c": ""})
	lines := func(stderr string) []string {
		var out []string
		for _, l := range strings.Split(strings.TrimSpace(stderr), "\n") {
			out = append(out, strings.TrimPrefix(l, "==> "))
		}
		return out
	}

	code, _, stderr := run(t, "-dir", dir, "-dry-run", "apply", "-auto-approve")
	want := []string{
		"[1/3] b: terraform init -input=false", "[1/3] b: terraform apply -auto-approve",
		"[2/3] a: terraform init -input=false", "[2/3] a: terraform apply -auto-approve",
		"[3/3] c: terraform init -input=false", "[3/3] c: terraform apply -auto-approve",
	}
	if got := lines(stderr); code != 0 || strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("apply: code %d, got\n%s", code, stderr)
	}

	// destroy reverses the order; -from then counts from the reversed list.
	code, _, stderr = run(t, "-dir", dir, "-dry-run", "-no-init", "-from", "a", "destroy", "--", "-var-file=x.tfvars")
	want = []string{"[1/2] a: terraform destroy -var-file=x.tfvars", "[2/2] b: terraform destroy -var-file=x.tfvars"}
	if got := lines(stderr); code != 0 || strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("destroy: code %d, got\n%s", code, stderr)
	}

	code, _, stderr = run(t, "-dir", dir, "-bin", "tofu", "-dry-run", "-only", "c", "fmt", "-check")
	if code != 0 || strings.TrimSpace(stderr) != "==> [1/1] c: tofu fmt -check" {
		t.Errorf("fmt: code %d, got\n%s", code, stderr)
	}
}

func TestUsageErrors(t *testing.T) {
	dir := stacksDir(t, map[string]string{"a": "", "b": ""})
	cyclic := stacksDir(t, map[string]string{"a": "b", "b": "a"})
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"no command", nil, "Usage:"},
		{"unknown command", []string{"-dir", dir, "aply"}, `unknown command "aply"`},
		{"unknown flag", []string{"-nope", "plan"}, "flag provided but not defined"},
		{"flag after command", []string{"-dir", dir, "plan", "-only", "a"}, "flag -only must come before the command"},
		{"missing folder", []string{"-dir", filepath.Join(dir, "missing"), "plan"}, "read stacks folder"},
		{"no stacks", []string{"-dir", t.TempDir(), "plan"}, "no stacks found"},
		{"unknown -only", []string{"-dir", dir, "-only", "zzz", "plan"}, `unknown stack "zzz"`},
		{"cycle", []string{"-dir", cyclic, "list"}, "dependency cycle: a -> b -> a"},
		{"missing binary", []string{"-dir", dir, "-bin", "no-such-terraform-binary", "plan"}, "no-such-terraform-binary"},
		{"list with args", []string{"-dir", dir, "list", "x"}, "list takes no arguments"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, _, stderr := run(t, tt.args...)
			if code != ExitUsage || !strings.Contains(stderr, tt.want) {
				t.Errorf("code %d, stderr %q, want code %d containing %q", code, stderr, ExitUsage, tt.want)
			}
		})
	}
}

func TestPassthroughAfterDoubleDashIsNotChecked(t *testing.T) {
	dir := stacksDir(t, map[string]string{"a": ""})
	code, _, stderr := run(t, "-dir", dir, "-dry-run", "-no-init", "plan", "--", "-from", "x")
	if code != 0 || !strings.Contains(stderr, "terraform plan -from x") {
		t.Errorf("code %d, stderr %q", code, stderr)
	}
}

func TestVersionAndHelp(t *testing.T) {
	for _, args := range [][]string{{"-version"}, {"version"}} {
		if code, out, _ := run(t, args...); code != 0 || !strings.HasPrefix(out, "tfstack ") {
			t.Errorf("%v: code %d, out %q", args, code, out)
		}
	}
	if code, _, stderr := run(t, "-h"); code != 0 || !strings.Contains(stderr, "Usage:") {
		t.Errorf("-h: code %d, stderr %q", code, stderr)
	}
	if code, out, _ := run(t, "help"); code != 0 || !strings.Contains(out, "Usage:") {
		t.Errorf("help: code %d", code)
	}
}
