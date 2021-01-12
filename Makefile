############################# Main targets #############################
# Install all tools and builds binaries.
install: update-tools bins

# Rebuild binaries.
bins: clean-bins temporal-server tctl temporal-cassandra-tool temporal-sql-tool

# Install all tools, recompile proto files, run all possible checks and tests (long but comprehensive).
all: update-tools clean proto bins check test

# Used by Buildkite.
ci-build: bins update-tools check proto mocks gomodtidy ensure-no-changes

# Delete all build artefacts.
clean: clean-bins clean-test-results

# Recompile proto files.
proto: clean-proto install-proto-submodule buf-lint api-linter protoc fix-proto-path goimports-proto proto-mocks copyright-proto

# Update proto submodule from remote and recompile proto files.
update-proto: clean-proto update-proto-submodule buf-lint api-linter protoc fix-proto-path update-go-api goimports-proto proto-mocks copyright-proto gomodtidy
########################################################################

.PHONY: proto

##### Variables ######
ifndef GOOS
GOOS := $(shell go env GOOS)
endif

ifndef GOARCH
GOARCH := $(shell go env GOARCH)
endif

ifndef GOPATH
GOPATH := $(shell go env GOPATH)
endif

GOBIN := $(if $(shell go env GOBIN),$(shell go env GOBIN),$(GOPATH)/bin)
SHELL := PATH=$(GOBIN):$(PATH) /bin/sh

MODULE_ROOT := go.temporal.io/server
COLOR := "\e[1;36m%s\e[0m\n"
RED :=   "\e[1;31m%s\e[0m\n"

define NEWLINE


endef

TEST_TIMEOUT := 20m

INTEG_TEST_ROOT        := ./host
INTEG_TEST_XDC_ROOT    := ./host/xdc
INTEG_TEST_NDC_ROOT    := ./host/ndc

ifndef PERSISTENCE_TYPE
override PERSISTENCE_TYPE := nosql
endif

ifndef PERSISTENCE_DRIVER
override PERSISTENCE_DRIVER := cassandra
endif

ifdef TEST_TAG
override TEST_TAG := -tags $(TEST_TAG)
endif

PROTO_ROOT := proto
PROTO_FILES = $(shell find ./$(PROTO_ROOT)/internal -name "*.proto")
PROTO_DIRS = $(sort $(dir $(PROTO_FILES)))
PROTO_IMPORTS := -I=$(PROTO_ROOT)/internal -I=$(PROTO_ROOT)/api -I=$(GOPATH)/src/github.com/temporalio/gogo-protobuf/protobuf
PROTO_OUT := api

ALL_SRC         := $(shell find . -name "*.go" | grep -v -e "^$(PROTO_OUT)")
TEST_DIRS       := $(sort $(dir $(filter %_test.go,$(ALL_SRC))))
INTEG_TEST_DIRS := $(filter $(INTEG_TEST_ROOT)/ $(INTEG_TEST_NDC_ROOT)/,$(TEST_DIRS))
UNIT_TEST_DIRS  := $(filter-out $(INTEG_TEST_ROOT)% $(INTEG_TEST_XDC_ROOT)% $(INTEG_TEST_NDC_ROOT)%,$(TEST_DIRS))

# Code coverage output files.
COVER_ROOT                 := ./.coverage
UNIT_COVER_PROFILE         := $(COVER_ROOT)/unit_coverprofile.out
INTEG_COVER_PROFILE        := $(COVER_ROOT)/integ_$(PERSISTENCE_DRIVER)_coverprofile.out
INTEG_XDC_COVER_PROFILE    := $(COVER_ROOT)/integ_xdc_$(PERSISTENCE_DRIVER)_coverprofile.out
INTEG_NDC_COVER_PROFILE    := $(COVER_ROOT)/integ_ndc_$(PERSISTENCE_DRIVER)_coverprofile.out
SUMMARY_COVER_PROFILE      := $(COVER_ROOT)/summary_coverprofile.out

