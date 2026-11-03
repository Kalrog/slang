-- The expanded code of a file (the server's `slang/expand`: the file after
-- its extensions ran) in a scratch buffer beside it, updated as the file
-- changes.
local lsp = require("slang.lsp")

local M = {}

local views = {} -- source buffer -> view buffer

local function show(view, text)
  if not vim.api.nvim_buf_is_valid(view) then
    return
  end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.bo[view].modifiable = true
  vim.api.nvim_buf_set_lines(view, 0, -1, false, lines)
  vim.bo[view].modifiable = false
end

local function refresh(src, view)
  local client = lsp.client(src)
  if not client then
    show(view, "// the slang language server is not running")
    return
  end
  client:request("slang/expand", { uri = vim.uri_from_bufnr(src) }, function(err, result)
    if err then
      show(view, "// cannot expand the file: " .. err.message)
    elseif result.text then
      show(view, result.text)
    else
      show(view, "// cannot expand the file: " .. tostring(result.error))
    end
  end, src)
end

function M.open(src)
  src = src == 0 and vim.api.nvim_get_current_buf() or src
  local view = views[src]
  if view and vim.api.nvim_buf_is_valid(view) then
    if vim.fn.bufwinid(view) == -1 then
      vim.cmd("vertical rightbelow sbuffer " .. view)
      vim.cmd.wincmd("p")
    end
    refresh(src, view)
    return
  end

  view = vim.api.nvim_create_buf(false, true)
  views[src] = view
  local name = vim.api.nvim_buf_get_name(src):gsub("%.[^./]*$", "")
  vim.api.nvim_buf_set_name(view, "slang-expanded://" .. name .. ".expanded.slang")
  vim.bo[view].bufhidden = "wipe"
  -- highlighted as slang; no language server (it is no file)
  vim.bo[view].filetype = "slang"
  vim.bo[view].modifiable = false
  vim.cmd("vertical rightbelow sbuffer " .. view)
  vim.cmd.wincmd("p")
  refresh(src, view)

  -- follows the edits of its file, a moment after they stop
  local group = vim.api.nvim_create_augroup("slang.expand." .. src, { clear = true })
  local timer = assert(vim.uv.new_timer())
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = src,
    callback = function()
      timer:stop()
      timer:start(300, 0, vim.schedule_wrap(function()
        refresh(src, view)
      end))
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = view,
    callback = function()
      views[src] = nil
      timer:stop()
      timer:close()
      vim.schedule(function()
        pcall(vim.api.nvim_del_augroup_by_id, group)
      end)
    end,
  })
end

return M
