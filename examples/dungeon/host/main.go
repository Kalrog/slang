// Command dungeon runs a slang game on Ebitengine.
//
// The host is deliberately thin: it owns the window and the game loop, and
// exposes drawing, input and timing to slang as the module "ebiten". The game
// itself (main.slang and everything it requires) is written in slang.
//
//	go run . [game directory]       (default: the current directory)
//
// The game directory is added to the module search path and must contain
// main.slang, which defines the globals update(dt) and draw() and optionally
// init(). Environment variables for automation:
//
//	DUNGEON_FRAMES=n         quit after n frames
//	DUNGEON_SCREENSHOT=path  write the last frame as a PNG before quitting
//	DUNGEON_KEYS=k1,k2,...   simulate key presses, one every six frames
//	                         (a key name as in Ebitengine, or `-` for a pause)
package main

import (
	"bufio"
	"fmt"
	"image/png"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/hajimehoshi/ebiten/v2"

	"slang/boot"
	"slang/stdlib"
	"slang/vm"
)

type game struct {
	dir     string
	host    *host
	vm      *vm.VM
	out     *bufio.Writer
	update  vm.Value
	draw    vm.Value
	frames  int
	limit   int
	shot    string
	done    bool
	started bool
}

func main() {
	dir := "."
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		fail(err)
	}
	g := &game{dir: abs, host: newHost()}
	if s := os.Getenv("DUNGEON_FRAMES"); s != "" {
		g.limit, _ = strconv.Atoi(s)
	}
	g.shot = os.Getenv("DUNGEON_SCREENSHOT")
	if keys := os.Getenv("DUNGEON_KEYS"); keys != "" {
		g.host.script = strings.Split(keys, ",")
	}
	g.load()
	if err := ebiten.RunGame(g); err != nil && err != ebiten.Termination {
		fail(err)
	}
	g.out.Flush()
}

func fail(err error) {
	if e, ok := err.(*vm.Error); ok {
		fmt.Fprintf(os.Stderr, "error: %s\n", e.Message)
		if e.Loc != nil {
			fmt.Fprintf(os.Stderr, "  at %s\n", e.Loc)
		}
		if e.Trace != "" {
			fmt.Fprintln(os.Stderr, e.Trace)
		}
	} else {
		fmt.Fprintln(os.Stderr, "error:", err)
	}
	os.Exit(1)
}

// load creates a fresh VM, runs main.slang and looks up the loop callbacks.
// It is also used by the reload native, so that a running game can pick up
// changed scripts without restarting the window.
func (g *game) load() {
	if g.out != nil {
		g.out.Flush()
	}
	v := vm.New()
	v.Embedded = boot.FS
	g.out = bufio.NewWriterSize(os.Stdout, 1<<16)
	v.Stdout = g.out
	stdlib.Open(v)
	v.Packages.GetStr("searchPaths").AsTable().Append(vm.String(g.dir))
	stdlib.Preload(v, "ebiten", vm.TableValue(g.host.module(g)))
	if err := stdlib.Boot(v); err != nil {
		fail(err)
	}
	g.vm = v
	g.host.reset()

	compiler, err := v.Call(v.GetGlobal("require"), vm.String("slang/compiler"))
	if err != nil {
		fail(err)
	}
	mainPath := filepath.Join(g.dir, "main.slang")
	fn, err := v.Call(compiler.AsTable().GetStr("load_file"), vm.String(mainPath), vm.String("main"))
	if err != nil {
		fail(err)
	}
	if _, err := v.Call(fn); err != nil {
		fail(err)
	}
	g.update = v.GetGlobal("update")
	g.draw = v.GetGlobal("draw")
	if g.update.IsNull() || g.draw.IsNull() {
		fail(fmt.Errorf("%s must define update(dt) and draw()", mainPath))
	}
	if init := v.GetGlobal("init"); !init.IsNull() {
		if _, err := v.Call(init); err != nil {
			fail(err)
		}
	}
	g.out.Flush()
	g.started = true
}

func (g *game) Update() error {
	if g.done {
		return ebiten.Termination
	}
	if g.host.reloadRequested {
		g.host.reloadRequested = false
		g.load()
	}
	g.host.beginFrame()
	dt := 1.0 / float64(ebiten.TPS())
	if _, err := g.vm.Call(g.update, vm.Float(dt)); err != nil {
		g.out.Flush()
		fail(err)
	}
	g.out.Flush()
	g.frames++
	if g.host.quitRequested {
		g.done = true
	}
	return nil
}

func (g *game) Draw(screen *ebiten.Image) {
	canvas := g.host.canvasFor(screen)
	g.host.target = canvas
	if _, err := g.vm.Call(g.draw); err != nil {
		g.out.Flush()
		fail(err)
	}
	g.out.Flush()
	g.host.target = nil
	screen.DrawImage(canvas, nil)
	if g.limit > 0 && g.frames >= g.limit && !g.done {
		if g.shot != "" {
			g.screenshot(canvas)
		}
		g.done = true
	}
}

func (g *game) screenshot(canvas *ebiten.Image) {
	w, h := canvas.Bounds().Dx(), canvas.Bounds().Dy()
	buf := make([]byte, 4*w*h)
	canvas.ReadPixels(buf)
	img := &rgbaImage{w: w, h: h, pix: buf}
	f, err := os.Create(g.shot)
	if err != nil {
		fail(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		fail(err)
	}
}

func (g *game) Layout(outsideWidth, outsideHeight int) (int, int) {
	return g.host.width * g.host.scale, g.host.height * g.host.scale
}
