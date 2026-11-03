-- slang for Neovim: the slang language server (lsp/ of the slang
-- repository) for highlighting, diagnostics, navigation, completion and
-- formatting; :Slang to run a file, use a REPL, run tests, see the expanded
-- code, fetch packages, build and debug (with nvim-dap). See README.md.
local M = {}

function M.setup(opts)
  local config = require("slang.config")
  config.options = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), opts or {})
  -- .slang is Neovim's shaderslang otherwise, when ftdetect/ was not sourced
  -- at startup (a plugin manager loading this later)
  dofile(config.plugin_dir .. "/ftdetect/slang.lua")
  require("slang.lsp").setup()
  require("slang.commands").setup()
  require("slang.dap").setup()
end

return M
