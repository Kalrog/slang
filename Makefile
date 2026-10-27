# Build pipeline for the Go implementation of slang.
#
#   make build        build bin/slang from the committed seed (go/boot)
#   make seed         re-generate the seed with bin/slang itself (self-hosting)
#   make fixpoint     check that the seed compiles itself to identical bytecode
#   make test         run the slang test suite
#   make stage0-seed  generate the seed with the legacy Dart compiler (bootstrap reference only)
#   make dungeon      run the example game (examples/dungeon) on Ebitengine
#   make dungeon-test run the example game's DSL tests
#   make zig          build the Zig VM (zig/zig-out/bin/slang), see PLAN_ZIG.md
#   make zig-test     run the slang test suite and the Zig unit tests on the Zig VM (fast and checked builds)
#   make zig-fixpoint check that the Zig VM compiles the seed to identical bytecode
#   make breakout     run the breakout example (examples/breakout) on the Zig VM with the raylib extension

DART   ?= dart
GO     ?= go
STAGE0  = cd legacy && $(DART) run tool/stage0.dart

LIB_SRC  := $(wildcard slang/lib/*.slang)
COMPILER_SRC := $(wildcard slang/compiler/*.slang)
TEST_SRC := $(wildcard test/*.slang)

.PHONY: all seed fixpoint test build stage0-seed clean dungeon dungeon-test zig zig-test zig-fixpoint breakout

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

dungeon:
	cd examples/dungeon && $(GO) run ./host .

dungeon-test: build
	cd examples/dungeon && ../../bin/slang test test

zig:
	cd zig && zig build -Doptimize=ReleaseFast

# the suite under the checked build as well (zig/zig-out-safe)
zig-safe:
	cd zig && zig build -Doptimize=ReleaseSafe -p zig-out-safe

zig-test: zig zig-safe
	cd zig && zig build test
	zig/zig-out/bin/slang test test
	zig/zig-out/bin/slang test zig/test
	SLANG_NATIVE_PATH=zig/zig-out-safe/lib zig/zig-out-safe/bin/slang test test
	SLANG_NATIVE_PATH=zig/zig-out-safe/lib zig/zig-out-safe/bin/slang test zig/test

zig-fixpoint: zig
	@rm -rf /tmp/slang-zig-fixpoint && mkdir -p /tmp/slang-zig-fixpoint
	@for f in $(LIB_SRC) $(COMPILER_SRC); do \
	  n=$$(basename $$f .slang); \
	  zig/zig-out/bin/slang compile $$f -o /tmp/slang-zig-fixpoint/$$n.slb --origin slang/$$n || exit 1; \
	  cmp go/boot/slang/$$n.slb /tmp/slang-zig-fixpoint/$$n.slb || { echo "zig-fixpoint: $$n differs"; exit 1; }; \
	done
	@echo "zig-fixpoint: ok"

breakout: zig
	SLANG_NATIVE_PATH=zig/zig-out/lib zig/zig-out/bin/slang run examples/breakout/main.slang

clean:
	rm -f bin/slang
	rm -rf zig/zig-out zig/.zig-cache
