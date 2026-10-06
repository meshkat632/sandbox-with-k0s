// Package version holds build metadata, set at link time with -ldflags -X.
package version

import (
	"fmt"
	"runtime"
	"runtime/debug"
)

// Build metadata; the defaults describe an unreleased build.
var (
	Version = "dev"
	Commit  = ""
	Date    = ""
)

// String returns a one-line description of the build.
func String() string {
	v := Version
	if v == "dev" {
		// Builds made with "go install module@version" carry the version here.
		if info, ok := debug.ReadBuildInfo(); ok && info.Main.Version != "" && info.Main.Version != "(devel)" {
			v = info.Main.Version
		}
	}
	s := "tfstack " + v
	if Commit != "" {
		s += " (" + Commit
		if Date != "" {
			s += ", " + Date
		}
		s += ")"
	}
	return fmt.Sprintf("%s %s %s/%s", s, runtime.Version(), runtime.GOOS, runtime.GOARCH)
}
