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
#   make bench        run bench/ (bench/run_all.sh adds the Lua ports and the C sawtooth)
#   make bench-vectors 3D vector math in every style: slang tables, methods, operators, a native
#                     (Zig) library, C through slang/ffi, buffers, a kernel (bench/vectors)
#   make raylib-test  run the raylib package's tests (packages/raylib; needs raylib installed)
#   make box2d-test   run the box2d package's tests (packages/box2d; needs Box2D 3 installed)
#   make jolt-test    run the jolt package's tests (packages/jolt; ships its own Jolt)
#   make midi-test    run the midi package's tests (packages/midi; no device needed)
#   make kernel-test  run the kernel package's tests (packages/kernel; ships its interpreter)
#   make kernel-bench kernels against plain slang (sawtooth, FM operator chain, filter)
#   make fm-gen       regenerate examples/fm/render.kernel from its algorithms
#   make physics      run the physics examples (examples/physics: Box2D and Jolt, drawn with raylib)
#   make breakout     run the breakout example (examples/breakout) on the raylib package
#   make deckhand     run the deckhand heist game (examples/deckhand) on the raylib package
#   make deckhand-test run deckhand's tests (no window: the deck, maps, world, every mission's solution)
#   make synth        run the synthesizer (examples/synth) on raylib/stream
#   make synth3d      the same synthesizer in 3D
#   make synth-test   run the synthesizer's engine tests (no window, no audio device)
#   make fm           run the six-operator FM synthesizer (examples/fm) on the kernel and raylib packages
#   make fm3d         the same FM synthesizer in 3D, with a hardware panel (display, encoders, buttons)
#   make fm-test      run its tests (no window, no audio device: every patch of the bank)
#   make synth-mix    record every song of examples/synth part by part and mix it (WAVs in examples/synth/mixdown)
#   make modular      run the pixel-art modular synthesizer (examples/modular) on the kernel and raylib packages
#   make modular-test run its tests (no window, no audio device: the rack, the kernel's modules, every patch)
#   make modular-demos rewrite the patches that come with it (examples/modular/patches)
#   make live         run the live coding environment for music and visuals (examples/live)
#   make live-test    run its tests (no window, no audio device: the notation, the engine, every piece)
#   make delve        run the Delve roguelike (examples/delve) on the raylib package
#   make delve-test   run delve's tests (no window: sight, maps, rules, the autoplayer)
#   make courier      run Courier, the flying-car delivery game (examples/courier) on raylib and jolt
#   make courier-test run its tests (no window: the city, the car on Jolt, the traffic, the jobs)
#   make siege        run the siege catapult game (examples/siege) on the raylib and jolt packages
#   make inkblast     run the Inkblast party game (examples/inkblast): slang/net, bots, raylib
#   make inkblast-test run Inkblast's tests (no window: the rules, a match over loopback)
#   make siege-test   run siege's tests (no window: structures stand, levels stand still, wrecking)
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

.PHONY: all build wasm wasm-gfx website serve build-safe install uninstall test test-safe test-gui unit seed fixpoint bench bench-vectors raylib-test box2d-test jolt-test physics breakout deckhand deckhand-test inkblast inkblast-test synth synth3d synth-test synth-mix modular modular-test modular-demos live live-test delve delve-test courier courier-test siege siege-test midi-test kernel-test kernel-bench fm fm3d fm-test fm-gen clean doc \
        vscode vscode-grammar

all: build

# bin/slang and lib/*.dylib (the install prefix is the repository root)
build:
	cd zig && $(ZIG) build -Doptimize=ReleaseFast -p ..

# the VM as WebAssembly (WASI), for the playground: website/slang.wasm
wasm:
	cd zig && $(ZIG) build -Dtarget=wasm32-wasi -Dffi=false -Doptimize=ReleaseSmall -p zig-out-wasm
	mkdir -p website/public && cp zig/zig-out-wasm/bin/slang.wasm website/public/slang.wasm

# the playground's graphics VM (slang with raylib, built with Emscripten):
# website/public/slang-gfx.js and .wasm; needs emcc (brew install emscripten)
wasm-gfx: build
	ZIG=$(ZIG) website/web/build.sh

# the website (website/out): home, tour, playground and API docs; the
# playground needs make wasm first
website: build
	bin/slang run website/build.slang

# the built website at http://127.0.0.1:8080 (PORT=...), served by slang
serve: website
	bin/slang run website/serve.slang $(or $(PORT),8080)

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
	@if [ -n "$(BOX2D_H)" ]; then $(MAKE) box2d-test; \
	  else echo "Box2D is not installed: packages/box2d not tested"; fi
	@if [ -n "$(RAYLIB_H)" ]; then $(MAKE) synth-test; fi
	@if [ -d "packages/jolt/lib/$(SLANG_PLATFORM)" ]; then $(MAKE) jolt-test && $(MAKE) siege-test && $(MAKE) courier-test; \
	  else echo "no joltc for $(SLANG_PLATFORM): packages/jolt and examples/siege not tested"; fi
	$(MAKE) midi-test
	$(MAKE) inkblast-test
	@if [ -d "packages/kernel/lib/$(SLANG_PLATFORM)" ]; then $(MAKE) kernel-test && $(MAKE) fm-test && $(MAKE) modular-test && $(MAKE) live-test; \
	  else echo "no kernel/vm for $(SLANG_PLATFORM): packages/kernel, examples/fm, examples/modular and examples/live not tested"; fi

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
	bin/slang run slang/seed_parsers.slang $(SEED_DIR)/pegc_root.slb
	cd zig && $(ZIG) build -Doptimize=ReleaseFast -p ..

