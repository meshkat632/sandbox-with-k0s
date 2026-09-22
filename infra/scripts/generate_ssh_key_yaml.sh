#!/usr/bin/env bash
#
# generate_ssh_key_yaml.sh
#
# Generates a new ed25519 SSH keypair (comment = your email) and
# writes the private + public key into a single YAML file, so you
# can then encrypt that file (e.g. with sops, age, gpg, or
# ansible-vault) instead of leaving the raw private key sitting on
# disk unencrypted.
#
# Usage:
#   ./generate_ssh_key_yaml.sh <email>
#
# Example:
#   ./generate_ssh_key_yaml.sh jane@example.com
#
# The output YAML file is named after the email's local part,
# e.g. jane@example.com -> jane.yaml
#
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "Usage: $0 <email>" >&2
  exit 1
fi

EMAIL="$1"

if [[ ! "${EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
  echo "Error: '${EMAIL}' doesn't look like a valid email address." >&2
  exit 1
fi

KEY_TYPE="ed25519"
KEY_NAME="${EMAIL%%@*}"
OUTPUT_YAML="${KEY_NAME}.yaml"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PRIVATE_KEY_PATH="${WORKDIR}/${KEY_NAME}"
PUBLIC_KEY_PATH="${PRIVATE_KEY_PATH}.pub"

echo "Generating ${KEY_TYPE} SSH keypair for '${EMAIL}'..."

# -N "" => no passphrase on the raw key file itself, since the
# YAML file as a whole is what you'll encrypt afterwards.
ssh-keygen -t "${KEY_TYPE}" -f "${PRIVATE_KEY_PATH}" -C "${EMAIL}" -N "" -q

PRIVATE_KEY_CONTENT="$(cat "${PRIVATE_KEY_PATH}")"
PUBLIC_KEY_CONTENT="$(cat "${PUBLIC_KEY_PATH}")"

{
  echo "ssh_key:"
  echo "  email: \"${EMAIL}\""
  echo "  type: \"${KEY_TYPE}\""
  echo "  created: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  echo "  public_key: |"
  sed 's/^/    /' <<< "${PUBLIC_KEY_CONTENT}"
  echo "  private_key: |"
  sed 's/^/    /' <<< "${PRIVATE_KEY_CONTENT}"
} > "${OUTPUT_YAML}"

chmod 600 "${OUTPUT_YAML}"

echo "Done."
echo "Keys written to: ${OUTPUT_YAML}"
echo
echo "Next step - encrypt it, e.g. with one of:"
echo "  gpg -c ${OUTPUT_YAML}                          # symmetric, passphrase-based"
echo "  age -p -o ${OUTPUT_YAML}.age ${OUTPUT_YAML}    # age, passphrase-based"
echo "  sops -e -i ${OUTPUT_YAML}                      # sops (needs a KMS/PGP/age key configured)"
echo "  ansible-vault encrypt ${OUTPUT_YAML}           # if you use Ansible"
echo
echo "Then remove the plaintext copy once encrypted, e.g.: shred -u ${OUTPUT_YAML}"