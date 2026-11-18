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
#   make bench-compare the same programs in slang, Python, Lua, LuaJIT, node and Ruby
#                     (bench/compare; RUNS=n, LANGS="slang python ...", a list of benchmarks)
#   make bench-vectors 3D vector math in every style: slang tables, methods, operators, a native
#                     (Zig) library, C through slang/ffi, buffers, a kernel (bench/vectors)
#   make raylib-test  run the raylib package's tests (packages/raylib; needs raylib installed)
#   make box2d-test   run the box2d package's tests (packages/box2d; needs Box2D 3 installed)
#   make jolt-test    run the jolt package's tests (packages/jolt; ships its own Jolt)
#   make midi-test    run the midi package's tests (packages/midi; no device needed)
#   make microphone-test run the microphone package's tests (packages/microphone; no device needed)
#   make kernel-test  run the kernel package's tests (packages/kernel; ships its interpreter)
#   make notebook-test run the notebook packages' tests (packages/notebook, packages/notebook_server: the format, a kernel, the server; no browser needed. With make wasm done and node installed, also slang.wasm as a notebook's kernel)
#   make notebook     serve the notebooks of packages/notebook/examples to the browser (slang notebook-server)
#   make studio-test  run the studio package's tests (packages/studio: instruments, effects, the mixer, sequences; no sound card needed)
#   make studio-demo  render the studio's demo piece to packages/studio/demo.wav and say how much of a core it takes
#   make window-test  run the window package's tests (packages/window; ships SDL3, opens hidden windows)
#   make gpu-test     run the gpu package's tests (packages/gpu; ships wgpu-native, no window needed)
#   make gpu          run the gpu examples in windows (examples/gpu: triangle, cube, waves)
#   make gpu-web-test run the gpu package's tests and the gpu examples in a browser (the graphics VM of make wasm-gfx, in headless Chrome; needs node)
#   make swarm        a million GPU particles with sound (examples/swarm, on the gpu and window packages)
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
#   make tracker      run the tracker (examples/tracker): songs as patterns of rows, on the studio and raylib packages
#   make tracker-test run its tests (no window, no sound card: the song, the player, the grid, the songs that come with it)
#   make tracker-demos rewrite the songs that come with it (examples/tracker/songs)
#   make dsp          play the block-diagram instruments (examples/dsp, on packages/dsp: a Faust-like language compiled to kernels)
#   make car          drive the four-cylinder engine of examples/dsp (programs/inline4.dsp)
#   make dsp-test     run the dsp package's tests and the example's (no window, no audio device: the language, the generated kernels, the engine)
#   make granular     play the granular synthesizer (examples/granular): grains of a microphone recording, on kernels
#   make granular-test run its tests (no window, no audio device: WAV files, the engine, recording through a virtual microphone)
#   make delve        run the Delve roguelike (examples/delve) on the raylib package
#   make delve-test   run delve's tests (no window: sight, maps, rules, the autoplayer)
#   make courier      run Courier, the flying-car delivery game (examples/courier) on raylib and jolt
#   make courier-test run its tests (no window: the city, the car on Jolt, the traffic, the jobs)
#   make switchback   run Switchback, the off-road drive up a valley made from a seed (examples/switchback) on raylib, jolt, kernel and dsp
#   make switchback-test run its tests (no window, no audio device: the drivetrain, the truck on Jolt, the land, the trails, the bot, exploring, a run, the sound)
#   make switchback-web  Switchback in the browser: a site of its own in examples/switchback/web (the graphics VM, built by wasm-gfx, and the game's files)
#   make switchback-web-serve  the same, served at http://127.0.0.1:8080/ (no daily run)
#   make switchback-daily switchback-release  the daily run: the site and everyone's times of the day (examples/switchback/server, times in examples/switchback/daily.db) at http://127.0.0.1:8080/
#   make switchback-release  refresh the deploy repo of the daily run (DEST=../vps/switchback): the site, the server, slang's source
#   make switchback-sound SCENE=engine  render a part of its sound to a WAV and play it (examples/switchback/tool/sound.slang; ARGS="..." for the scene, e.g. SCENE=drive ARGS="25 300 40 heavy")
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
# the grammar extensions the binary carries: those of libraries it carries
# (slang/async, slang/html, slang/test, slang/json, slang/sqlite); the list
# is also in zig/build.zig (seedModule)
EXT_SRC  := extensions/async.slang extensions/html.slang extensions/inline_test.slang extensions/json.slang extensions/sqlite.slang
EXT_SEED_DIR := boot/extensions

