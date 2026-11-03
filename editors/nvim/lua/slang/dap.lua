-- The debugger, through nvim-dap when it is installed. The VM speaks the
-- Debug Adapter Protocol on a local port: the adapter starts the program
-- with `slang run --debug <port>` (SLANG_DEBUG=<port> for `slang test`), its
-- output in the REPL, and connects once it waits for a debugger.
-- Configurations: program, args, cwd, stopOnEntry, and command = "test" to
-- debug a file's tests.
local config = require("slang.config")

local M = {}

local function free_port()
  local tcp = assert(vim.uv.new_tcp())
  tcp:bind("127.0.0.1", 0)
  local port = tcp:getsockname().port
  tcp:close()
  return port
end

local function adapter(callback, cfg)
  local repl = require("dap.repl")
  local port = free_port()
  local verb = cfg.command or "run"
  local args = { config.slang() }
  local env
  if verb == "run" then
    vim.list_extend(args, { "run", "--debug", tostring(port), cfg.program })
    vim.list_extend(args, cfg.args or {})
  else
    table.insert(args, verb)
    vim.list_extend(args, cfg.args or {})
    table.insert(args, cfg.program)
    env = { SLANG_DEBUG = tostring(port) }
  end
  local listening = false
  local early = {}
  local function output(data)
    vim.schedule(function()
      repl.append((data:gsub("\n$", "")))
    end)
  end
  local ok, err = pcall(vim.system, args, {
    cwd = cfg.cwd or config.root(0),
    env = env,
    stdout = function(_, data)
      if data then
        output(data)
      end
    end,
    stderr = function(_, data)
      if not data then
        return
      end
      if not listening and data:find("waiting for a debugger", 1, true) then
        listening = true
        vim.schedule(function()
          callback({ type = "server", host = "127.0.0.1", port = port })
        end)
      elseif listening then
        output(data)
      else
        table.insert(early, data)
      end
    end,
  }, function(out)
    if not listening then
      vim.schedule(function()
        vim.notify(
          ("slang ended (code %d) before the debugger could connect\n%s"):format(out.code, table.concat(early)),
          vim.log.levels.ERROR
        )
      end)
    end
  end)
  if not ok then
    vim.notify("slang: cannot start " .. args[1] .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function dap()
  local ok, d = pcall(require, "dap")
  return ok and d or nil
end

-- the adapter and the configurations of a launch.json-less F5
function M.setup()
  local d = dap()
  if not d then
    return false
  end
  d.adapters.slang = adapter
  d.configurations.slang = d.configurations.slang or {
    { type = "slang", request = "launch", name = "Debug the current file", program = "${file}" },
    { type = "slang", request = "launch", name = "Debug the tests of the current file", command = "test", program = "${file}" },
  }
  return true
end

-- debugs a file, or (command = "test") its tests, only the one named
function M.start(file, command, only)
  if not M.setup() then
    vim.notify("slang: debugging needs nvim-dap (mfussenegger/nvim-dap)", vim.log.levels.ERROR)
    return
  end
  local name = vim.fs.basename(file)
  dap().run({
    type = "slang",
    request = "launch",
    name = "Debug " .. (only or name),
    command = command,
    program = file,
    args = only and { "--only", only } or {},
  })
end

return M
