# k0stool helpers
#
# make keypair   -> generate ~/.k0stool/k0stool-key{,.pub} (skipped if it exists)
# make clean     -> remove the generated keys

KEY_DIR     := $(HOME)/.k0stool
KEY_NAME    := k0stool-key
PRIVATE_KEY := $(KEY_DIR)/$(KEY_NAME)

.PHONY: keypair clean

keypair: $(PRIVATE_KEY)
	@echo "keypair ready: $(PRIVATE_KEY)"

$(PRIVATE_KEY):
	@mkdir -p $(KEY_DIR)
	@echo "generating ed25519 keypair..."
	@ssh-keygen -t ed25519 -f $(PRIVATE_KEY) -N "" -C "k0stool" -q
	@chmod 600 $(PRIVATE_KEY)

clean:
	@rm -f $(PRIVATE_KEY) $(PRIVATE_KEY).pub