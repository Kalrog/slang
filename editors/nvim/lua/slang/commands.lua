-- :Slang <command>: run, debug, repl, send, expand, test, get, update,
-- build, restart.
local config = require("slang.config")

local M = {}

-- the buffer's file, saved; nil (and why) when it has none
local function file_of(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    vim.notify("slang: the buffer is no file", vim.log.levels.ERROR)
    return nil
  end
  if vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent update")
    end)
  end
  return name
end

-- slang with args in the terminal, in the folder of the buffer's project
local function in_project(args)
  return function(cmd)
    local dir = config.project(cmd.buf)
    if not dir then
      vim.notify("slang: no slang.project above this file", vim.log.levels.ERROR)
      return
    end
    require("slang.terminal").run(args, dir)
  end
end

local commands = {
  run = function(cmd)
    local file = file_of(cmd.buf)
    if file then
      require("slang.terminal").run({ "run", file }, config.root(cmd.buf))
    end
  end,
  debug = function(cmd)
    local file = file_of(cmd.buf)
    if file then
      require("slang.dap").start(file)
    end
  end,
  repl = function(cmd)
    require("slang.terminal").repl(config.root(cmd.buf))
  end,
  -- the selected lines (:'<,'>Slang send), else the current one
  send = function(cmd)
    local first, last = cmd.line1, cmd.line2
    if cmd.range == 0 then
      first = vim.api.nvim_win_get_cursor(0)[1]
      last = first
    end
    local lines = vim.api.nvim_buf_get_lines(cmd.buf, first - 1, last, false)
    require("slang.terminal").send(lines, config.root(cmd.buf))
  end,
  expand = function(cmd)
    require("slang.expand").open(cmd.buf)
  end,
  -- the file's tests (the project's, when it is no test file); `nearest`:
  -- the test or group under the cursor; `all`: the project's; `debug`: the
  -- one under the cursor in the debugger; `clear`: the marks of the last run
  test = function(cmd)
    local tests = require("slang.tests")
    local what = cmd.fargs[2]
    if what == nil then
      tests.file(cmd.buf)
    elseif what == "nearest" then
      tests.nearest_run(cmd.buf, vim.api.nvim_win_get_cursor(0)[1] - 1)
    elseif what == "all" then
      tests.project(cmd.buf)
    elseif what == "debug" then
      local file = file_of(cmd.buf)
      if not file then
        return
      end
      local line = vim.api.nvim_win_get_cursor(0)[1] - 1
      tests.list(cmd.buf, function(list)
        require("slang.dap").start(file, "test", tests.nearest(list, line))
      end)
    elseif what == "clear" then
      tests.clear(cmd.buf)
    else
      vim.notify("slang: :Slang test [nearest|all|debug|clear]", vim.log.levels.ERROR)
    end
  end,
  get = in_project({ "get" }),
  update = in_project({ "update" }),
  build = function(cmd)
    in_project(cmd.fargs[2] == "dir" and { "build", "--dir" } or { "build" })(cmd)
  end,
  restart = function()
    require("slang.lsp").restart()
  end,
}

local arguments = {
  test = { "nearest", "all", "debug", "clear" },
  build = { "dir" },
}

local function complete(lead, line)
  local words = vim.split(line:gsub("^%S+%s*", ""), "%s+")
  local candidates = #words <= 1 and vim.tbl_keys(commands) or arguments[words[1]] or {}
  table.sort(candidates)
  return vim.tbl_filter(function(c)
    return vim.startswith(c, lead)
  end, candidates)
end

function M.setup()
  vim.api.nvim_create_user_command("Slang", function(cmd)
    local f = commands[cmd.fargs[1]]
    if not f then
      vim.notify("slang: no command " .. cmd.fargs[1], vim.log.levels.ERROR)
      return
    end
    cmd.buf = vim.api.nvim_get_current_buf()
    f(cmd)
  end, { nargs = "+", range = true, complete = complete, desc = "slang: run, test, debug, repl, expand, build ..." })
end

return M
