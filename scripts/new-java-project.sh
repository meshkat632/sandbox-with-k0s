#!/usr/bin/env bash
# Create a new Java project from a template with its own groupId/artifactId.
#
#   mkjava <groupId> <artifactId> [target-dir]
#
#   mkjava io.acme billing              # -> ./billing
#   mkjava io.acme billing ~/code/bill  # -> ~/code/bill
#
# The groupId also becomes the Java package (com.example -> io.acme).
#
# The template defaults to java-template; set TEMPLATE_DIR to use another one
# (see new-flink-job.sh).
#
# Install as a command:  ln -s "$(realpath scripts/new-java-project.sh)" ~/.local/bin/mkjava
set -euo pipefail

# resolve symlinks so the template is found when installed on PATH
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
TEMPLATE_DIR="$(cd "${TEMPLATE_DIR:-$SCRIPT_DIR/../java-template}" && pwd)"
TEMPLATE_GROUP="com.example"
TEMPLATE_ARTIFACT="$(basename "$TEMPLATE_DIR")"
CMD_NAME="${CMD_NAME:-mkjava}"

die() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '2,9p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e "s/mkjava/$CMD_NAME/"
    exit "${1:-0}"
}

case "${1:-}" in -h|--help) usage ;; esac
[[ $# -ge 2 && $# -le 3 ]] || usage 1

GROUP_ID="$1"
ARTIFACT_ID="$2"
TARGET_DIR="${3:-$PWD/$ARTIFACT_ID}"

# groupId doubles as the package name, so it has to be a valid Java package
[[ "$GROUP_ID" =~ ^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)*$ ]] \
    || die "groupId '$GROUP_ID' is not a valid Java package (lowercase, dot-separated, e.g. io.acme)"
[[ "$ARTIFACT_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "artifactId '$ARTIFACT_ID' may only contain letters, digits, '.', '_' and '-'"
[[ ! -e "$TARGET_DIR" ]] || die "target '$TARGET_DIR' already exists"

mkdir -p "$TARGET_DIR"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

# copy the template, minus build output and IDE state
tar -C "$TEMPLATE_DIR" \
    --exclude=./target --exclude=./.idea --exclude=./.git --exclude='*.iml' \
    -cf - . | tar -C "$TARGET_DIR" -xf -

# move the sources to the new package
OLD_PATH="${TEMPLATE_GROUP//.//}"
NEW_PATH="${GROUP_ID//.//}"
if [[ "$OLD_PATH" != "$NEW_PATH" ]]; then
    for root in "$TARGET_DIR"/src/*/java; do
        [[ -d "$root/$OLD_PATH" ]] || continue
        mv "$root/$OLD_PATH" "$root/.pkg-tmp"
        # drop the now-empty parents of the old package (e.g. com/)
        find "$root" -mindepth 1 -type d -empty -not -name .pkg-tmp -delete
        mkdir -p "$(dirname "$root/$NEW_PATH")"
        mv "$root/.pkg-tmp" "$root/$NEW_PATH"
    done
fi

# rewrite groupId / package / artifactId everywhere
grep -rIlZ -e "$TEMPLATE_GROUP" -e "$OLD_PATH" -e "$TEMPLATE_ARTIFACT" "$TARGET_DIR" \
    | xargs -0 -r sed -i \
        -e "s|${TEMPLATE_GROUP//./\\.}|$GROUP_ID|g" \
        -e "s|$OLD_PATH|$NEW_PATH|g" \
        -e "s|$TEMPLATE_ARTIFACT|$ARTIFACT_ID|g"

# the "Adopting the template" steps are done; drop them from the new README
if [[ -f "$TARGET_DIR/README.md" ]]; then
    awk '/^## /{skip = ($0 == "## Adopting the template")} !skip' "$TARGET_DIR/README.md" \
        > "$TARGET_DIR/README.md.tmp"
    mv "$TARGET_DIR/README.md.tmp" "$TARGET_DIR/README.md"
fi

echo "Created $GROUP_ID:$ARTIFACT_ID in $TARGET_DIR"
echo "Next: cd $TARGET_DIR && make test"
