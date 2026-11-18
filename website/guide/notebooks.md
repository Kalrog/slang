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
executables.

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
| `nb.image(bytes)` | a PNG, JPEG, GIF, WebP or SVG image |
| `nb.html(markup)`, `nb.svg(text)` | markup of your own; `html` takes slang/html nodes too |
| `nb.markdown(text)`, `nb.text(text)` | rendered Markdown; text as it is |
| `nb.display(...values)` | shows values now |
| `nb.clear()` | takes away what the cell showed so far |

A value of your own shows itself when its metatable has `__display`, a
function of the value that gives one of these. Outside a notebook the same
calls print text, so a module that uses them also runs as a program.

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

Each open notebook has a kernel, a slang process of its own, started when
its first cell runs. The outputs are kept by the server, so a reload shows
them and a running cell runs on.

The server runs code, and every page a browser has open can reach a port
of the machine. It listens on 127.0.0.1 only, answers only requests with
its token (the address it prints carries it once; a cookie after that),
and takes WebSockets and changes only from its own pages.

## In the terminal

| command | does |
|---|---|
| `slang notebook run notes.md` | runs the cells in order and prints what they show; exits with 1 when a cell fails |
| `slang notebook run --save notes.md` | also keeps the outputs in the sidecar |
| `slang notebook run --keep-going notes.md` | runs the cells after a failing one too |
| `slang notebook export notes.md` | writes `notes.html`: the text, the code and the saved outputs in one file |
| `slang notebook export --run --no-code notes.md` | runs it first; leaves the code out |
| `slang notebook new notes.md` | writes a notebook to start from |
| `slang notebook clear notes.md` | removes the saved outputs |

`run` makes a notebook a check: a guide whose samples must keep working
runs in CI like a test.

## From a program

The packages are libraries too. `notebook/document` reads and writes
notebooks and their sidecars, `notebook/client` starts a kernel and runs
code in it, `notebook/run` runs a whole notebook, `notebook/export` makes
the HTML page, and `notebook_server` serves. Their sources document them.
