# k0stool helpers — gitops secrets via sops + age
#
# make tools    -> install sops + age (uses sudo)
# make age-key  -> generate YOUR age key (~/.config/sops/age/keys.txt), prints the public key
# make secret   -> bootstrap secrets/ssh-keypair.enc.yaml, encrypted for everyone in .sops.keys.yaml
# make rotate   -> re-encrypt existing secrets for the current .sops.keys.yaml (run after adding a party)
# make keypair  -> extract the committed private key into ~/.k0stool/ for ssh
# make decrypt FILE=<name> -> decrypt any committed secret (short name or path)
# make clean    -> remove the extracted keys
#
# Typical first-time setup:
#   make tools && make age-key
#   # paste the printed public key into .sops.keys.yaml
#   make secret
#   git add .sops.keys.yaml secrets/ && git commit
#
# .sops.yaml is GENERATED from .sops.keys.yaml — edit the keys file, never .sops.yaml.

KEY_DIR      := $(HOME)/.k0stool
KEY_NAME     := k0stool-key
PRIVATE_KEY  := $(KEY_DIR)/$(KEY_NAME)
AGE_KEY      := $(HOME)/.config/sops/age/keys.txt
SECRET_FILE  := secrets/ssh-keypair.enc.yaml
KEYS_FILE    := .sops.keys.yaml
SOPS_CONFIG  := .sops.yaml
SOPS_VERSION := 3.9.0

.PHONY: tools age-key secret rotate keypair decrypt clean

tools:
	@command -v age-keygen >/dev/null 2>&1 || { sudo apt-get update && sudo apt-get install -y age; }
	@command -v sops >/dev/null 2>&1 || { \
		arch=$$(uname -m); \
		[ "$$arch" = "x86_64" ] && arch=amd64 || arch=arm64; \
		echo "installing sops v$(SOPS_VERSION)..."; \
		curl -sSfL -o /tmp/sops https://github.com/getsops/sops/releases/download/v$(SOPS_VERSION)/sops-v$(SOPS_VERSION).linux.$${arch}; \
		sudo install -m 755 /tmp/sops /usr/local/bin/sops; \
	}
	@sops --version

age-key: tools
	@test -f $(AGE_KEY) || { \
		mkdir -p $$(dirname $(AGE_KEY)); \
		echo "generating age key..."; \
		age-keygen -o $(AGE_KEY); \
	}
	@echo "age public key: $$(age-keygen -y $(AGE_KEY))"
	@echo "-> add this to $(KEYS_FILE)"

$(SOPS_CONFIG): $(KEYS_FILE)
	@keys=$$(grep -oE 'age1[a-z0-9]+' $(KEYS_FILE) | paste -sd, -); \
	if [ -z "$$keys" ]; then \
		echo "no age public keys found in $(KEYS_FILE) — add at least one (see the comments in that file)"; \
		exit 1; \
	fi; \
	printf 'creation_rules:\n  - path_regex: secrets/.*\\.enc\\.yaml$$\n    age: %s\n' "$$keys" > $(SOPS_CONFIG); \
	echo "generated $(SOPS_CONFIG) for $$keys"

secret: age-key $(SOPS_CONFIG)
	@test ! -f $(SECRET_FILE) || { echo "$(SECRET_FILE) already exists — run 'make rotate' to update recipients, or delete it to start over"; exit 1; }
	@mkdir -p $$(dirname $(SECRET_FILE))
	@tmp=$$(mktemp -d); \
	ssh-keygen -t ed25519 -f $$tmp/key -N "" -C "k0stool" -q; \
	{ echo "private_key: |"; sed 's/^/    /' $$tmp/key; echo "public_key: $$(cat $$tmp/key.pub)"; } > $(SECRET_FILE); \
	rm -rf $$tmp
	@sops --encrypt --in-place $(SECRET_FILE)
	@sops -d $(SECRET_FILE) | grep -q "BEGIN OPENSSH PRIVATE KEY"
	@echo "created and verified $(SECRET_FILE) — commit it:"
	@echo "  git add $(KEYS_FILE) secrets/ && git commit -m 'add encrypted ssh keypair'"

rotate: $(SOPS_CONFIG)
	@test -f $(SECRET_FILE) || { echo "nothing to rotate — $(SECRET_FILE) does not exist"; exit 1; }
	@sops rotate --in-place $(SECRET_FILE)
	@echo "re-encrypted $(SECRET_FILE) for: $$(grep -oE 'age1[a-z0-9]+' $(KEYS_FILE) | paste -sd, -)"
	@echo "commit the result: git add secrets/ && git commit"

keypair:
	@test -f $(SECRET_FILE) || { echo "missing $(SECRET_FILE) — clone the repo or run 'make secret'"; exit 1; }
	@test -f $(PRIVATE_KEY) || { \
		mkdir -p $(KEY_DIR); \
		echo "extracting ssh keypair from $(SECRET_FILE)..."; \
		umask 077; \
		sops -d --extract '["private_key"]' $(SECRET_FILE) > $(PRIVATE_KEY); \
		sops -d --extract '["public_key"]' $(SECRET_FILE) > $(PRIVATE_KEY).pub; \
		chmod 644 $(PRIVATE_KEY).pub; \
	}
	@echo "keypair ready: $(PRIVATE_KEY)"

decrypt:
	@test -n "$(FILE)" || { \
		echo "usage: make decrypt FILE=<name>"; \
		echo "available encrypted secrets:"; \
		ls secrets/*.enc.yaml 2>/dev/null || echo "  (none found)"; \
		exit 1; \
	}
	@f="$(FILE)"; \
	case "$$f" in */*) : ;; *) f="secrets/$$f" ;; esac; \
	case "$$f" in *.enc.yaml) : ;; *) f="$$f.enc.yaml" ;; esac; \
	test -f "$$f" || { echo "no such encrypted file: $$f"; exit 1; }; \
	sops -d "$$f"

clean:
	@rm -f $(PRIVATE_KEY) $(PRIVATE_KEY).pub
