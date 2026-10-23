# Build pipeline for the Go implementation of slang.
#
#   make build        build bin/slang from the committed seed (go/boot)
#   make seed         re-generate the seed with bin/slang itself (self-hosting)
#   make fixpoint     check that the seed compiles itself to identical bytecode
#   make test         run the slang test suite
#   make stage0-seed  generate the seed with the legacy Dart compiler (bootstrap reference only)

DART   ?= dart
GO     ?= go
STAGE0  = cd legacy && $(DART) run tool/stage0.dart

LIB_SRC  := $(wildcard slang/lib/*.slang)
COMPILER_SRC := $(wildcard slang/compiler/*.slang)
TEST_SRC := $(wildcard test/*.slang)

.PHONY: all seed fixpoint test build stage0-seed clean

all: build

build:
	cd go && $(GO) build -o ../bin/slang ./cmd/slang

# self-hosted seed: compile every library/compiler source with the current binary
seed: build
	@for f in $(LIB_SRC) $(COMPILER_SRC); do \
	  n=$$(basename $$f .slang); \
	  bin/slang compile $$f -o go/boot/slang/$$n.slb --origin slang/$$n || exit 1; \
	  echo "seed: $$f -> go/boot/slang/$$n.slb"; \
	done
	cd go && $(GO) build -o ../bin/slang ./cmd/slang

# the seed must reproduce itself exactly
fixpoint: build
	@rm -rf /tmp/slang-fixpoint && mkdir -p /tmp/slang-fixpoint
	@for f in $(LIB_SRC) $(COMPILER_SRC); do \
	  n=$$(basename $$f .slang); \
	  bin/slang compile $$f -o /tmp/slang-fixpoint/$$n.slb --origin slang/$$n || exit 1; \
	  cmp go/boot/slang/$$n.slb /tmp/slang-fixpoint/$$n.slb || { echo "fixpoint: $$n differs"; exit 1; }; \
	done
	@echo "fixpoint: ok"

test: build
	bin/slang test test

stage0-seed: $(LIB_SRC) $(COMPILER_SRC)
	$(STAGE0) --out ../go/boot --strip ../slang/lib/ --prefix slang/ $(addprefix ../,$(LIB_SRC))
	$(STAGE0) --out ../go/boot --strip ../slang/compiler/ --prefix slang/ $(addprefix ../,$(COMPILER_SRC))

clean:
	rm -f bin/slang
