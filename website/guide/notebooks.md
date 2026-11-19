# Notebooks

A notebook is text and code that runs: you write a cell, run it, and see
what it gives under it, with the cells before it still in effect. Slang's
notebooks are two packages kept with slang, not a part of the language:
`notebook` (the file format, the kernel that runs the cells, a command
line) and `notebook_server` (the page in the browser).

```sh
slang install packages/notebook_server   # once: the executable notebook-server
slang install packages/notebook          # once: the executable notebook
slang notebook-server                    # the notebooks of this folder, in the browser
slang notebook run notes.md              # or run one in the terminal
```

[Projects and packages](projects.md) explains `slang install` and
executables. The site's [Notebook](../notebook/) page is a notebook to try
without installing anything: slang runs inside the page.

## A notebook is a Markdown file

Any Markdown file is a notebook. Its fenced code blocks labelled `slang`
are the code cells, and the text between them the text cells; blocks in
other languages belong to the text. So a notebook reads as a document
wherever Markdown does, diffs like text, and the guides of this
documentation open as notebooks. `slang notebook new notes.md` writes one
to start from.

What the cells showed is not in the notebook. It is kept next to it, in
the sidecar: `notes.md` has `notes.out.json`. Opening the notebook shows
the last results without running anything. Outputs belong to a cell by a
hash of its code, so they follow cells that move and are dropped for a
cell that changed. Commit the sidecars or ignore them (`*.out.json`), as
the project likes.

## Cells

The cells of a notebook run in one session, as pieces of one program:

```slang
local samples = {}
for(local i = 0; i < 100; i = i + 1){
  append(samples, i * i)
}
len(samples)
```

- A cell's top-level locals stay for the cells after it. Functions see
  the same variable the next cell assigns, as in a file.
- A cell that ends in an expression or a call shows its value. `null`
  shows nothing.
- What a cell prints is shown as it is printed, C code's output included.
- An error shows its kind, its message and its place: the line in the
  cell, and the line of the notebook's file in the trace.
- A cell may `await` (see [Async and the web](async.md)). What it starts
  and leaves running, a timer or a server, runs on between the cells.

The same session is in `slang repl`: it keeps locals between lines and
shows the value a line ends in.

Cells run in the project of the notebook's folder: its `slang.project`
gives them its packages, its search paths and its extensions, so a
notebook in a project uses the project's code with the project's syntax.
A notebook outside any project is plain slang.

## Showing more than text

A value that is a table is shown as a tree to unfold. For more, the module
`notebook` makes things to show; a cell shows the one it ends in, and
`display` shows them from anywhere in a cell.

```slang
local nb = require("notebook")
local math = require("slang/math")

local wave = {}
for(local i = 0; i < 8000; i = i + 1){
  append(wave, math.sin(i * 0.05) * math.exp(-i / 3000))
}
nb.display(nb.plot(wave, {title: "A plucked note"}), nb.audio(wave, {rate: 8000}))
nb.table({{name: "peak", value: 1.0}, {name: "length", value: len(wave)}})
```

| function | shows |
|---|---|
| `nb.plot(data, options)` | a chart of numbers: lines, points or bars; long lists as their envelope |
| `nb.table(rows, options)` | rows, as records or lists |
| `nb.audio(samples, {rate})` | sound to play |
| `nb.image(bytes)` | an image from the bytes of its file: PNG, JPEG, GIF, WebP or SVG |
| `nb.pixels(width, height, color)` | an image made a pixel at a time: `color(x, y)` gives a grey from 0 to 1, or `{red, green, blue}` |
| `nb.code(source, language)` | source code as code: a program the cell made, a file it read |
| `nb.html(markup)`, `nb.svg(text)` | markup of your own; `html` takes slang/html nodes too |
| `nb.markdown(text)`, `nb.text(text)` | rendered Markdown; text as it is |
| `nb.display(...values)` | shows values now |
| `nb.clear()` | takes away what the cell showed so far |

A value of your own shows itself when its metatable has `__display`, a
function of the value that gives one of these. Outside a notebook the same
calls print text, so a module that uses them also runs as a program.

## Controls

A cell can show controls: sliders, checkboxes, dropdowns, text inputs and
buttons. Using one in the page calls its function in the kernel, with the
cells' locals. An output made with `nb.output` is a place under the cell
that such a function fills again with `show`.

