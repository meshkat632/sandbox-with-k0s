BINARY  := tfstack
PKG     := github.com/meshkat632/sandbox-with-k0s/tfstack
VERSION ?= $(shell git describe --tags --match 'tfstack/v*' --always --dirty 2>/dev/null | sed 's|^tfstack/||')
COMMIT  := $(shell git rev-parse --short HEAD 2>/dev/null)
DATE    := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -s -w \
	-X $(PKG)/internal/version.Version=$(VERSION) \
	-X $(PKG)/internal/version.Commit=$(COMMIT) \
	-X $(PKG)/internal/version.Date=$(DATE)
GOFLAGS_BUILD := -trimpath -ldflags "$(LDFLAGS)"
PLATFORMS := linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64

.PHONY: build install test cover vet fmt fmt-check lint check dist clean

build: ## Build bin/tfstack
	CGO_ENABLED=0 go build $(GOFLAGS_BUILD) -o bin/$(BINARY) ./cmd/tfstack

install: ## Install into GOBIN
	CGO_ENABLED=0 go install $(GOFLAGS_BUILD) ./cmd/tfstack

test: ## Run tests with the race detector
	go test -race ./...

cover: ## Write coverage.out and print the total
	go test -coverprofile=coverage.out ./...
	go tool cover -func=coverage.out | tail -1

vet:
	go vet ./...

fmt:
	gofmt -w .

fmt-check:
	@test -z "$$(gofmt -l .)" || { echo "gofmt needed:"; gofmt -l .; exit 1; }

lint: ## Needs golangci-lint v2
	golangci-lint run

check: fmt-check vet test ## What CI runs, minus golangci-lint

dist: ## Cross-compile release archives into dist/
	@rm -rf dist && mkdir -p dist
	@for p in $(PLATFORMS); do \
		os=$${p%/*}; arch=$${p#*/}; ext=; [ $$os = windows ] && ext=.exe; \
		out=dist/$(BINARY)_$(VERSION)_$${os}_$${arch}; \
		echo "building $$out"; \
		mkdir -p $$out && cp README.md $$out/ && \
		CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build $(GOFLAGS_BUILD) -o $$out/$(BINARY)$$ext ./cmd/tfstack && \
		tar -C dist -czf $$out.tar.gz $$(basename $$out) && rm -r $$out || exit 1; \
	done
	@cd dist && sha256sum *.tar.gz > checksums.txt

clean:
	rm -rf bin dist coverage.out