.PHONY: all build wasm wasm-gfx website serve build-safe install uninstall test test-safe test-gui unit seed fixpoint bench bench-compare bench-vectors raylib-test box2d-test jolt-test physics breakout deckhand deckhand-test inkblast inkblast-test synth synth3d synth-test synth-mix modular modular-test modular-demos live live-test tracker tracker-test tracker-demos dsp car dsp-test granular granular-test delve delve-test courier courier-test switchback switchback-test switchback-web switchback-web-serve switchback-daily switchback-sound siege siege-test midi-test microphone-test notebook-test notebook studio-test studio-demo window-test gpu-test gpu gpu-web-test swarm kernel-test kernel-bench fm fm3d fm-test fm-gen clean doc \
        vscode vscode-grammar

all: build

# bin/slang and lib/*.dylib (the install prefix is the repository root)
build:
	cd zig && $(ZIG) build -Doptimize=ReleaseFast -p ..

# the VM as WebAssembly (WASI): website/public/slang.wasm for the
# playground, lib/slang.wasm for notebooks that run in the browser (the
# notebook package finds it there, and make install takes it along)
wasm:
	cd zig && $(ZIG) build -Dtarget=wasm32-wasi -Dffi=false -Doptimize=ReleaseSmall -p zig-out-wasm
	mkdir -p website/public lib && cp zig/zig-out-wasm/bin/slang.wasm website/public/slang.wasm
	cp zig/zig-out-wasm/bin/slang.wasm lib/slang.wasm

# the playground's graphics VM (slang built with Emscripten, with raylib,
# Box2D, Jolt, WebGPU and SDL linked in, for the raylib, box2d, jolt, kernel,
# gpu and window packages): website/public/slang-gfx.js and .wasm; needs
# emcc (brew install emscripten)
wasm-gfx: build
	ZIG=$(ZIG) website/web/build.sh

# the website (website/out): home, tour, guides, playground, API docs and
# a notebook that runs in the page (the notebook package's tour, made by
# its export); the playground and the notebook need make wasm first
website: build
	bin/slang run website/build.slang
	@if [ -f website/public/slang.wasm ]; then mkdir -p website/out/notebook && \
	  (cd packages/notebook && ../../bin/slang exec notebook export --live --vm ../assets/slang.wasm --home ../ \
	    -o ../../website/out/notebook/index.html examples/tour.md); \
	  else echo "website: no public/slang.wasm (make wasm): no notebook page"; fi

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
	$(MAKE) microphone-test
	$(MAKE) notebook-test
	@if [ -d "packages/window/lib/$(SLANG_PLATFORM)" ]; then $(MAKE) window-test; \
	  else echo "no SDL3 for $(SLANG_PLATFORM): packages/window not tested"; fi
	@if [ -d "packages/gpu/lib/$(SLANG_PLATFORM)" ]; then $(MAKE) gpu-test; \
	  else echo "no wgpu-native for $(SLANG_PLATFORM): packages/gpu not tested"; fi
	$(MAKE) inkblast-test
	@if [ -d "packages/kernel/lib/$(SLANG_PLATFORM)" ]; then $(MAKE) kernel-test && $(MAKE) fm-test && $(MAKE) modular-test && $(MAKE) live-test && $(MAKE) dsp-test && $(MAKE) granular-test && $(MAKE) studio-test && $(MAKE) tracker-test; \
	  else echo "no kernel/vm for $(SLANG_PLATFORM): packages/kernel, packages/dsp, packages/studio, examples/fm, examples/modular, examples/live, examples/dsp, examples/granular and examples/tracker not tested"; fi
	@if [ -d "packages/kernel/lib/$(SLANG_PLATFORM)" ] && [ -d "packages/jolt/lib/$(SLANG_PLATFORM)" ]; then $(MAKE) switchback-test; \
	  else echo "no kernel/vm or no joltc for $(SLANG_PLATFORM): examples/switchback not tested"; fi

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
	@mkdir -p $(EXT_SEED_DIR)
	@for f in $(EXT_SRC); do \
	  n=$$(basename $$f .slang); \
	  bin/slang compile $$f -o $(EXT_SEED_DIR)/$$n.slb --origin extensions/$$n || exit 1; \
	  echo "seed: $$f -> $(EXT_SEED_DIR)/$$n.slb"; \
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
	@for f in $(EXT_SRC); do \
	  n=$$(basename $$f .slang); \
	  bin/slang compile $$f -o /tmp/slang-fixpoint/ext_$$n.slb --origin extensions/$$n || exit 1; \
	  cmp $(EXT_SEED_DIR)/$$n.slb /tmp/slang-fixpoint/ext_$$n.slb || { echo "fixpoint: extensions/$$n differs"; exit 1; }; \
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

