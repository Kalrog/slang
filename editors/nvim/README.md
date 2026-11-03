# slang for Neovim

Highlighting, diagnostics, navigation, completion, formatting, tests,
running and debugging for slang, in Neovim 0.11 or newer. A Vim syntax file
colours the core language on its own; the plugin starts the slang language
server (`lsp/` of this repository) for slang buffers, which parses each
file with the project's real grammar, extensions and dialects included.
What the server provides (see `lsp/README.md`) works through Neovim's own
LSP client:

- semantic tokens over the syntax colours, parse errors and lint warnings;
- hover (`K`), go to definition, references, document highlights, rename
  across the project (`grn`, `grr`, `gd` with your mappings), the outline
  and workspace symbols, signature help, completion (members after `a.`
  and `a:`, names, keywords, `require("...")` module names);
- parameter-name inlay hints, on by default;
- formatting with `slang fmt`'s formatter (`gq`, `vim.lsp.buf.format()`),
  on save by default;
- `slang.project`: its keys completed, explained and checked;
- the project's dialect suffixes are slang files once the server reports
  them, and a `slang.project` written in Neovim makes it reload the grammars.

Besides, the `:Slang` command:

| command | does |
|---|---|
| `:Slang run` | `slang run` the file in a terminal split |
| `:Slang debug` | debug the file (nvim-dap) |
| `:Slang repl` | open the REPL |
| `:Slang send` | send the current line, or `:'<,'>Slang send` the selected ones, to the REPL |
| `:Slang expand` | the file after its extensions ran, beside it, following its edits |
| `:Slang test` | the tests of a `*test.slang` file (else the project's): ✓/✗ beside each test and group, failures as diagnostics and in the quickfix list |
| `:Slang test nearest` | the test or group under the cursor |
| `:Slang test all` | every test of the project |
| `:Slang test debug` | the test under the cursor in the debugger |
| `:Slang test clear` | remove the marks of the last run |
| `:Slang get`, `update`, `build`, `build dir` | `slang get`, `update`, `build`, `build --dir` in the project's folder |
| `:Slang restart` | restart the language server |

`:compiler slang` sets `:make` to `slang test` with an `errorformat` for
slang's errors and failed tests (`:make build` builds). `:checkhealth slang`
says what was found. The VS Code extension's snippets load into LuaSnip
(`require("luasnip.loaders.from_vscode").lazy_load()`) and other engines
that read VS Code snippet packages.

## Installing

With lazy.nvim, from a checkout of this repository:

```lua
{
  dir = "~/Development/Workspace/slang/editors/nvim",
  ft = "slang",
  cmd = "Slang",
  opts = {},
}
```

The plugin finds the language server in the repository it is in and the
`slang` binary on the PATH, else the repository's `bin/slang` (`make`
builds it).

## Options

The defaults:

```lua
require("slang").setup({
  path = nil,                   -- the slang binary
  server_dir = nil,             -- the folder holding lsp/main.slang
  parameter_hints = "literals", -- inlay hints for "literals", "all" or "none" of the arguments
  lint = true,                  -- unused locals, unknown globals, missing modules
  inlay_hints = true,
  format_on_save = true,
  associate_dialects = true,    -- the project's dialect suffixes are slang files
  root = nil,                   -- function(buf): where the server, run, test and the REPL start
                                -- (default: the git root, else the project, else the cwd)
  terminal_height = 15,
})
```

Server settings that are not plugin options go through `vim.lsp.config`:
`vim.lsp.config("slang", { ... })` after `setup`.

Some mappings, for example:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "slang",
  callback = function(args)
    local map = function(lhs, rhs) vim.keymap.set("n", lhs, rhs, { buffer = args.buf }) end
    map("<leader>sr", "<cmd>Slang run<cr>")
    map("<leader>st", "<cmd>Slang test nearest<cr>")
    map("<leader>sT", "<cmd>Slang test<cr>")
    map("<leader>se", "<cmd>Slang expand<cr>")
    map("<S-CR>", "<cmd>Slang send<cr>")
    vim.keymap.set("x", "<S-CR>", ":Slang send<cr>", { buffer = args.buf })
  end,
})
```

## Debugging

With [nvim-dap](https://github.com/mfussenegger/nvim-dap) installed, the
plugin adds a `slang` adapter: it starts the program with `slang run
--debug <port>` (`SLANG_DEBUG` for `slang test`), shows its output in the
dap REPL and connects to the VM, which speaks the Debug Adapter Protocol.
`dap.continue()` on a slang buffer offers "Debug the current file" and
"Debug the tests of the current file"; configurations take `program`,
`args`, `cwd`, `stopOnEntry`, and `command = "test"`. Breakpoints (with
conditions), stepping, the call stack, locals, upvalues and globals, and
expressions in the REPL work as in VS Code.

## Trust

The language server runs the project's extensions while it parses (VS Code
starts it in trusted workspaces only). This plugin starts it for every slang
buffer: open projects you do not trust with the plugin off.
