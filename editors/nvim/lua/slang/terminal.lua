-- Terminals in a split at the bottom: one running a slang command (run,
-- get, build ...; the next command replaces it), and the REPL, which stays
-- until it ends. The cursor stays where it was.
local config = require("slang.config")

local M = {}

local command -- {buf, chan}
local repl

local function window_of(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

local function alive(term)
  return term and vim.api.nvim_buf_is_valid(term.buf) and vim.fn.jobwait({ term.chan }, 0)[1] == -1
end

-- the window showing term, else a new split at the bottom
local function window(term)
  local win = term and vim.api.nvim_buf_is_valid(term.buf) and window_of(term.buf)
  if win then
    return win
  end
  local back = vim.api.nvim_get_current_win()
  vim.cmd("botright " .. config.options.terminal_height .. "split")
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(back)
  return win
end

-- a terminal running cmd in a new buffer shown in win
local function start(win, cmd, cwd)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  local chan
  vim.api.nvim_win_call(win, function()
    chan = vim.fn.jobstart(cmd, { term = true, cwd = cwd })
  end)
  if chan <= 0 then
    vim.notify("slang: cannot start " .. cmd[1] .. " (set path; see :checkhealth slang)", vim.log.levels.ERROR)
  end
  return { buf = buf, chan = chan }
end

-- runs slang with args in the command terminal
function M.run(args, cwd)
  local old = command
  local win = window(old)
  command = start(win, vim.list_extend({ config.slang() }, args), cwd)
  if old and vim.api.nvim_buf_is_valid(old.buf) then
    pcall(vim.fn.jobstop, old.chan)
    vim.api.nvim_buf_delete(old.buf, { force = true })
  end
end

-- the REPL's channel, started in cwd when it is not running, and shown
function M.repl(cwd)
  if alive(repl) then
    local win = window(repl)
    if vim.api.nvim_win_get_buf(win) ~= repl.buf then
      vim.api.nvim_win_set_buf(win, repl.buf)
    end
    return repl.chan
  end
  local old = repl
  repl = start(window(old), { config.slang(), "repl" }, cwd)
  if old and vim.api.nvim_buf_is_valid(old.buf) then
    vim.api.nvim_buf_delete(old.buf, { force = true })
  end
  return repl.chan
end

-- sends lines to the REPL, which reads a line at a time; blank ones are left out
function M.send(lines, cwd)
  local chan = M.repl(cwd)
  if chan <= 0 then
    return
  end
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      vim.api.nvim_chan_send(chan, line .. "\r")
    end
  end
end

return M