microphone-test: build
	cd packages/microphone && ../../bin/slang test test

# the window package ships SDL3 per platform (packages/window/tool/build.sh)
window-test: build
	cd packages/window && ../../bin/slang test test

# the gpu package ships wgpu-native per platform (packages/gpu/tool/fetch.sh)
gpu-test: build
	cd packages/gpu && ../../bin/slang test test && ../../bin/slang run examples/compute.slang

gpu: build
	cd examples/gpu && ../../bin/slang run triangle.slang && ../../bin/slang run cube.slang && ../../bin/slang run waves.slang

# the gpu and window packages in a browser: the gpu package's tests and the
# gpu examples on the graphics VM (make wasm-gfx first), in headless Chrome
# on this machine's GPU
gpu-web-test:
	node website/web/test/gpu_web_test.mjs

swarm: build
	cd examples/swarm && ../../bin/slang run main.slang

# the kernel package ships its interpreter per platform (packages/kernel/tool/build.sh)
kernel-test: build
	cd packages/kernel && ../../bin/slang test test

# the native libraries (a Zig extension, a C library) go to build/bench,
# not lib/: they are the benchmark's, never installed
bench-compare: build
	bench/compare/run.sh $(BENCH)

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

tracker: build
	cd examples/tracker && ../../bin/slang run main.slang

tracker-test: build
	cd examples/tracker && ../../bin/slang test test

tracker-demos: build
	cd examples/tracker && ../../bin/slang run tool/demos.slang

dsp: build
	cd examples/dsp && ../../bin/slang run main.slang

car: build
	cd examples/dsp && ../../bin/slang run car.slang

dsp-test: build
	cd packages/dsp && ../../bin/slang test test
	cd examples/dsp && ../../bin/slang test test

notebook-test: build
	cd packages/notebook && ../../bin/slang test test
	cd packages/notebook_server && ../../bin/slang test test
	@cmp website/public/wasi.js packages/notebook/web/wasi.js || \
	  { echo "website/public/wasi.js and packages/notebook/web/wasi.js differ: they are one file, kept twice"; exit 1; }
	@if [ -f lib/slang.wasm ] && command -v node > /dev/null; then \
	  node packages/notebook/test/web_test.mjs lib/slang.wasm; \
	  else echo "no lib/slang.wasm (make wasm) or no node: notebooks in the browser not tested"; fi

notebook: build
	cd packages/notebook_server && ../../bin/slang exec notebook-server ../notebook/examples

studio-test: build
	cd packages/studio && ../../bin/slang test test

studio-demo: build
	cd packages/studio && ../../bin/slang run tool/demo.slang demo.wav

granular: build
	cd examples/granular && ../../bin/slang run main.slang

granular-test: build
	cd examples/granular && ../../bin/slang test test

delve: build
	bin/slang run examples/delve/main.slang

delve-test: build
	cd examples/delve && ../../bin/slang test test

courier: build
	bin/slang run examples/courier/main.slang

courier-test: build
	cd examples/courier && ../../bin/slang test test

switchback: build
	bin/slang run examples/switchback/main.slang

switchback-test: build
	cd examples/switchback && ../../bin/slang test test

# a site of its own (index.html, files.json, the graphics VM): any static
# server will do; no special headers are needed (no threads)
switchback-web: wasm-gfx
	bin/slang run website/web/game.slang examples/switchback examples/switchback/web Switchback

switchback-web-serve: switchback-web
	bin/slang run website/serve.slang 8080 examples/switchback/web

switchback-daily: switchback-web
	bin/slang run examples/switchback/server/main.slang 8080

DEST ?= ../vps/switchback
switchback-release: build
	examples/switchback/deploy/release.sh $(DEST)

# a scene of tool/scenes rendered to a WAV (no audio device needed), then
# played where there is a player for it
SCENE ?= engine
SOUND_OUT ?= /tmp/switchback-sound
switchback-sound: build
	@mkdir -p $(SOUND_OUT)
	cd examples/switchback && ../../bin/slang run tool/sound.slang $(SCENE) $(SOUND_OUT) $(ARGS)
	@if command -v afplay >/dev/null; then afplay $(SOUND_OUT)/$(SCENE).wav; else echo "written: $(SOUND_OUT)/$(SCENE).wav"; fi

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
