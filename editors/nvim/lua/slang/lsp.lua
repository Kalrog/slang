-- The slang language server: `slang run <server_dir>/lsp/main.slang
-- <server_dir>` in the buffer's root folder. Besides what Neovim does with
-- the server's capabilities: inlay hints, formatting on save, the
-- project's dialect suffixes as slang files (the `slang/project`
-- notification), and slang.project written in Neovim told to the server.
local config = require("slang.config")

local M = {}

function M.client(buf)
  return vim.lsp.get_clients({ name = "slang", bufnr = buf })[1]
end

-- files under the project's folder with one of its dialect suffixes are
-- slang files (a project's .json files, not every one), the ones open already too
local function associate(project, dialects)
  if not config.options.associate_dialects or type(project) ~= "string" then
    return
  end
  local dir = vim.fs.normalize(project):gsub("/slang%.project$", "")
  local patterns = {}
  for _, suffix in ipairs(dialects or {}) do
    if suffix ~= ".slang" then
      patterns[vim.pesc(dir) .. "/.*" .. vim.pesc(suffix)] = "slang"
    end
  end
  if next(patterns) == nil then
    return
  end
  vim.filetype.add({ pattern = patterns })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "slang" then
      local name = vim.api.nvim_buf_get_name(buf)
      for _, suffix in ipairs(dialects) do
        if suffix ~= ".slang" and vim.startswith(name, dir .. "/") and vim.endswith(name, suffix) then
          vim.bo[buf].filetype = "slang"
          break
        end
      end
    end
  end
end

-- the "punctuation" token type is the server's own
local function highlights()
  vim.api.nvim_set_hl(0, "@lsp.type.punctuation.slang", { link = "@punctuation.delimiter", default = true })
end

local function attach(client, buf)
  local opts = config.options
  if opts.inlay_hints and opts.parameter_hints ~= "none" then
    vim.lsp.inlay_hint.enable(true, { bufnr = buf })
  end
  if opts.format_on_save then
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = vim.api.nvim_create_augroup("slang.format." .. buf, { clear = true }),
      buffer = buf,
      callback = function()
        vim.lsp.buf.format({ bufnr = buf, id = client.id, timeout_ms = 3000 })
      end,
    })
  end
end

function M.setup()
  local opts = config.options
  vim.lsp.config("slang", {
    cmd = function(dispatchers, cfg)
      local dir = config.server_dir()
      if not dir then
        error("slang: lsp/main.slang not found (set server_dir; see :checkhealth slang)")
      end
      -- the server resolves extension files from its working directory
      return vim.lsp.rpc.start(
        { config.slang(), "run", dir .. "/lsp/main.slang", dir },
        dispatchers,
        { cwd = cfg.root_dir }
      )
    end,
    filetypes = { "slang" },
    root_dir = function(buf, on_dir)
      on_dir(config.root(buf))
    end,
    init_options = {
      parameterHints = opts.parameter_hints,
      lint = opts.lint,
    },
    handlers = {
      ["slang/project"] = function(_, params)
        associate(params.path, params.dialects)
      end,
    },
    on_attach = attach,
  })
  vim.lsp.enable("slang")

  local group = vim.api.nvim_create_augroup("slang.lsp", { clear = true })
  highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  -- a changed slang.project makes the server load the grammars anew
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "slang.project",
    callback = function(args)
      local uri = vim.uri_from_fname(vim.api.nvim_buf_get_name(args.buf))
      for _, client in ipairs(vim.lsp.get_clients({ name = "slang" })) do
        client:notify("workspace/didChangeWatchedFiles", { changes = { { uri = uri, type = 2 } } })
      end
    end,
  })
end

-- stops the servers and starts them again for the open slang buffers
function M.restart()
  local clients = vim.lsp.get_clients({ name = "slang" })
  for _, client in ipairs(clients) do
    client:stop()
  end
  local timer = assert(vim.uv.new_timer())
  local tries = 0
  timer:start(100, 100, vim.schedule_wrap(function()
    tries = tries + 1
    local running = vim.tbl_filter(function(c)
      return not c:is_stopped()
    end, clients)
    if #running == 0 or tries > 50 then
      timer:stop()
      timer:close()
      for _, c in ipairs(running) do
        c:stop(true)
      end
      vim.lsp.enable("slang")
    end
  end))
end

return M
