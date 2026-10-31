# Build pipeline for slang. The implementation is the Zig VM in zig/; the
# compiler and libraries are written in slang and boot from the seed
# bytecode in boot/slang.
#
#   make build        build bin/slang (ReleaseFast), lib/ (native extensions) and
#                     lib/static (the runtime and extensions as archives, for slang build)
#   make install      copy them to $(PREFIX)/bin/slang and $(PREFIX)/lib/slang/ (PREFIX=/usr/local); make uninstall
#   make test         run the slang test suite, the native extension tests and the Zig unit tests
#   make test-safe    the suites on the checked build (ReleaseSafe) and under GC stress
#   make test-gui     the webview tests (macOS; they open and close windows)
#   make seed         re-generate the seed with bin/slang itself (self-hosting), then rebuild
#   make fixpoint     check that the seed compiles itself to identical bytecode
#   make bench        run bench/
#   make raylib-test  run the raylib package's tests (packages/raylib; needs raylib installed)
#   make breakout     run the breakout example (examples/breakout) on the raylib package
#   make deckhand     run the deckhand heist game (examples/deckhand) on the raylib package
#   make deckhand-test run deckhand's tests (no window: the deck, maps, world, every mission's solution)
#   make vscode       package the VS Code extension (editors/vscode) with the language server
#   make doc          regenerate doc/: HTML documentation of slang's library (slang doc)
#
# The earlier implementations, the Go VM and the original Dart one (with the
# dungeon example, which ran on the Go VM), are on the branch `legacy`.

ZIG    ?= zig
PREFIX ?= /usr/local

LIB_SRC  := $(wildcard slang/lib/*.slang)
COMPILER_SRC := $(wildcard slang/compiler/*.slang)
SEED_DIR := boot/slang

.PHONY: all build wasm build-safe install uninstall test test-safe test-gui unit seed fixpoint bench raylib-test breakout deckhand deckhand-test clean doc \
        vscode vscode-grammar

all: build

# bin/slang and lib/*.dylib (the install prefix is the repository root)
build:
	cd zig && $(ZIG) build -Doptimize=ReleaseFast -p ..

# the VM as WebAssembly (WASI), for the playground: website/slang.wasm
wasm:
	cd zig && $(ZIG) build -Dtarget=wasm32-wasi -Dffi=false -Doptimize=ReleaseSmall -p zig-out-wasm
	mkdir -p website/public && cp zig/zig-out-wasm/bin/slang.wasm website/public/slang.wasm

build-safe:
	cd zig && $(ZIG) build -Doptimize=ReleaseSafe -p zig-out-safe
	cd zig && $(ZIG) build -Doptimize=ReleaseSafe -Dgc-stress=true -p zig-out-stress

# the binary looks for native extensions in <prefix>/lib/slang next to its bin/
install: build
	install -d $(PREFIX)/bin $(PREFIX)/lib/slang
	install -m 755 bin/slang $(PREFIX)/bin/slang
	install -m 644 $$(find lib -maxdepth 1 -type f) $(PREFIX)/lib/slang/
	install -d $(PREFIX)/lib/slang/static
	install -m 644 lib/static/* $(PREFIX)/lib/slang/static/
	install -d $(PREFIX)/lib/slang/src
	install -m 644 $(LIB_SRC) $(COMPILER_SRC) $(PREFIX)/lib/slang/src/
	install -d $(PREFIX)/lib/slang/stubs
	cp -R slang/stubs/. $(PREFIX)/lib/slang/stubs/
	install -d $(PREFIX)/include
	install -m 644 zig/include/slang.h $(PREFIX)/include/slang.h
	@echo "installed $(PREFIX)/bin/slang and $$(find lib -maxdepth 1 -type f | wc -l | tr -d ' ') extensions in $(PREFIX)/lib/slang"

uninstall:
	rm -f $(PREFIX)/bin/slang
	rm -rf $(PREFIX)/lib/slang
	rm -f $(PREFIX)/include/slang.h

unit:
	cd zig && $(ZIG) build test

test: build unit
	bin/slang test test
	bin/slang test zig/test
	@if [ -n "$(RAYLIB_H)" ]; then $(MAKE) raylib-test; \
	  else echo "raylib is not installed: packages/raylib not tested"; fi

test-gui: build
	bin/slang test zig/test/gui

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

# the raylib package calls the installed raylib through slang/ffi
RAYLIB_H := $(firstword $(wildcard $(RAYLIB_PREFIX)/include/raylib.h /opt/homebrew/include/raylib.h /usr/local/include/raylib.h /usr/include/raylib.h))

raylib-test: build
	cd packages/raylib && ../../bin/slang test test

breakout: build
	bin/slang run examples/breakout/main.slang

deckhand: build
	bin/slang run examples/deckhand/main.slang

deckhand-test: build
	cd examples/deckhand && ../../bin/slang test test

# the VS Code extension (editors/vscode): generated grammar, bundled lsp/, .vsix
vscode-grammar: build
	bin/slang run editors/vscode/gen_grammar.slang > editors/vscode/syntaxes/slang.tmLanguage.json

# the library's documentation, from its doc comments; doc/ is kept in the
# repository, so regenerate it when the library changes
doc: build
	rm -rf doc
	bin/slang doc -o doc

vscode: vscode-grammar
	cd editors/vscode && npm install --no-audit --no-fund && npm run package

clean:
	rm -rf bin lib zig/zig-out zig/zig-out-* zig/.zig-cache editors/vscode/out editors/vscode/lsp editors/vscode/*.vsix