# the seed must reproduce itself exactly
fixpoint: build
	@rm -rf /tmp/slang-fixpoint && mkdir -p /tmp/slang-fixpoint
	@for f in $(LIB_SRC) $(COMPILER_SRC); do \
	  n=$$(basename $$f .slang); \
	  bin/slang compile $$f -o /tmp/slang-fixpoint/$$n.slb --origin slang/$$n || exit 1; \
	  cmp $(SEED_DIR)/$$n.slb /tmp/slang-fixpoint/$$n.slb || { echo "fixpoint: $$n differs"; exit 1; }; \
	done
	@bin/slang run slang/seed_parsers.slang /tmp/slang-fixpoint/pegc_root.slb > /dev/null || exit 1
	@cmp $(SEED_DIR)/pegc_root.slb /tmp/slang-fixpoint/pegc_root.slb || { echo "fixpoint: root parsers differ"; exit 1; }
	@echo "fixpoint: ok"

bench: build
	@for b in bench/fib bench/dijkstra bench/tables bench/strings bench/compile bench/micro bench/audio; do bin/slang run $$b.slang; done

# the raylib package calls the installed raylib through slang/ffi
RAYLIB_H := $(firstword $(wildcard $(RAYLIB_PREFIX)/include/raylib.h /opt/homebrew/include/raylib.h /usr/local/include/raylib.h /usr/include/raylib.h))

raylib-test: build
	cd packages/raylib && ../../bin/slang test test

# the box2d package calls the installed Box2D; jolt ships joltc per platform
BOX2D_H := $(firstword $(wildcard $(BOX2D_PREFIX)/include/box2d/box2d.h /opt/homebrew/include/box2d/box2d.h /opt/homebrew/opt/box2d/include/box2d/box2d.h /usr/local/include/box2d/box2d.h /usr/include/box2d/box2d.h))
SLANG_PLATFORM := $(shell uname -s | sed 's/Darwin/macos/;s/Linux/linux/')-$(shell uname -m | sed 's/arm64/aarch64/')

box2d-test: build
	cd packages/box2d && ../../bin/slang test test

jolt-test: build
	cd packages/jolt && ../../bin/slang test test

midi-test: build
	cd packages/midi && ../../bin/slang test test

# the kernel package ships its interpreter per platform (packages/kernel/tool/build.sh)
kernel-test: build
	cd packages/kernel && ../../bin/slang test test

# the native libraries (a Zig extension, a C library) go to build/bench,
# not lib/: they are the benchmark's, never installed
bench-vectors: build
	cd zig && $(ZIG) build bench-libs -Doptimize=ReleaseFast -p ..
	cd bench/vectors && ../../bin/slang run main.slang

kernel-bench: build
	cd packages/kernel && ../../bin/slang run bench/bench.slang

physics: build
	cd examples/physics && ../../bin/slang run boxes.slang && ../../bin/slang run tower.slang

breakout: build
	bin/slang run examples/breakout/main.slang

deckhand: build
	bin/slang run examples/deckhand/main.slang

deckhand-test: build
	cd examples/deckhand && ../../bin/slang test test

inkblast: build
	cd examples/inkblast && ../../bin/slang run main.slang

inkblast-test: build
	cd examples/inkblast && ../../bin/slang test test

synth: build
	cd examples/synth && ../../bin/slang run main.slang

synth3d: build
	cd examples/synth && ../../bin/slang run main3d.slang

synth-test: build
	cd examples/synth && ../../bin/slang test test

fm: build
	cd examples/fm && ../../bin/slang run main.slang

fm3d: build
	cd examples/fm && ../../bin/slang run main3d.slang

fm-test: build
	cd examples/fm && ../../bin/slang test test

# regenerate examples/fm/render.kernel (one render kernel per algorithm)
fm-gen: build
	cd examples/fm && ../../bin/slang run tool/gen_render.slang

synth-mix: build
	cd examples/synth && for s in songs/*.slang; do ../../bin/slang run mixdown.slang $$s || exit 1; done

modular: build
	cd examples/modular && ../../bin/slang run main.slang

modular-test: build
	cd examples/modular && ../../bin/slang test test

modular-demos: build
	cd examples/modular && ../../bin/slang run tool/demos.slang

live: build
	cd examples/live && ../../bin/slang run main.slang pieces/first.slang

live-test: build
	cd examples/live && ../../bin/slang test test

delve: build
	bin/slang run examples/delve/main.slang

delve-test: build
	cd examples/delve && ../../bin/slang test test

courier: build
	bin/slang run examples/courier/main.slang

courier-test: build
	cd examples/courier && ../../bin/slang test test

siege: build
	bin/slang run examples/siege/main.slang

siege-test: build
	cd examples/siege && ../../bin/slang test test

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
