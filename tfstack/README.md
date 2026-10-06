# tfstack

Run Terraform across a folder of stacks, one stack at a time, in dependency
order. A single static binary with no dependencies beyond the Go standard
library.

```
stacks/
  01-network/   main.tf
  02-iam/       main.tf
  03-database/  main.tf  depends_on.txt   # "01-network"
  04-app/       main.tf  depends_on.txt   # "03-database, 02-iam"
  _modules/     ...                       # skipped
```

```sh
tfstack list
tfstack plan
tfstack apply -auto-approve
tfstack -only 01-network,02-iam plan
tfstack -from 03-database apply                      # resume after a failure
tfstack -bin tofu destroy -- -var-file=../../prod.tfvars
```

## Install

```sh
make build          # bin/tfstack
make install        # into $GOBIN
go install github.com/meshkat632/sandbox-with-k0s/tfstack/cmd/tfstack@latest
```

Needs Go 1.24 or newer to build, and `terraform` (or `tofu`) on `PATH` to run.

## How it works

- **Stacks.** A stack is a direct subfolder of the stacks folder that contains
  `*.tf`, `*.tf.json`, `*.tofu` or `*.tofu.json` files. Folders starting with
  `_` or `.` are skipped.
- **Order.** Stacks run in name order, so numeric prefixes are usually enough.
  A stack that needs others first lists them in `depends_on.txt`, separated by
  newlines, spaces or commas; `#` starts a comment. Unknown names and cycles
  are reported before anything runs.
- **Destroy** runs in reverse order.
- **Init.** `validate`, `plan`, `apply`, `destroy`, `output` and `refresh` run
  `terraform init -input=false` in each stack first. `-no-init` skips that.
  To pass arguments to init, set `TF_CLI_ARGS_init`.
- **Failure.** The run stops at the first stack that fails, marks the rest as
  skipped, prints a summary table and exits non-zero. `-continue-on-error`
  keeps going. `-from <stack>` resumes from a stack; with `destroy` it counts
  from the reversed order.
- **Ctrl-C.** Terraform is left to finish cleanly and release its state lock,
  and no further stacks start. Terraform is never killed. In CI, where
  there is no terminal, SIGINT and SIGTERM are relayed to Terraform as an
  interrupt.

Progress lines and the summary go to stderr; Terraform's own output is passed
through untouched, so `tfstack -only 04-app output -json | jq` works.

## Usage

```
tfstack [flags] <command> [terraform args]
```

Commands: `list`, `init`, `validate`, `plan`, `apply`, `destroy`, `output`,
`refresh`, `fmt`, `version`.

Flags come **before** the command. Everything after the command goes to
Terraform unchanged; a leading `--` is optional.

| Flag | Default | Meaning |
| --- | --- | --- |
| `-dir path` | `stacks`, or `$TFSTACK_DIR` | Folder holding the stacks |
| `-bin name` | `terraform`, or `$TFSTACK_BIN` | Terraform binary, e.g. `tofu` |
| `-only a,b` | all | Run only these stacks |
| `-from stack` | first | Start at this stack |
| `-continue-on-error` | off | Keep going after a stack fails |
| `-no-init` | off | Do not run `terraform init` first |
| `-dry-run` | off | Print the Terraform commands without running them |
| `-no-color` | off | Plain progress lines; `NO_COLOR` does the same |
| `-version` | | Print the version |

| Exit code | Meaning |
| --- | --- |
| 0 | Every stack succeeded |
| 1 | A stack failed |
| 2 | `plan -detailed-exitcode` found changes in at least one stack, and none failed |
| 64 | Bad command line, or an invalid stacks folder (unknown stack, cycle) |
| 130 | Interrupted |

## Things to know

- **One state per stack.** Give every stack its own backend location, for
  example a separate S3 key, or the states overwrite each other.
- **Sharing values.** A stack reads another's outputs with
  `terraform_remote_state`; see `examples/stacks/03-database`. That needs the
  other stack applied first, so `plan` on a fresh set of stacks fails at the
  first stack that reads state which does not exist yet.
- **Relative paths** in passed-through arguments resolve inside each stack
  folder: use `../../prod.tfvars` or an absolute path.
- **`-only` does not add dependencies.** It runs exactly the stacks named.
- **Approval prompts.** Without `-auto-approve`, `apply` and `destroy` prompt
  once per stack.

## Try it

The example stacks use only the built-in `terraform_data` resource and local
state, so they touch nothing outside their folders:

```sh
make build
bin/tfstack -dir examples/stacks list
bin/tfstack -dir examples/stacks apply -auto-approve
bin/tfstack -dir examples/stacks destroy -auto-approve
```

## Development

```sh
make check    # gofmt, go vet, tests with the race detector
make lint     # golangci-lint v2
make cover
make dist     # release archives and checksums in dist/
```

```
cmd/tfstack        entry point
internal/cli       flags, commands, wiring
internal/stack     discovery, dependency ordering, selection
internal/runner    running Terraform, signals, summary
internal/version   build metadata set by -ldflags
examples/stacks    runnable sample
```

The runner tests use the test binary itself as a stand-in for Terraform, so
they need nothing installed.

CI (`.github/workflows/tfstack.yml`) tests on Linux, macOS and Windows, lints,
and applies and destroys the example stacks with real Terraform. Pushing a tag
`tfstack/vX.Y.Z` also publishes the `make dist` archives as a GitHub release.
