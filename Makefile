GCI_VERSION = 0.13.5
GOFUMPT_VERSION = 0.7.0
GOLANGCI_LINT_VERSION = 1.62.2
GOLINES_VERSION = 0.12.2
GO_LICENSES_VERSION = 1.6.0

ALLOWED_LICENSES = "Apache-2.0,BSD-2-Clause,BSD-3-Clause,MIT,MPL-2.0"

GO_MODULE_NAME = github.com/anttikivi/reginald

OUTPUT_NAME ?= rgl

CGO_CPPFLAGS ?= ${CPPFLAGS}
export CGO_CPPFLAGS
CGO_CFLAGS ?= ${CFLAGS}
export CGO_CFLAGS
CGO_LDFLAGS ?= $(filter -g -L% -l% -O%,${LDFLAGS})
export CGO_LDFLAGS

EXE =
ifeq ($(shell go env GOOS),windows)
EXE = .exe
endif

.PHONY: all
all: build plugins

scripts/build$(EXE): scripts/build.go
ifeq ($(EXE),)
	GOOS= GOARCH= GOARM= GOFLAGS= CGO_ENABLED= go build -o $@ $<
else
	go build -o $@ $<
endif

.PHONY: bin/$(OUTPUT_NAME)$(EXE)
bin/$(OUTPUT_NAME)$(EXE): scripts/build$(EXE)
	@$< $@

.PHONY: build
build: bin/$(OUTPUT_NAME)$(EXE)

.PHONY: clean
clean: scripts/build$(EXE)
	@$< $@

.PHONY: man
man: scripts/build$(EXE)
	@$< $@

.PHONY: plugins
plugins: scripts/build$(EXE)
	@$< $@

.PHONY: test
test:
	go test ./...

.PHONY: bench
bench:
	go test -bench=. ./...

## Formatting tasks

# Is there a bit too much going on in this command?
.PHONY: fmt
fmt:
	# go fmt ./...
	go mod tidy
	go run github.com/daixiang0/gci@v$(GCI_VERSION) write . --skip-generated --skip-vendor -s standard -s default
	go run github.com/segmentio/golines@v$(GOLINES_VERSION) -m 120 --no-chain-split-dots -w .
	go run mvdan.cc/gofumpt@v$(GOFUMPT_VERSION) -extra -l -w .

## Lint tasks

.PHONY: lint
lint: golangci-lint

.PHONY: golangci-lint
golangci-lint:
	@go run github.com/golangci/golangci-lint/cmd/golangci-lint@v$(GOLANGCI_LINT_VERSION) run ./...

## License checks

.PHONY: license-check
license-check:
	go mod verify
	go mod download
	go run github.com/google/go-licenses@v$(GO_LICENSES_VERSION) check --include_tests $(GO_MODULE_NAME)/... --allowed_licenses=$(ALLOWED_LICENSES)
