package main

import (
	"bytes"
	"image"
	"image/color"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hajimehoshi/ebiten/v2"
	"github.com/hajimehoshi/ebiten/v2/inpututil"
	"github.com/hajimehoshi/ebiten/v2/text/v2"
	"github.com/hajimehoshi/ebiten/v2/vector"
	"golang.org/x/image/font/gofont/goregular"

	"slang/vm"
)

// host holds the window state and implements the natives of the ebiten module.
// Coordinates passed from slang are logical pixels; everything is drawn at
// logical size times scale, so pixel art stays crisp and text is rendered at
// the real resolution.
type host struct {
	width, height, scale int
	target               *ebiten.Image // the canvas while draw() runs
	canvas               *ebiten.Image
	start                time.Time
	fontSource           *text.GoTextFaceSource
	faces                map[int]*text.GoTextFace
	quitRequested        bool
	reloadRequested      bool
	keys                 map[string]ebiten.Key
	game                 *game
	script               []string // simulated key presses (DUNGEON_KEYS)
	frame                int
	simulated            string // the key simulated this frame, if any
}

func newHost() *host {
	src, err := text.NewGoTextFaceSource(bytes.NewReader(goregular.TTF))
	if err != nil {
		fail(err)
	}
	return &host{
		width: 320, height: 192, scale: 3,
		start:      time.Now(),
		fontSource: src,
		faces:      map[int]*text.GoTextFace{},
		keys:       map[string]ebiten.Key{},
	}
}

func (h *host) reset() {
	h.quitRequested = false
}

func (h *host) beginFrame() {
	h.simulated = ""
	if len(h.script) > 0 && h.frame%6 == 0 {
		i := h.frame / 6
		if i < len(h.script) && h.script[i] != "-" {
			h.simulated = h.script[i]
		}
	}
	h.frame++
}

func (h *host) simulatedKey(name string) bool {
	return h.simulated != "" && strings.EqualFold(h.simulated, name)
}

func (h *host) canvasFor(screen *ebiten.Image) *ebiten.Image {
	w, h2 := h.width*h.scale, h.height*h.scale
	if h.canvas == nil || h.canvas.Bounds().Dx() != w || h.canvas.Bounds().Dy() != h2 {
		h.canvas = ebiten.NewImage(w, h2)
	}
	h.canvas.Clear()
	return h.canvas
}

func (h *host) face(size int) *text.GoTextFace {
	if f, ok := h.faces[size]; ok {
		return f
	}
	f := &text.GoTextFace{Source: h.fontSource, Size: float64(size * h.scale)}
	h.faces[size] = f
	return f
}

func (h *host) key(name string) (ebiten.Key, bool) {
	if k, ok := h.keys[name]; ok {
		return k, true
	}
	var k ebiten.Key
	candidates := []string{name, strings.ToUpper(name[:1]) + name[1:]}
	for _, c := range candidates {
		if err := k.UnmarshalText([]byte(c)); err == nil {
			h.keys[name] = k
			return k, true
		}
	}
	return 0, false
}

func unpackColor(v vm.Value) color.RGBA {
	n := uint32(v.AsInt())
	return color.RGBA{R: uint8(n >> 24), G: uint8(n >> 16), B: uint8(n >> 8), A: uint8(n)}
}

func (h *host) needTarget(name string) (*ebiten.Image, error) {
	if h.target == nil {
		return nil, vm.Errorf("ebiten.%s can only be called from draw()", name)
	}
	return h.target, nil
}

