# Build pipeline for slang. The implementation is the Zig VM in zig/; the
# compiler and libraries are written in slang and boot from the seed
# bytecode in boot/slang.
#
#   make build        build bin/slang (ReleaseFast) and lib/ (native extensions)
#   make test         run the slang test suite, the native extension tests and the Zig unit tests
#   make test-safe    the suites on the checked build (ReleaseSafe) and under GC stress
#   make seed         re-generate the seed with bin/slang itself (self-hosting), then rebuild
#   make fixpoint     check that the seed compiles itself to identical bytecode
#   make bench        run bench/
#   make breakout     run the breakout example (examples/breakout) on the raylib extension
#   make dungeon-test run the dungeon example's DSL tests
#   make dungeon      run the dungeon example on its Go/Ebitengine host (legacy host, uses the Go VM)
#   make vscode       package the VS Code extension (editors/vscode) with the language server
#
# Legacy implementations, kept for reference: the Go VM (go/, the reference
# implementation during the port; `make go-build`, `make go-test`,
# `make go-fixpoint`) and the original Dart one (legacy/, `make stage0-seed`).

ZIG    ?= zig
GO     ?= go
DART   ?= dart
STAGE0  = cd legacy && $(DART) run tool/stage0.dart

LIB_SRC  := $(wildcard slang/lib/*.slang)
COMPILER_SRC := $(wildcard slang/compiler/*.slang)
SEED_DIR := boot/slang

.PHONY: all build build-safe test test-safe unit seed fixpoint bench breakout dungeon dungeon-test clean \
        vscode vscode-grammar go-build go-seed-copy go-test go-fixpoint stage0-seed

all: build

# bin/slang and lib/*.dylib (the install prefix is the repository root)
build:
	cd zig && $(ZIG) build -Doptimize=ReleaseFast -p ..

build-safe:
	cd zig && $(ZIG) build -Doptimize=ReleaseSafe -p zig-out-safe
	cd zig && $(ZIG) build -Doptimize=ReleaseSafe -Dgc-stress=true -p zig-out-stress

unit:
	cd zig && $(ZIG) build test

test: build unit
	bin/slang test test
	bin/slang test zig/test

test-safe: build-safe
	zig/zig-out-safe/bin/slang test test
	zig/zig-out-safe/bin/slang test zig/test
	zig/zig-out-stress/bin/slang test test
	zig/zig-out-stress/bin/slang test zig/test

# self-hosted seed: compile every library/compiler source with the current
# binary, then rebuild so that the binary embeds the new seed
seed: build
	@for f in $(LIB_SRC) $(COMPILER_SRC); do \
	  n=$$(basename $$f .slang); \
	  bin/slang compile $$f -o $(SEED_DIR)/$$n.slb --origin slang/$$n || exit 1; \
	  echo "seed: $$f -> $(SEED_DIR)/$$n.slb"; \
	done
	cd zig && $(ZIG) build -Doptimize=ReleaseFast -p ..

# the seed must reproduce itself exactly
fixpoint: build
	@rm -rf /tmp/slang-fixpoint && mkdir -p /tmp/slang-fixpoint
	@for f in $(LIB_SRC) $(COMPILER_SRC); do \
	  n=$$(basename $$f .slang); \
	  bin/slang compile $$f -o /tmp/slang-fixpoint/$$n.slb --origin slang/$$n || exit 1; \
	  cmp $(SEED_DIR)/$$n.slb /tmp/slang-fixpoint/$$n.slb || { echo "fixpoint: $$n differs"; exit 1; }; \
	done
	@echo "fixpoint: ok"

bench: build
	@for b in bench/fib bench/dijkstra bench/tables bench/strings bench/compile; do bin/slang run $$b.slang; done

breakout: build
	bin/slang run examples/breakout/main.slang

dungeon-test: build
	cd examples/dungeon && ../../bin/slang test test

dungeon: go-seed-copy
	cd examples/dungeon && $(GO) run ./host .

# the VS Code extension (editors/vscode): generated grammar, bundled lsp/, .vsix
vscode-grammar: build
	bin/slang run editors/vscode/gen_grammar.slang > editors/vscode/syntaxes/slang.tmLanguage.json

vscode: vscode-grammar
	cd editors/vscode && npm install --no-audit --no-fund && npm run package

clean:
	rm -rf bin lib zig/zig-out zig/zig-out-* zig/.zig-cache go/bin go/boot/slang editors/vscode/out editors/vscode/lsp editors/vscode/*.vsix

# ------------------------------------------------------------ legacy: Go VM

# Go's embed cannot leave its module: the seed is copied into go/boot/slang
go-seed-copy:
	@mkdir -p go/boot/slang && cp $(SEED_DIR)/*.slb go/boot/slang/

go-build: go-seed-copy
	cd go && $(GO) build -o bin/slang ./cmd/slang

go-test: go-build
	go/bin/slang test test

go-fixpoint: go-build
	@rm -rf /tmp/slang-go-fixpoint && mkdir -p /tmp/slang-go-fixpoint
	@for f in $(LIB_SRC) $(COMPILER_SRC); do \
	  n=$$(basename $$f .slang); \
	  go/bin/slang compile $$f -o /tmp/slang-go-fixpoint/$$n.slb --origin slang/$$n || exit 1; \
	  cmp $(SEED_DIR)/$$n.slb /tmp/slang-go-fixpoint/$$n.slb || { echo "go-fixpoint: $$n differs"; exit 1; }; \
	done
	@echo "go-fixpoint: ok"

# ------------------------------------------------------------ legacy: Dart

stage0-seed: $(LIB_SRC) $(COMPILER_SRC)
	$(STAGE0) --out ../go/boot --strip ../slang/lib/ --prefix slang/ $(addprefix ../,$(LIB_SRC))
	$(STAGE0) --out ../go/boot --strip ../slang/compiler/ --prefix slang/ $(addprefix ../,$(COMPILER_SRC))