```slang
local nb = require("notebook")

local view = nb.output("move the slider")
local speed = nb.slider({label: "speed", min: 1, max: 10}, func(v){
  view:show(nb.plot({1, v, v * v}, {title: "speed"}))
})
speed
```

`nb.interact` does that in one step: the controls, and under them what a
function gives for their values, again each time one of them changes. The
function gets their values by the same keys.

```slang
local nb = require("notebook")
local math = require("slang/math")

nb.interact({
  frequency: nb.slider({min: 1.0, max: 20.0, value: 6.0}),
  smooth: nb.checkbox(),
}, func(v){
  local ys = {}
  for(local i = 0; i < 200; i = i + 1){
    append(ys, math.sin(i / 20 * v.frequency))
  }
  return nb.plot(ys, {kind: v.smooth and "line" or "bar"})
})
```

| function | shows |
|---|---|
| `nb.slider(options, f)` | a number from `min` to `max` (0 to 1), in steps of `step`; `scale: "log"` for a frequency or a time |
| `nb.checkbox(options, f)` | yes or no |
| `nb.dropdown(options, f)` | one of `options.options` |
| `nb.input(options, f)` | a line of text, given to `f` when enter is pressed or it is left |
| `nb.button(label, f)` | a button: `f()` with each click |
| `nb.panel(controls)` | controls side by side, in one box |
| `nb.output(...values)` | a place whose content `show(...values)` replaces; `clear()` empties it |
| `nb.interact(controls, f)` | controls, and what `f(values)` gives under them |
| `nb.on(name, f)` | a function the page's own HTML calls: `slang.call(name, value)` is a promise of what it gives back |

Options also take `label` and `value`. A control's `value` is what it is
set to now, for the cells after it too, and its function can be set or
changed later as `on_change`. Calls wait for the cell that runs, and while
one runs only the newest value of a control waits after it, so a slider
that is dragged does not pile up work.

A control works while the kernel that made it runs: after a restart, or
in a notebook just opened, it is greyed out until its cell runs again. A
cell that runs again replaces its controls. An exported page shows them
as they were last set, without doing anything.

## In the browser

`slang notebook-server [folder | notebook.md]` serves a folder's notebooks
at `http://127.0.0.1:8888/` and opens the page. `--port n` takes another
port, `--no-open` only prints the address.

- **Run** a cell with shift+enter (and go to the next) or ctrl+enter
  (and stay); **Run all** runs them from the top and stops at a cell that
  fails.
- **Stop** interrupts the running cell at its next call or loop. The
  session's state stays. **Restart** starts the kernel over and forgets
  it.
- Edits are saved as you make them, to the Markdown file and the sidecar.
  Command+S saves at once.
- Code is coloured by slang's own parser under the notebook's project, so
  the syntax of the project's extensions is coloured as it is parsed.
- With a cell selected and no cursor in it: enter edits, A and B add a
  cell above or below, D twice deletes, M and Y make it text or code, the
  arrows move.

### What the editor knows

A cell's editor asks slang's language server, the one the editors use,
about the code. It reads all the code cells as one program, top to bottom,
as they run: a name of one cell is known in the cells below it.

- **Mistakes** are underlined as you type: what does not parse, names
  nothing defines, modules that are not there, calls that do not fit the
  documented types of what they call. The mouse over one says what it is.
- **Completion** opens while you type a name, and after `.` and `:` with
  what the value before it has, in `require("` with the modules there are,
  and in a table literal with the fields a function's doc asks for.
  Ctrl+space or command+I asks for it; enter or tab takes the chosen one.
- After `(` the **signature** of what is called shows above the line, the
  argument being written marked.
- The mouse over a name shows what it is, with its doc. From there, or
  with the keys: its **definition** (command+B, or command+click) is gone
  to when it is in a cell and shown when it is in a file; its **uses**
  (shift+F12) are listed; **rename** (F2) changes it in every cell. A name
  that other files of the project use is not renamed from here.
- The other uses of the name at the cursor are marked in every cell.
- **Format** in a cell's corner (alt+shift+F) formats its code as
  `slang fmt` does.
- **Outline** lists the notebook's headings and what its code defines; a
  click goes there.

