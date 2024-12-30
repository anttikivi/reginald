GCI_VERSION = 0.13.5
GOFUMPT_VERSION = 0.7.0
GOLANGCI_LINT_VERSION = 1.62.2
LICENSEI_VERSION = 0.9.0

OUTPUT_NAME ?= reginald

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
all: build

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
clean: script/build$(EXE)
	@$< $@

.PHONY: test
test:
	go test ./...

## Lint tasks

.PHONY: lint
lint: golangci-lint

.PHONY: golangci-lint
golangci-lint:
	@go run github.com/golangci/golangci-lint/cmd/golangci-lint@v${GOLANGCI_LINT_VERSION} run ./...

## License checks
# These are meant to be run in the CI.

.PHONY: license-check
license-check:
	go mod vendor
	bin/licensei cache --debug
	bin/licensei check --debug
	bin/licensei header --debug
	rm -rf vendor/
	git diff --exit-code

deps: bin/licensei

bin/licensei: bin/licensei-${LICENSEI_VERSION}
	@ln -sf licensei-${LICENSEI_VERSION} bin/licensei
bin/licensei-${LICENSEI_VERSION}:
	@mkdir -p bin
	curl -sfL https://git.io/licensei | bash -s v${LICENSEI_VERSION}
	@mv bin/licensei $@
