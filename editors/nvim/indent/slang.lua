if vim.b.did_indent then
  return
end
vim.b.did_indent = true

vim.bo.indentexpr = "v:lua.require'slang.indent'.get(v:lnum)"
vim.bo.indentkeys = "0{,0},0),0],!^F,o,O,e"

vim.b.undo_indent = "setlocal indentexpr< indentkeys<"
