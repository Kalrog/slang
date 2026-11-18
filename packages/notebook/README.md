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
`examples/tour.md` is a notebook that shows what cells can show.

## The modules

| module | what it is |
|---|---|
| `notebook` | what cells call: `plot`, `table`, `audio`, `image`, `html`, `markdown`, `display` |
| `notebook/document` | a notebook as a file: Markdown to cells and back, the sidecar of outputs |
| `notebook/client` | starts a kernel and runs code in it: `execute`, `interrupt`, `shutdown` |
| `notebook/kernel`, `notebook/protocol` | the process that runs the cells, and how it talks |
| `notebook/run` | runs a whole notebook |
| `notebook/export` | a notebook and its outputs as one HTML page |
| `notebook/inspect` | a value as text and as a tree to unfold |
| `notebook/markdown`, `notebook/highlight` | Markdown to HTML; code coloured by slang's parser |

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

`make notebook-test` runs the tests of both packages.
