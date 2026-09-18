#!/usr/bin/env bash
#
# secret-util.sh
#
# Simple wrapper around sops for bulk operations on secret files.
#
# Usage:
#   secret-util.sh list        [start_dir]
#   secret-util.sh decrypt-all [start_dir]
#   secret-util.sh encrypt-all [start_dir]
#   secret-util.sh check       [start_dir]
#   secret-util.sh encrypt     <file>
#   secret-util.sh decrypt     <file>
#
# File matching: any file ending in secrets.yaml, found recursively
# under start_dir (default: current directory).
# Adjust NAME_PATTERNS below if your naming convention differs.

set -euo pipefail

NAME_PATTERNS=("*secrets.yaml")

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [start_dir]

Commands:
  list          List all matching secret files (no encryption check)     [start_dir]
  decrypt-all   Decrypt all matching secret files in place (plaintext!)  [start_dir]
  encrypt-all   Encrypt all matching plaintext files in place            [start_dir]
  check         Report which matching files are encrypted vs plaintext  [start_dir]
  encrypt       Encrypt a single file in place                           <file>
  decrypt       Decrypt a single file in place (plaintext on disk!)      <file>

start_dir defaults to the current directory.
EOF
}

find_files() {
  local dir="$1"
  local find_args=()
  local first=true
  for pat in "${NAME_PATTERNS[@]}"; do
    if [ "$first" = true ]; then
      find_args+=(-name "$pat")
      first=false
    else
      find_args+=(-o -name "$pat")
    fi
  done
  find "$dir" -type f \( "${find_args[@]}" \)
}

is_encrypted() {
  # sops-encrypted files carry a top-level "sops:" metadata block.
  grep -q '^sops:' "$1" 2>/dev/null
}

cmd_list() {
  local dir="${1:-.}"
  local any=false

  while IFS= read -r f; do
    any=true
    echo "$f"
  done < <(find_files "$dir")

  if [ "$any" = false ]; then
    echo "No matching secret files found under '$dir'." >&2
    exit 1
  fi
}

cmd_check() {
  local dir="${1:-.}"
  local any=false
  local unencrypted=()

  while IFS= read -r f; do
    any=true
    if is_encrypted "$f"; then
      echo "  [encrypted]   $f"
    else
      echo "  [PLAINTEXT]   $f"
      unencrypted+=("$f")
    fi
  done < <(find_files "$dir")

  if [ "$any" = false ]; then
    echo "No matching secret files found under '$dir'."
    exit 0
  fi

  echo
  if [ "${#unencrypted[@]}" -eq 0 ]; then
    echo "OK: all matching files are encrypted."
    exit 0
  else
    echo "WARNING: ${#unencrypted[@]} file(s) are NOT encrypted:"
    printf '  %s\n' "${unencrypted[@]}"
    exit 2
  fi
}

cmd_decrypt_all() {
  local dir="${1:-.}"
  local failed=()

  while IFS= read -r f; do
    if ! is_encrypted "$f"; then
      echo "-> $f (already plaintext, skipping)"
      continue
    fi
    echo "-> $f"
    if sops -d -i "$f"; then
      echo "   decrypted"
    else
      echo "   FAILED"
      failed+=("$f")
    fi
  done < <(find_files "$dir")

  if [ "${#failed[@]}" -gt 0 ]; then
    echo
    echo "Failed on ${#failed[@]} file(s):"
    printf '  %s\n' "${failed[@]}"
    exit 1
  fi
}

cmd_encrypt_all() {
  local dir="${1:-.}"
  local failed=()

  while IFS= read -r f; do
    if is_encrypted "$f"; then
      echo "-> $f (already encrypted, skipping)"
      continue
    fi
    echo "-> $f"
    if sops -e -i "$f"; then
      echo "   encrypted"
    else
      echo "   FAILED"
      failed+=("$f")
    fi
  done < <(find_files "$dir")

  if [ "${#failed[@]}" -gt 0 ]; then
    echo
    echo "Failed on ${#failed[@]} file(s):"
    printf '  %s\n' "${failed[@]}"
    exit 1
  fi
}

cmd_encrypt_one() {
  local f="$1"

  if [ ! -f "$f" ]; then
    echo "Error: file not found: $f" >&2
    exit 1
  fi

  if is_encrypted "$f"; then
    echo "-> $f (already encrypted, skipping)"
    return 0
  fi

  echo "-> $f"
  if sops -e -i "$f"; then
    echo "   encrypted"
  else
    echo "   FAILED"
    exit 1
  fi
}

cmd_decrypt_one() {
  local f="$1"

  if [ ! -f "$f" ]; then
    echo "Error: file not found: $f" >&2
    exit 1
  fi

  if ! is_encrypted "$f"; then
    echo "-> $f (already plaintext, skipping)"
    return 0
  fi

  echo "-> $f"
  if sops -d -i "$f"; then
    echo "   decrypted"
  else
    echo "   FAILED"
    exit 1
  fi
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

if ! command -v sops >/dev/null 2>&1; then
  echo "Error: sops is not installed or not on PATH" >&2
  exit 1
fi

COMMAND="$1"
shift || true

case "$COMMAND" in
  list)        cmd_list "${1:-.}" ;;
  decrypt-all) cmd_decrypt_all "${1:-.}" ;;
  encrypt-all) cmd_encrypt_all "${1:-.}" ;;
  check)       cmd_check "${1:-.}" ;;
  encrypt)
    if [ $# -lt 1 ]; then
      echo "Error: encrypt requires a file path" >&2
      usage
      exit 1
    fi
    cmd_encrypt_one "$1"
    ;;
  decrypt)
    if [ $# -lt 1 ]; then
      echo "Error: decrypt requires a file path" >&2
      usage
      exit 1
    fi
    cmd_decrypt_one "$1"
    ;;
  -h|--help)   usage ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage
    exit 1
    ;;
esac