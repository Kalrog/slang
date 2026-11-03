-- The indentexpr of slang buffers: a line after one that leaves a bracket
-- open is indented a level more, a line starting with a closing bracket a
-- level less (slang fmt does the rest). Lines inside a """ string keep
-- theirs.
local M = {}

local closing = { [")"] = true, ["]"] = true, ["}"] = true }
local opening = { ["("] = true, ["["] = true, ["{"] = true }

-- the brackets a line opens minus those it closes, after the ones it starts
-- with; strings and comments left out
local function balance(line)
  local i, n = 1, #line
  while i <= n and (line:sub(i, i):match("%s") or closing[line:sub(i, i)]) do
    i = i + 1
  end
  local depth = 0
  while i <= n do
    local c = line:sub(i, i)
    if c == "/" and line:sub(i + 1, i + 1) == "/" then
      break
    elseif c == '"' then
      if line:sub(i, i + 2) == '"""' then
        local stop = line:find('"""', i + 3, true)
        if not stop then
          break
        end
        i = stop + 2
      else
        i = i + 1
        while i <= n and line:sub(i, i) ~= '"' do
          i = i + (line:sub(i, i) == "\\" and 2 or 1)
        end
      end
    elseif opening[c] then
      depth = depth + 1
    elseif closing[c] then
      depth = depth - 1
    end
    i = i + 1
  end
  return depth
end

local function in_string(lnum)
  local id = vim.fn.synID(lnum, 1, 1)
  return vim.fn.synIDattr(id, "name") == "slangString"
end

function M.get(lnum)
  if in_string(lnum) then
    return -1
  end
  local prev = vim.fn.prevnonblank(lnum - 1)
  if prev == 0 then
    return 0
  end
  local sw = vim.fn.shiftwidth()
  local indent = vim.fn.indent(prev)
  local depth = balance(vim.fn.getline(prev))
  if depth > 0 then
    indent = indent + sw
  elseif depth < 0 then
    indent = indent - sw
  end
  if closing[vim.trim(vim.fn.getline(lnum)):sub(1, 1)] then
    indent = indent - sw
  end
  return math.max(0, indent)
end

return M