# Need the following option to have integration tests count towards coverage. godoc below:
# -coverpkg pkg1,pkg2,pkg3
#   Apply coverage analysis in each test to the given list of packages.
#   The default is for each test to analyze only the package being tested.
#   Packages are specified as import paths.
GOCOVERPKG_ARG := -coverpkg="$(MODULE_ROOT)/common/...,$(MODULE_ROOT)/service/...,$(MODULE_ROOT)/client/...,$(MODULE_ROOT)/tools/..."

##### Tools #####
update-checkers:
	@printf $(COLOR) "Install/update check tools..."
	cd && GO111MODULE=on go get golang.org/x/tools/cmd/goimports
	cd && GO111MODULE=on go get golang.org/x/lint/golint
	cd && GO111MODULE=on go get honnef.co/go/tools/cmd/staticcheck@v0.1.0
	cd && GO111MODULE=on go get github.com/kisielk/errcheck@v1.4.0
	cd && GO111MODULE=on go get github.com/googleapis/api-linter/cmd/api-linter@v1.10.0
	cd && GO111MODULE=on go get github.com/bufbuild/buf/cmd/buf@v0.33.0

update-mockgen:
	@printf $(COLOR) "Install/update mockgen tool..."
	cd && GO111MODULE=on go get github.com/golang/mock/mockgen@1fe605df5e5f07f453dc4f594cc3510c914dbdee

update-proto-plugins:
	@printf $(COLOR) "Install/update proto plugins..."
	GO111MODULE=off go get github.com/temporalio/gogo-protobuf/protoc-gen-gogoslick
	cd && GO111MODULE=on go get google.golang.org/grpc@v1.34.0

update-tools: update-checkers update-mockgen update-proto-plugins

##### Proto #####
$(PROTO_OUT):
	@mkdir -p $(PROTO_OUT)