func (h *host) module(g *game) *vm.Table {
	h.game = g
	fs := float64(h.scale)
	natives := map[string]vm.NativeFunc{
		// window(title, width, height, scale): the logical size and the pixel scale
		"window": func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
			title, err := vm.ArgString(args, 0, "title")
			if err != nil {
				return vm.Null, err
			}
			h.width = int(vm.ArgIntOr(args, 1, int64(h.width)))
			h.height = int(vm.ArgIntOr(args, 2, int64(h.height)))
			h.scale = int(vm.ArgIntOr(args, 3, int64(h.scale)))
			if h.scale < 1 {
				h.scale = 1
			}
			fs = float64(h.scale)
			h.faces = map[int]*text.GoTextFace{}
			ebiten.SetWindowTitle(title)
			ebiten.SetWindowSize(h.width*h.scale, h.height*h.scale)
			return vm.Null, nil
		},
		// image(width, height, pixels): an image from a string of RGBA bytes
		"image": func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
			w, err := vm.ArgInt(args, 0, "width")
			if err != nil {
				return vm.Null, err
			}
			ht, err := vm.ArgInt(args, 1, "height")
			if err != nil {
				return vm.Null, err
			}
			pix, err := vm.ArgString(args, 2, "pixels")
			if err != nil {
				return vm.Null, err
			}
			if int64(len(pix)) != 4*w*ht {
				return vm.Null, vm.Errorf("image: expected %d bytes of pixels for %dx%d, got %d", 4*w*ht, w, ht, len(pix))
			}
			img := ebiten.NewImage(int(w), int(ht))
			img.WritePixels([]byte(pix))
			return vm.UserdataValue(vm.NewUserdata(img, nil)), nil
		},
		// draw(image, x, y [, flip_x, alpha, scale]): draws an image at logical coordinates
		"draw": func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
			dst, err := h.needTarget("draw")
			if err != nil {
				return vm.Null, err
			}
			img, err := vm.ArgUserdata[*ebiten.Image](args, 0, "image")
			if err != nil {
				return vm.Null, err
			}
			x, y := vm.ArgNumberOr(args, 1, 0), vm.ArgNumberOr(args, 2, 0)
			flip := vm.ArgBool(args, 3, false)
			alpha := vm.ArgNumberOr(args, 4, 1)
			extra := vm.ArgNumberOr(args, 5, 1)
			op := &ebiten.DrawImageOptions{}
			if flip {
				op.GeoM.Scale(-1, 1)
				op.GeoM.Translate(float64(img.Bounds().Dx()), 0)
			}
			op.GeoM.Scale(fs*extra, fs*extra)
			op.GeoM.Translate(math.Round(x*fs), math.Round(y*fs))
			if alpha < 1 {
				op.ColorScale.ScaleAlpha(float32(alpha))
			}
			dst.DrawImage(img, op)
			return vm.Null, nil
		},
		// rect(x, y, width, height, color): a filled rectangle
		"rect": func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
			dst, err := h.needTarget("rect")
			if err != nil {
				return vm.Null, err
			}
			x, y := vm.ArgNumberOr(args, 0, 0), vm.ArgNumberOr(args, 1, 0)
			w, ht := vm.ArgNumberOr(args, 2, 0), vm.ArgNumberOr(args, 3, 0)
			vector.FillRect(dst, float32(x*fs), float32(y*fs), float32(w*fs), float32(ht*fs), unpackColor(vm.Arg(args, 4)), false)
			return vm.Null, nil
		},
		// text(string, x, y, size, color): draws text; size is in logical pixels
		"text": func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
			dst, err := h.needTarget("text")
			if err != nil {
				return vm.Null, err
			}
			s, err := vm.ArgString(args, 0, "text")
			if err != nil {
				return vm.Null, err
			}
			x, y := vm.ArgNumberOr(args, 1, 0), vm.ArgNumberOr(args, 2, 0)
			size := int(vm.ArgIntOr(args, 3, 8))
			op := &text.DrawOptions{}
			op.GeoM.Translate(math.Round(x*fs), math.Round(y*fs))
			op.ColorScale.ScaleWithColor(unpackColor(vm.Arg(args, 4)))
			text.Draw(dst, s, h.face(size), op)
			return vm.Null, nil
		},
		// text_width(string, size): the width of the text in logical pixels
		"text_width": func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
			s, err := vm.ArgString(args, 0, "text")
			if err != nil {
				return vm.Null, err
			}
			size := int(vm.ArgIntOr(args, 1, 8))
			w, _ := text.Measure(s, h.face(size), 0)
			return vm.Float(w / fs), nil
		},
		// key_down(name): whether a key is held (names as in Ebitengine: ArrowLeft, A, Space, Enter, Escape, ...)
		"key_down": func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
			name, err := vm.ArgString(args, 0, "key")
			if err != nil {
				return vm.Null, err
			}
			k, ok := h.key(name)
			if !ok {
				return vm.Null, vm.Errorf("unknown key %q", name)
			}
			return vm.Bool(ebiten.IsKeyPressed(k) || h.simulatedKey(name)), nil
		},
		// key_pressed(name): whether a key went down this frame
		"key_pressed": func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
			name, err := vm.ArgString(args, 0, "key")
			if err != nil {
				return vm.Null, err
			}
			k, ok := h.key(name)
			if !ok {
				return vm.Null, vm.Errorf("unknown key %q", name)
			}
			return vm.Bool(inpututil.IsKeyJustPressed(k) || h.simulatedKey(name)), nil
		},
		// clock(): seconds since the program started
		"clock": func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
			return vm.Float(time.Since(h.start).Seconds()), nil
		},
		// quit(): ends the game after the current frame
		"quit": func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
			h.quitRequested = true
			return vm.Null, nil
		},
		// reload(): restarts the scripts in a fresh VM before the next frame
		"reload": func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
			h.reloadRequested = true
			return vm.Null, nil
		},
		// mtime(path): modification time of a file in seconds, or null
		"mtime": func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
			p, err := vm.ArgString(args, 0, "path")
			if err != nil {
				return vm.Null, err
			}
			if !filepath.IsAbs(p) {
				p = filepath.Join(h.game.dir, p)
			}
			st, err := os.Stat(p)
			if err != nil {
				return vm.Null, nil
			}
			return vm.Float(float64(st.ModTime().UnixNano()) / 1e9), nil
		},
	}
	t := vm.NewTable(0, len(natives))
	for name, fn := range natives {
		t.SetStr(name, vm.FunctionValue(vm.NewNative(name, fn)))
	}
	return t
}

// rgbaImage adapts a raw RGBA buffer to image.Image for png.Encode.
type rgbaImage struct {
	w, h int
	pix  []byte
}

func (m *rgbaImage) ColorModel() color.Model { return color.RGBAModel }
func (m *rgbaImage) Bounds() image.Rectangle { return image.Rect(0, 0, m.w, m.h) }
func (m *rgbaImage) At(x, y int) color.Color {
	i := 4 * (y*m.w + x)
	return color.RGBA{m.pix[i], m.pix[i+1], m.pix[i+2], m.pix[i+3]}
}
