-- The options of the slang plugin, and where the slang binary, the language
-- server and a buffer's project are.
local M = {}

M.defaults = {
  -- the slang binary: nil is slang on the PATH, else this repository's bin/slang
  path = nil,
  -- the folder holding lsp/main.slang: nil is this repository's
  server_dir = nil,
  -- which call arguments get their parameter's name as an inlay hint:
  -- "literals", "all" or "none"
  parameter_hints = "literals",
  -- unused locals, globals no project file defines, requires of missing modules
  lint = true,
  inlay_hints = true,
  format_on_save = true,
  -- the dialect suffixes of the project's slang.project are slang files
  associate_dialects = true,
  -- the folder the server (and run, test, the REPL) starts in, for a buffer:
  -- nil is the git root above it, else its project, else the working directory
  root = nil,
  terminal_height = 15,
}

M.options = vim.deepcopy(M.defaults)

-- editors/nvim, and the repository it is in
M.plugin_dir = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
M.repo_dir = vim.fs.dirname(vim.fs.dirname(M.plugin_dir))

-- errors (`error: ...` then `  at file:line:col`) and failed tests
-- (`  Error: ... @file:line:col`), for :compiler slang and the test runner
M.errorformat = table.concat({
  [[%\s%#Error: %m @%f:%l:%c]],
  [[%Eerror: %m]],
  [[%Z%\s%#at %f:%l:%c]],
  [[%-C%.%#]],
  [[%-G%.%#]],
}, ",")

function M.slang()
  local path = M.options.path
  if path then
    return vim.fn.expand(path)
  end
  if vim.fn.executable("slang") == 1 then
    return "slang"
  end
  local local_build = M.repo_dir .. "/bin/slang"
  if vim.fn.executable(local_build) == 1 then
    return local_build
  end
  return "slang"
end

function M.server_dir()
  if M.options.server_dir then
    return vim.fn.expand(M.options.server_dir)
  end
  for _, dir in ipairs({ M.plugin_dir, M.repo_dir }) do
    if vim.uv.fs_stat(dir .. "/lsp/main.slang") then
      return dir
    end
  end
end

function M.root(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if M.options.root then
    return M.options.root(buf)
  end
  return vim.fs.root(buf, ".git") or vim.fs.root(buf, "slang.project") or vim.fn.getcwd()
end

-- the folder of the slang.project above a buffer's file
function M.project(buf)
  return vim.fs.root(buf, "slang.project")
end

return M
