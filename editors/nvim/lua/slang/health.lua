-- :checkhealth slang
local config = require("slang.config")

local M = {}

function M.check()
  local h = vim.health
  h.start("slang")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.11 or newer is needed (vim.lsp.config)")
  end

  local slang = config.slang()
  if vim.fn.executable(slang) == 1 then
    h.ok("slang: " .. vim.fn.exepath(slang))
  else
    h.error("slang not found: " .. slang, { "put slang on the PATH, or setup({ path = '/path/to/slang' })" })
  end

  local dir = config.server_dir()
  if dir then
    h.ok("language server: " .. dir .. "/lsp/main.slang")
  else
    h.error("lsp/main.slang not found", { "setup({ server_dir = '<the slang repository>' })" })
  end

  local clients = vim.lsp.get_clients({ name = "slang" })
  if #clients > 0 then
    for _, c in ipairs(clients) do
      h.ok(("server running (id %d) in %s"):format(c.id, c.root_dir or "?"))
    end
  else
    h.info("no server running (it starts with the first slang buffer)")
  end

  if pcall(require, "dap") then
    h.ok("nvim-dap: :Slang debug and :Slang test debug are available")
  else
    h.warn("nvim-dap is not installed: no debugging")
  end
end

return M
