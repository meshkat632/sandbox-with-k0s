// Package stack discovers Terraform stacks in a folder and orders them by
// their declared dependencies.
package stack

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"unicode"
)

// DependsFile is the optional per-stack file listing the stacks that must run first.
const DependsFile = "depends_on.txt"

// Stack is one Terraform root module directly under the stacks folder.
type Stack struct {
	Name      string
	Dir       string // absolute path
	DependsOn []string
}

// Discover returns the stacks directly under root, sorted by name. A stack is
// a subfolder holding Terraform files; folders starting with "_" or "." are skipped.
func Discover(root string) ([]Stack, error) {
	root, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, fmt.Errorf("read stacks folder: %w", err)
	}
	var stacks []Stack
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, "_") || strings.HasPrefix(name, ".") {
			continue
		}
		dir := filepath.Join(root, name)
		// Stat rather than e.IsDir so a symlinked stack folder counts.
		if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
			continue
		}
		ok, err := hasTerraformFiles(dir)
		if err != nil {
			return nil, err
		}
		if !ok {
			continue
		}
		deps, err := readDeps(filepath.Join(dir, DependsFile))
		if err != nil {
			return nil, fmt.Errorf("stack %s: %w", name, err)
		}
		if slices.Contains(deps, name) {
			return nil, fmt.Errorf("stack %s: %s lists the stack itself", name, DependsFile)
		}
		stacks = append(stacks, Stack{Name: name, Dir: dir, DependsOn: deps})
	}
	sort.Slice(stacks, func(i, j int) bool { return stacks[i].Name < stacks[j].Name })
	return stacks, nil
}

func hasTerraformFiles(dir string) (bool, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false, err
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		for _, ext := range []string{".tf", ".tf.json", ".tofu", ".tofu.json"} {
			if strings.HasSuffix(e.Name(), ext) {
				return true, nil
			}
		}
	}
	return false, nil
}

// readDeps parses a depends_on.txt: stack names separated by newlines, spaces
// or commas, with "#" starting a comment. A missing file means no dependencies.
func readDeps(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var deps []string
	for _, line := range strings.Split(string(data), "\n") {
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		fields := strings.FieldsFunc(line, func(r rune) bool { return r == ',' || unicode.IsSpace(r) })
		for _, f := range fields {
			f = strings.TrimSuffix(strings.TrimPrefix(f, "./"), "/")
			if f != "" && !slices.Contains(deps, f) {
				deps = append(deps, f)
			}
		}
	}
	return deps, nil
}

// Order sorts stacks so that every stack comes after the stacks it depends
// on. Stacks that are free to run in any order keep their name order.
func Order(stacks []Stack) ([]Stack, error) {
	byName := make(map[string]Stack, len(stacks))
	for _, s := range stacks {
		byName[s.Name] = s
	}
	var unknown []string
	for _, s := range stacks {
		for _, d := range s.DependsOn {
			if _, ok := byName[d]; !ok {
				unknown = append(unknown, fmt.Sprintf("%s depends on unknown stack %q", s.Name, d))
			}
		}
	}
	if len(unknown) > 0 {
		return nil, errors.New(strings.Join(unknown, "; "))
	}

	pending := slices.Clone(stacks)
	sort.Slice(pending, func(i, j int) bool { return pending[i].Name < pending[j].Name })
	done := make(map[string]bool, len(stacks))
	ordered := make([]Stack, 0, len(stacks))
	for len(pending) > 0 {
		next := slices.IndexFunc(pending, func(s Stack) bool {
			return !slices.ContainsFunc(s.DependsOn, func(d string) bool { return !done[d] })
		})
		if next < 0 {
			return nil, fmt.Errorf("dependency cycle: %s", strings.Join(findCycle(pending, done), " -> "))
		}
		done[pending[next].Name] = true
		ordered = append(ordered, pending[next])
		pending = slices.Delete(pending, next, next+1)
	}
	return ordered, nil
}

// findCycle walks unfinished dependencies from the first blocked stack until
// it revisits one, and returns that loop.
func findCycle(pending []Stack, done map[string]bool) []string {
	byName := make(map[string]Stack, len(pending))
	for _, s := range pending {
		byName[s.Name] = s
	}
	var path []string
	cur := pending[0].Name
	for {
		if i := slices.Index(path, cur); i >= 0 {
			return append(path[i:], cur)
		}
		path = append(path, cur)
		for _, d := range byName[cur].DependsOn {
			if !done[d] {
				cur = d
				break
			}
		}
	}
}

// Reverse returns the stacks in the opposite order, as used for destroy.
func Reverse(stacks []Stack) []Stack {
	out := slices.Clone(stacks)
	slices.Reverse(out)
	return out
}

// Select narrows an ordered list: only keeps the named stacks (all when
// empty), and from drops everything before that stack.
func Select(ordered []Stack, only []string, from string) ([]Stack, error) {
	has := func(list []Stack, name string) bool {
		return slices.ContainsFunc(list, func(s Stack) bool { return s.Name == name })
	}
	out := ordered
	if len(only) > 0 {
		for _, name := range only {
			if !has(ordered, name) {
				return nil, fmt.Errorf("unknown stack %q in -only", name)
			}
		}
		out = nil
		for _, s := range ordered {
			if slices.Contains(only, s.Name) {
				out = append(out, s)
			}
		}
	}
	if from != "" {
		i := slices.IndexFunc(out, func(s Stack) bool { return s.Name == from })
		if i < 0 {
			if has(ordered, from) {
				return nil, fmt.Errorf("stack %q given to -from is excluded by -only", from)
			}
			return nil, fmt.Errorf("unknown stack %q in -from", from)
		}
		out = out[i:]
	}
	return out, nil
}