Each open notebook has a kernel, started when its first cell runs. The
outputs are kept by the server, so a reload shows them and a running cell
runs on.

The server runs code, and every page a browser has open can reach a port
of the machine. It listens on 127.0.0.1 only, answers only requests with
its token (the address it prints carries it once; a cookie after that),
and takes WebSockets and changes only from its own pages.

## Two kinds of kernel

What runs a notebook's cells is its kernel. There are two kinds:

| kernel | is | its cells |
|---|---|---|
| `process` | a slang process on this machine | do all a slang program can: files, the network, native packages, `await` |
| `wasm` | slang as WebAssembly, in a worker of the notebook's page | compute and show. They see a copy of the notebook's project and nothing else of the machine |

A notebook runs in a process unless it says otherwise, on its first line,
in a comment that Markdown does not show:

```markdown
<!-- slang-notebook kernel: wasm -->
```

The page has a switch for it (**On this machine** / **In the page**), which
writes that line. `slang notebook-server --kernel wasm` runs every notebook
in its page, whatever the notebooks say, and `--kernel process` every one
in a process. A notebook from someone else is safe to open with `--kernel
wasm`: its cells cannot reach your files.

In the page a kernel has less than a process:

- No event loop: `slang/async` and what is built on it (the network, a web
  server, timers) are not there, so a cell cannot `await`.
- No native code: packages with a native part (raylib, sqlite, `slang/ffi`)
  do not load.
- The files are a copy: the folder of the notebook's project (the nearest
  `slang.project` above it, else its own folder), up to 16 MB and 2 MB a
  file, without hidden files. What a cell writes stays in the page. The
  packages a project gets from elsewhere are not copied yet.
- **Stop** keeps the session where the browser lets a page share memory
  with its worker (Chrome, Edge, Firefox). In other browsers it ends the
  kernel, and the page says so.

Kernels in the page need slang as WebAssembly: `make wasm` builds
`lib/slang.wasm`, and `make install` takes it along.

## Without a server

`slang notebook export --live notes.md` writes `notes.html`: not a picture
of the notebook but the notebook itself, with slang inside the page (about
3 MB). Whoever opens the file can edit the cells and run them, without
slang and without a server. It opens showing what the cells showed when
they last ran.

`slang notebook app` writes the same page with an empty notebook. In it:

- **New** starts a notebook, **Open** takes a Markdown file from the
  machine, **Save** writes one. In Chrome and Edge an opened or saved file
  is then kept up to date as you edit; other browsers download a copy.
- Changes are also kept in the browser's storage, so a reload brings them
  back. **Reset** (on a page that came with a notebook) goes back to that
  one.
- The kernel is the `wasm` one, with its limits, and there is no project:
  the page has only what slang itself brings and the `notebook` module.
- The editor knows the same as on the server: the language server runs
  in the page too, with the sources of slang's library to read about.

A page that is served rather than opened from a disk can load slang from
next to it instead of carrying it (`--vm slang.wasm`). For **Stop** to keep
the session there, the server has to send the page with the headers
`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: credentialless`.

## In the terminal

| command | does |
|---|---|
| `slang notebook run notes.md` | runs the cells in order and prints what they show; exits with 1 when a cell fails |
| `slang notebook run --save notes.md` | also keeps the outputs in the sidecar |
| `slang notebook run --keep-going notes.md` | runs the cells after a failing one too |
| `slang notebook export notes.md` | writes `notes.html`: the text, the code and the saved outputs in one file |
| `slang notebook export --run --no-code notes.md` | runs it first; leaves the code out |
| `slang notebook export --live notes.md` | writes `notes.html` that is the notebook, to edit and run: slang is in the page |
| `slang notebook app` | writes `notebook.html`: the same page with an empty notebook |
| `slang notebook new notes.md` | writes a notebook to start from |
| `slang notebook clear notes.md` | removes the saved outputs |

`run` makes a notebook a check: a guide whose samples must keep working
runs in CI like a test.

## From a program

The packages are libraries too. `notebook/document` reads and writes
notebooks and their sidecars, `notebook/client` starts a kernel and runs
code in it, `notebook/run` runs a whole notebook, `notebook/export` makes
the HTML pages, `notebook/session` is an open notebook as a page talks to
it, and `notebook_server` serves. Their sources document them.