clean-proto:
	@rm -rf $(PROTO_OUT)/*

update-proto-submodule:
	@printf $(COLOR) "Update proto submodule from remote..."
	git submodule update --force --remote $(PROTO_ROOT)/api

install-proto-submodule:
	@printf $(COLOR) "Install proto submodule..."
	git submodule update --init $(PROTO_ROOT)/api

protoc: $(PROTO_OUT)
	@printf $(COLOR) "Build proto files..."
# Run protoc separately for each directory because of different package names.
	$(foreach PROTO_DIR,$(PROTO_DIRS),\
		protoc $(PROTO_IMPORTS) \
		 	--gogoslick_out=Mgoogle/protobuf/descriptor.proto=github.com/golang/protobuf/protoc-gen-go/descriptor,Mgoogle/protobuf/duration.proto=github.com/gogo/protobuf/types,Mgoogle/protobuf/wrappers.proto=github.com/gogo/protobuf/types,Mgoogle/protobuf/timestamp.proto=github.com/gogo/protobuf/types,plugins=grpc,paths=source_relative:$(PROTO_OUT) \
			$(PROTO_DIR)*.proto \
	$(NEWLINE))

fix-proto-path:
	mv -f $(PROTO_OUT)/temporal/server/api/* $(PROTO_OUT) && rm -rf $(PROTO_OUT)/temporal

# All gRPC generated service files pathes relative to PROTO_OUT.
PROTO_GRPC_SERVICES = $(patsubst $(PROTO_OUT)/%,%,$(shell find $(PROTO_OUT) -name "service.pb.go"))
service_name = $(firstword $(subst /, ,$(1)))
mock_file_name = $(call service_name,$(1))mock/$(subst $(call service_name,$(1))/,,$(1:go=mock.go))

proto-mocks: $(PROTO_OUT)
	@printf $(COLOR) "Generate proto mocks..."
	$(foreach PROTO_GRPC_SERVICE,$(PROTO_GRPC_SERVICES),\
		cd $(PROTO_OUT) && \
		mockgen -package $(call service_name,$(PROTO_GRPC_SERVICE))mock -source $(PROTO_GRPC_SERVICE) -destination $(call mock_file_name,$(PROTO_GRPC_SERVICE)) \
	$(NEWLINE))

update-go-api:
	@printf $(COLOR) "Update go.temporal.io/api@master..."
	@go get -u go.temporal.io/api@master

goimports-proto:
	@printf $(COLOR) "Run goimports for proto files..."
	@goimports -w $(PROTO_OUT)

copyright-proto:
	@printf $(COLOR) "Update license headers for proto files..."
	@go run ./cmd/tools/copyright/licensegen.go --scanDir $(PROTO_OUT)

##### Binaries #####
clean-bins:
	@printf $(COLOR) "Delete old binaries..."
	@rm -f tctl
	@rm -f temporal-server
	@rm -f temporal-cassandra-tool
	@rm -f temporal-sql-tool

temporal-server:
	@printf $(COLOR) "Build temporal-server with OS: $(GOOS), ARCH: $(GOARCH)..."
	go build -ldflags "$(shell ./scripts/go-build-ldflags.sh $(MODULE_ROOT)/ldflags)" -o temporal-server cmd/server/main.go

tctl:
	@printf $(COLOR) "Build tctl with OS: $(GOOS), ARCH: $(GOARCH)..."
	go build -o tctl cmd/tools/cli/main.go

temporal-cassandra-tool:
	@printf $(COLOR) "Build temporal-cassandra-tool with OS: $(GOOS), ARCH: $(GOARCH)..."
	go build -o temporal-cassandra-tool cmd/tools/cassandra/main.go

temporal-sql-tool:
	@printf $(COLOR) "Build temporal-sql-tool with OS: $(GOOS), ARCH: $(GOARCH)..."
	go build -o temporal-sql-tool cmd/tools/sql/main.go

##### Checks #####
copyright-check:
	@printf $(COLOR) "Check license header..."
	@go run ./cmd/tools/copyright/licensegen.go --verifyOnly

lint:
	@printf $(COLOR) "Run linter..."
	@golint ./...

vet:
	@printf $(COLOR) "Run go vet..."
	@go vet ./... || true

goimports-check:
	@printf $(COLOR) "Run goimports checks..."
	@goimports -l .

goimports:
	@printf $(COLOR) "Run goimports..."
	@goimports -w .

staticcheck:
	@printf $(COLOR) "Run staticcheck..."
	@staticcheck -fail none ./...

errcheck:
	@printf $(COLOR) "Run errcheck..."
	@errcheck ./... || true

api-linter:
	@printf $(COLOR) "Run api-linter..."
	@api-linter --set-exit-status $(PROTO_IMPORTS) --config=$(PROTO_ROOT)/api-linter.yaml $(PROTO_FILES)

buf-lint:
	@printf $(COLOR) "Run buf linter..."
	@(cd $(PROTO_ROOT) && buf check lint)

buf-build:
	@printf $(COLOR) "Build image.bin with buf..."
	@(cd $(PROTO_ROOT) && buf build -o image.bin)

buf-breaking:
	@printf $(COLOR) "Run buf breaking changes check against image.bin..."
	@(cd $(PROTO_ROOT) && buf check breaking --against image.bin)

check: copyright-check goimports-check lint vet staticcheck errcheck

##### Tests #####
clean-test-results:
	@rm -f test.log
	@go clean -testcache

unit-test: clean-test-results
	@printf $(COLOR) "Run unit tests..."
	$(foreach UNIT_TEST_DIR,$(UNIT_TEST_DIRS),\
		@go test -timeout $(TEST_TIMEOUT) -race $(UNIT_TEST_DIR) $(TEST_TAG) | tee -a test.log \
	$(NEWLINE))
	@! grep -q "^--- FAIL" test.log

integration-test: clean-test-results
	@printf $(COLOR) "Run integration tests..."
	$(foreach INTEG_TEST_DIR,$(INTEG_TEST_DIRS),\
		@go test -timeout $(TEST_TIMEOUT) -race $(INTEG_TEST_DIR) $(TEST_TAG) | tee -a test.log \
	$(NEWLINE))
# Need to run xdc tests with race detector off because of ringpop bug causing data race issue.
	@go test -timeout $(TEST_TIMEOUT) $(INTEG_TEST_XDC_ROOT) $(TEST_TAG) | tee -a test.log
	@! grep -q "^--- FAIL" test.log

test: unit-test integration-test

##### Coverage #####
$(COVER_ROOT):
	@mkdir -p $(COVER_ROOT)

unit-test-coverage: $(COVER_ROOT)
	@printf $(COLOR) "Run unit tests with coverage..."
	@echo "mode: atomic" > $(UNIT_COVER_PROFILE)
	$(foreach UNIT_TEST_DIR,$(patsubst ./%/,%,$(UNIT_TEST_DIRS)),\
		@mkdir -p $(COVER_ROOT)/$(UNIT_TEST_DIR); \
		go test ./$(UNIT_TEST_DIR) -timeout $(TEST_TIMEOUT) -race -coverprofile=$(COVER_ROOT)/$(UNIT_TEST_DIR)/coverprofile.out || exit 1; \
		grep -v -e "^mode: \w\+" $(COVER_ROOT)/$(UNIT_TEST_DIR)/coverprofile.out >> $(UNIT_COVER_PROFILE) || true \
	$(NEWLINE))

integration-test-coverage: $(COVER_ROOT)
	@printf $(COLOR) "Run integration tests with coverage with $(PERSISTENCE_DRIVER) driver..."
	@go test $(INTEG_TEST_ROOT) -timeout $(TEST_TIMEOUT) -race $(TEST_TAG) -persistenceType=$(PERSISTENCE_TYPE) -persistenceDriver=$(PERSISTENCE_DRIVER) $(GOCOVERPKG_ARG) -coverprofile=$(INTEG_COVER_PROFILE)

integration-test-xdc-coverage: $(COVER_ROOT)
	@printf $(COLOR) "Run integration test for cross DC with coverage with $(PERSISTENCE_DRIVER) driver..."
	@go test $(INTEG_TEST_XDC_ROOT) -timeout $(TEST_TIMEOUT) $(TEST_TAG) -persistenceType=$(PERSISTENCE_TYPE) -persistenceDriver=$(PERSISTENCE_DRIVER) $(GOCOVERPKG_ARG) -coverprofile=$(INTEG_XDC_COVER_PROFILE)

integration-test-ndc-coverage: $(COVER_ROOT)
	@printf $(COLOR) "Run integration test for NDC with coverage with $(PERSISTENCE_DRIVER) driver..."
	@go test $(INTEG_TEST_NDC_ROOT) -timeout $(TEST_TIMEOUT) -race $(TEST_TAG) -persistenceType=$(PERSISTENCE_TYPE) -persistenceDriver=$(PERSISTENCE_DRIVER) $(GOCOVERPKG_ARG) -coverprofile=$(INTEG_NDC_COVER_PROFILE)

$(SUMMARY_COVER_PROFILE): $(COVER_ROOT)
	@printf $(COLOR) "Combine coverage reports to $(SUMMARY_COVER_PROFILE)..."
	@rm -f $(SUMMARY_COVER_PROFILE)
	@echo "mode: atomic" > $(SUMMARY_COVER_PROFILE)
	$(foreach COVER_PROFILE,$(wildcard $(COVER_ROOT)/*_coverprofile.out),\
		@printf $(COLOR) $(COVER_PROFILE); \
		cat $(COVER_PROFILE) | grep -v -e "^mode: \w\+" | grep -v -E "[Mm]ocks?" >> $(SUMMARY_COVER_PROFILE) \
	$(NEWLINE))

coverage-report: $(SUMMARY_COVER_PROFILE)
	@printf $(COLOR) "Generate HTML report from $(SUMMARY_COVER_PROFILE) to $(SUMMARY_COVER_PROFILE).html..."
	@go tool cover -html=$(SUMMARY_COVER_PROFILE) -o $(SUMMARY_COVER_PROFILE).html

ci-coverage-report: $(SUMMARY_COVER_PROFILE) coverage-report
	@printf $(COLOR) "Generate Coveralls report from $(SUMMARY_COVER_PROFILE)..."
	cd && GO111MODULE=on go get github.com/mattn/goveralls@v0.0.7
	@goveralls -coverprofile=$(SUMMARY_COVER_PROFILE) -service=buildkite || (printf $(RED) "Generating report for Coveralls (goveralls) failed."; exit 1)

##### Schema #####
install-schema: temporal-cassandra-tool
	@printf $(COLOR) "Install Cassandra schema..."
	./temporal-cassandra-tool --ep 127.0.0.1 create -k temporal --rf 1
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal setup-schema -v 0.0
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal update-schema -d ./schema/cassandra/temporal/versioned
	./temporal-cassandra-tool --ep 127.0.0.1 create -k temporal_visibility --rf 1
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_visibility setup-schema -v 0.0
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_visibility update-schema -d ./schema/cassandra/visibility/versioned

install-schema-mysql-pre5720: temporal-sql-tool
	@printf $(COLOR) "Install MySQL schema..."
	./temporal-sql-tool --ep 127.0.0.1 --ca tx_isolation='READ-COMMITTED' create --db temporal
	./temporal-sql-tool --ep 127.0.0.1 --ca tx_isolation='READ-COMMITTED' --db temporal setup-schema -v 0.0
	./temporal-sql-tool --ep 127.0.0.1 --ca tx_isolation='READ-COMMITTED' --db temporal update-schema -d ./schema/mysql/v57/temporal/versioned
	./temporal-sql-tool --ep 127.0.0.1 --ca tx_isolation='READ-COMMITTED' create --db temporal_visibility
	./temporal-sql-tool --ep 127.0.0.1 --ca tx_isolation='READ-COMMITTED' --db temporal_visibility setup-schema -v 0.0
	./temporal-sql-tool --ep 127.0.0.1 --ca tx_isolation='READ-COMMITTED' --db temporal_visibility update-schema -d ./schema/mysql/v57/visibility/versioned

install-schema-mysql: temporal-sql-tool
	@printf $(COLOR) "Install MySQL schema..."
	./temporal-sql-tool --ep 127.0.0.1 -u root --pw root create --db temporal
	./temporal-sql-tool --ep 127.0.0.1 -u root --pw root --db temporal setup-schema -v 0.0
	./temporal-sql-tool --ep 127.0.0.1 -u root --pw root --db temporal update-schema -d ./schema/mysql/v57/temporal/versioned
	./temporal-sql-tool --ep 127.0.0.1 -u root --pw root create --db temporal_visibility
	./temporal-sql-tool --ep 127.0.0.1 -u root --pw root --db temporal_visibility setup-schema -v 0.0
	./temporal-sql-tool --ep 127.0.0.1 -u root --pw root --db temporal_visibility update-schema -d ./schema/mysql/v57/visibility/versioned

install-schema-postgresql: temporal-sql-tool
	@printf $(COLOR) "Install Postgres schema..."
	./temporal-sql-tool --ep 127.0.0.1 -p 5432 -u temporal -pw temporal --pl postgres create --db temporal
	./temporal-sql-tool --ep 127.0.0.1 -p 5432 -u temporal -pw temporal --pl postgres --db temporal setup -v 0.0
	./temporal-sql-tool --ep 127.0.0.1 -p 5432 -u temporal -pw temporal --pl postgres --db temporal update-schema -d ./schema/postgresql/v96/temporal/versioned
	./temporal-sql-tool --ep 127.0.0.1 -p 5432 -u temporal -pw temporal --pl postgres create --db temporal_visibility
	./temporal-sql-tool --ep 127.0.0.1 -p 5432 -u temporal -pw temporal --pl postgres --db temporal_visibility setup-schema -v 0.0
	./temporal-sql-tool --ep 127.0.0.1 -p 5432 -u temporal -pw temporal --pl postgres --db temporal_visibility update-schema -d ./schema/postgresql/v96/visibility/versioned

install-schema-es:
	@printf $(COLOR) "Install Elasticsearch schema..."
	curl -X PUT "http://127.0.0.1:9200/_template/temporal-visibility-template" -H "Content-Type: application/json" --data-binary @./schema/elasticsearch/v7/visibility/index_template.json
	curl -X PUT "http://127.0.0.1:9200/temporal-visibility-dev"

install-schema-cdc: temporal-cassandra-tool
	@printf $(COLOR)  "Set up temporal_active key space..."
	./temporal-cassandra-tool --ep 127.0.0.1 create -k temporal_active --rf 1
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_active setup-schema -v 0.0
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_active update-schema -d ./schema/cassandra/temporal/versioned
	./temporal-cassandra-tool --ep 127.0.0.1 create -k temporal_visibility_active --rf 1
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_visibility_active setup-schema -v 0.0
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_visibility_active update-schema -d ./schema/cassandra/visibility/versioned

	@printf $(COLOR) "Set up temporal_standby key space..."
	./temporal-cassandra-tool --ep 127.0.0.1 create -k temporal_standby --rf 1
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_standby setup-schema -v 0.0
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_standby update-schema -d ./schema/cassandra/temporal/versioned
	./temporal-cassandra-tool --ep 127.0.0.1 create -k temporal_visibility_standby --rf 1
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_visibility_standby setup-schema -v 0.0
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_visibility_standby update-schema -d ./schema/cassandra/visibility/versioned

	@printf $(COLOR) "Set up temporal_other key space..."
	./temporal-cassandra-tool --ep 127.0.0.1 create -k temporal_other --rf 1
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_other setup-schema -v 0.0
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_other update-schema -d ./schema/cassandra/temporal/versioned
	./temporal-cassandra-tool --ep 127.0.0.1 create -k temporal_visibility_other --rf 1
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_visibility_other setup-schema -v 0.0
	./temporal-cassandra-tool --ep 127.0.0.1 -k temporal_visibility_other update-schema -d ./schema/cassandra/visibility/versioned

##### Run server #####
start-dependencies:
	docker-compose -f docker-compose/docker-compose.yml -f docker-compose/docker-compose.$(GOOS).yml up

stop-dependencies:
	docker-compose -f docker-compose/docker-compose.yml -f docker-compose/docker-compose.$(GOOS).yml down

start: temporal-server
	./temporal-server start

start-es: temporal-server
	./temporal-server --zone es start

start-cdc-active: temporal-server
	./temporal-server --zone active start

start-cdc-standby: temporal-server
	./temporal-server --zone standby start

start-cdc-other: temporal-server
	./temporal-server --zone other start

##### Mocks #####
AWS_SDK_VERSION := $(lastword $(shell grep "github.com/aws/aws-sdk-go" go.mod))
external-mocks:
	@printf $(COLOR) "Generate external libraries mocks..."
	@mockgen -copyright_file LICENSE -package mocks -source $(GOPATH)/pkg/mod/github.com/aws/aws-sdk-go@$(AWS_SDK_VERSION)/service/s3/s3iface/interface.go | grep -v -e "^// Source: .*" > common/archiver/s3store/mocks/S3API.go

go-generate:
	@printf $(COLOR) "Process go:generate directives..."
	@go generate ./...

mocks: go-generate external-mocks

##### Auxilary #####
gomodtidy:
	@printf $(COLOR) "go mod tidy..."
	@go mod tidy

ensure-no-changes:
	@git diff --name-status --exit-code || (printf $(RED) "Above files are not regenerated properly. Regenerate them and try again."; exit 1)
