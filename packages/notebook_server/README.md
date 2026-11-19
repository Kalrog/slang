# notebook_server

Slang notebooks in the browser: a folder's notebooks, and each one as
cells to edit and run. The notebooks are the Markdown files of the
`notebook` package; this package is the server and the page.

```sh
slang install packages/notebook_server   # once
slang notebook-server                    # the notebooks of this folder
slang notebook-server notes              # those of the folder notes
slang notebook-server notes/first.md     # that notebook, made when it is missing
slang notebook-server --kernel wasm      # every notebook's cells run inside its page
```

It serves at `http://127.0.0.1:8888/` (`--port n` for another port) and
opens the page (`--no-open` only prints the address). Ctrl-c ends the
server and its kernels.

- Shift+enter runs a cell and goes on, ctrl+enter runs it and stays.
  **Run all** runs the notebook from the top, **Stop** interrupts the
  running cell, **Restart** starts the kernel over.
- Every open notebook has a kernel of its own, started when its first
  cell runs, in the project of the notebook's folder. It is a slang
  process on this machine, or, for a notebook that says `kernel: wasm` (the
  page has a switch), slang as WebAssembly inside the page: the cells then
  see a copy of the project and nothing else of the machine. `--kernel
  wasm` or `--kernel process` makes it one of the two for every notebook;
  `wasm` is how to open a notebook you do not trust. (Needs `make wasm`.)
- Edits are saved as they are made, to the Markdown file and to the
  sidecar of outputs. What the cells showed is kept by the server: a
  reload shows it, and a running cell runs on.
- Code is coloured by slang's own parser, under the notebook's project.
  The page loads nothing from elsewhere.
- The editor asks slang's language server (the `lsp` package, in the
  server's process) about the code, all cells read as one program:
  mistakes underlined as you type, completion (ctrl+space or command+I),
  the signature of the call being written, what a name is under the
  mouse, its definition (command+B or command+click), its uses
  (shift+F12), renaming in every cell (F2), formatting (alt+shift+F, or
  **Format** in the cell's corner), and an **Outline** of the notebook.
- The server listens on 127.0.0.1 only and wants its token, which the
  address it prints carries: a notebook server runs code, and any page in
  a browser can reach a port of the machine.

The guide [Notebooks](../../website/guide/notebooks.md) has the rest.

```slang
local async = require("slang/async")
local server = require("notebook_server")

async.main(func(){
  local s = server.start({root: "notes", port: 0})   // any free port
  print(s.url, "\n")
  async.await(s.done)
})
```

`make notebook` serves the example notebooks, `make notebook-test` runs
the tests.
