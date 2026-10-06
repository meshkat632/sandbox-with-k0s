// Command tfstack runs Terraform across a folder of stacks, one stack at a time.
package main

import (
	"os"

	"github.com/meshkat632/sandbox-with-k0s/tfstack/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}
