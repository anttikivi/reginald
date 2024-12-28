GCI_VERSION = 0.13.5
GOFUMPT_VERSION = 0.7.0
GOLANGCI_LINT_VERSION = 1.62.2
LICENSEI_VERSION = 0.9.0
OUTPUT_NAME=reginald

.PHONY: all
all: build

.PHONY: build
build:
ifneq ($(REGINALD_VERSION),)
	go build -ldflags "-X 'main.buildVersion=$(REGINALD_VERSION)'" -o "$(OUTPUT_NAME)" ./main.go
else
	go build -o "$(OUTPUT_NAME)" ./main.go
endif

.PHONY: run
run:
	go run ./main.go

.PHONY: fmt
fmt:
	go run github.com/daixiang0/gci@v${GCI_VERSION} write . --skip-generated -s standard -s default
	go run mvdan.cc/gofumpt@v${GOFUMPT_VERSION} -l -w .

.PHONY: test
test:
	go test -v ./...

.PHONY: check
check: lint license-check

.PHONY: lint
lint: golangci-lint

.PHONY: golangci-lint
golangci-lint:
	go run github.com/golangci/golangci-lint/cmd/golangci-lint@v${GOLANGCI_LINT_VERSION} run ./...

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
