package stack

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// tree creates files under a temp dir; keys are slash-separated paths.
func tree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, content := range files {
		p := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func names(stacks []Stack) []string {
	out := make([]string, len(stacks))
	for i, s := range stacks {
		out[i] = s.Name
	}
	return out
}

func TestDiscover(t *testing.T) {
	root := tree(t, map[string]string{
		"02-iam/main.tf":             "",
		"01-network/main.tf.json":    "{}",
		"03-db/main.tf":              "",
		"03-db/depends_on.txt":       "# needs the VPC\n01-network, ./02-iam/\n\n01-network # again\n",
		"_modules/vpc/main.tf":       "",
		"_modules/main.tf":           "",
		".hidden/main.tf":            "",
		"docs/README.md":             "",
		"nested/child/main.tf":       "",
		"05-tofu/main.tofu":          "",
		"notes.tf":                   "",
		"04-empty/depends_on.txt":    "01-network",
		"04-empty/sub/placeholder":   "",
		"06-app/main.tf":             "",
		"06-app/terraform.tfvars":    "",
		"06-app/.terraform/x/y.tf":   "",
		"06-app/modules/web/main.tf": "",
	})
	got, err := Discover(root)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"01-network", "02-iam", "03-db", "05-tofu", "06-app"}
	if !slices.Equal(names(got), want) {
		t.Fatalf("stacks = %v, want %v", names(got), want)
	}
	if deps := got[2].DependsOn; !slices.Equal(deps, []string{"01-network", "02-iam"}) {
		t.Errorf("03-db deps = %v", deps)
	}
	if !filepath.IsAbs(got[0].Dir) {
		t.Errorf("Dir %q is not absolute", got[0].Dir)
	}
}

func TestDiscoverErrors(t *testing.T) {
	if _, err := Discover(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Error("missing folder: want error")
	}
	root := tree(t, map[string]string{"a/main.tf": "", "a/depends_on.txt": "a"})
	if _, err := Discover(root); err == nil || !strings.Contains(err.Error(), "itself") {
		t.Errorf("self dependency: got %v", err)
	}
}

func TestOrder(t *testing.T) {
	tests := []struct {
		name    string
		deps    map[string][]string
		want    []string
		wantErr string
	}{
		{name: "name order without deps", deps: map[string][]string{"b": nil, "a": nil, "c": nil}, want: []string{"a", "b", "c"}},
		{name: "dependency pulls a later name forward", deps: map[string][]string{"a": {"z"}, "b": nil, "z": nil}, want: []string{"b", "z", "a"}},
		{name: "diamond", deps: map[string][]string{"app": {"db", "iam"}, "db": {"net"}, "iam": {"net"}, "net": nil}, want: []string{"net", "db", "iam", "app"}},
		{name: "unknown", deps: map[string][]string{"a": {"nope"}}, wantErr: `a depends on unknown stack "nope"`},
		{name: "cycle", deps: map[string][]string{"a": {"b"}, "b": {"c"}, "c": {"a"}, "d": nil}, wantErr: "dependency cycle: a -> b -> c -> a"},
		{name: "cycle behind a blocked stack", deps: map[string][]string{"a": {"b"}, "b": {"c"}, "c": {"b"}}, wantErr: "dependency cycle: b -> c -> b"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var in []Stack
			for n, d := range tt.deps {
				in = append(in, Stack{Name: n, DependsOn: d})
			}
			got, err := Order(in)
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("err = %v, want %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(names(got), tt.want) {
				t.Errorf("order = %v, want %v", names(got), tt.want)
			}
		})
	}
}

func TestSelect(t *testing.T) {
	ordered := []Stack{{Name: "a"}, {Name: "b"}, {Name: "c"}, {Name: "d"}}
	tests := []struct {
		name    string
		in      []Stack
		only    []string
		from    string
		want    []string
		wantErr string
	}{
		{name: "all", in: ordered, want: []string{"a", "b", "c", "d"}},
		{name: "only keeps run order", in: ordered, only: []string{"c", "a"}, want: []string{"a", "c"}},
		{name: "from", in: ordered, from: "c", want: []string{"c", "d"}},
		{name: "from on reversed list", in: Reverse(ordered), from: "c", want: []string{"c", "b", "a"}},
		{name: "only and from", in: ordered, only: []string{"a", "b", "d"}, from: "b", want: []string{"b", "d"}},
		{name: "unknown only", in: ordered, only: []string{"x"}, wantErr: "-only"},
		{name: "unknown from", in: ordered, from: "x", wantErr: "-from"},
		{name: "from excluded", in: ordered, only: []string{"a"}, from: "b", wantErr: "excluded by -only"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Select(tt.in, tt.only, tt.from)
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("err = %v, want %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(names(got), tt.want) {
				t.Errorf("got %v, want %v", names(got), tt.want)
			}
		})
	}
}
