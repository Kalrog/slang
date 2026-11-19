# notebook

Notebooks for slang: text and code in one file, run a cell at a time, with
what each cell shows under it. This package is the file format, the kernel
that runs the cells, what cells call to show plots and tables, and a
command line. `notebook_server` puts notebooks in the browser.

```sh
slang install packages/notebook       # once
slang notebook new notes.md           # a notebook to start from
slang notebook run notes.md           # run its cells, print what they show
slang notebook run --save notes.md    # and keep the outputs (notes.out.json)
slang notebook export notes.md        # notes.html: text, code and outputs in one file
slang notebook export --live notes.md # notes.html that is the notebook: slang runs in the page
slang notebook app                    # notebook.html: an empty notebook that runs in the page
```

A notebook is a Markdown file: its `slang` code blocks are the cells, the
text between them is text. The cells run in order in one session: a cell's
top-level locals stay for the cells after it, and a cell that ends in an
expression shows its value. They run in the project of the notebook's
folder, with its packages and its extensions.

```slang
local nb = require("notebook")

nb.plot({{y: dry, label: "dry"}, {y: wet, label: "wet"}}, {title: "The mix"})
nb.display(nb.table(rows), nb.audio(wet, {rate: 48000}))
```

The guide [Notebooks](../../website/guide/notebooks.md) has the rest.
`examples/tour.md` is a notebook that shows what cells can show,
`examples/controls.md` one whose cells show controls,
`examples/filters/filters.md` designs, plays and measures biquad filters
(with the dsp package);
`examples/gpu/gpu.md` draws with the GPU into a texture and shows it as
an image (it needs a kernel on this machine: slang in a page has no `gpu`
package).

## The modules

| module | what it is |
|---|---|
| `notebook` | what cells call: `plot`, `table`, `audio`, `image`, `pixels`, `code`, `html`, `markdown`, `display`; controls (`slider`, `checkbox`, `dropdown`, `input`, `button`, `panel`, `interact`, `on`) and outputs to replace (`output`) |
| `notebook/document` | a notebook as a file: Markdown to cells and back, the sidecar of outputs |
| `notebook/client` | starts a kernel and runs code in it: `execute`, `interrupt`, `shutdown` |
| `notebook/kernel`, `notebook/protocol` | the process that runs the cells, and how it talks |
| `notebook/runner` | what runs cells inside a kernel: one session, in the notebook's project |
| `notebook/run` | runs a whole notebook |
| `notebook/export` | a notebook and its outputs as one HTML page; `app`: the notebook as a page that runs it |
| `notebook/session` | an open notebook: cells, the queue, a kernel, the pages that show it |
| `notebook/kernel_web`, `notebook/service_web` | the kernel and the session as slang.wasm in a page's workers |
| `notebook/remote`, `notebook/browser` | a kernel that is in a page, as a session sees it; what a page needs (slang.wasm, the worker, the files) |
| `notebook/inspect` | a value as text and as a tree to unfold |
| `notebook/markdown`, `notebook/highlight` | Markdown to HTML; code coloured by slang's parser |
| `notebook/language` | what an editor knows about the cells' code: slang's language server (the `lsp` package), with the code cells as one notebook |

```slang
local async = require("slang/async")
local client = require("notebook/client")

async.main(func(){
  local kernel = client.start({path: "notes.md", on_event: func(event){
    if(event.event == "result"){
      print(event.data["text/plain"], "\n")
    }
  }})
  async.await(kernel:execute("local n = 20"))
  async.await(kernel:execute("n + 1"))          // prints 21
  async.await(kernel:shutdown())
})
```

## In a browser, without a process

A notebook's cells can run inside its page: slang as WebAssembly (`make
wasm` builds `lib/slang.wasm`) in a worker. A notebook asks for that on
its first line (`<!-- slang-notebook kernel: wasm -->`), the notebook
server can do it for every notebook (`--kernel wasm`), and `export --live`
and `app` make a page that needs nothing else: the notebook's session is a
second worker there.

`web/` is the page: `app.js` and `app.css` (the notebook server's page
too), `worker.js` (runs slang.wasm) and `wasi.js` (the system slang.wasm
asks for; the same file as `website/public/wasi.js`).

`make notebook-test` runs the tests of both packages, and with `make wasm`
done and node installed also `test/web_test.mjs`: slang.wasm as a kernel
and as a page's session, with Node in the page's place.
