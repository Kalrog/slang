-- Tests, run with `slang test --json`: a ✓ or ✗ beside each test and group
-- of the file (the server's `slang/tests` finds them), failures as
-- diagnostics where they happened and in the quickfix list. A file that does
-- not load gets its error in the quickfix list.
local config = require("slang.config")
local lsp = require("slang.lsp")

local M = {}

local ns = vim.api.nvim_create_namespace("slang.test")

function M.is_test_file(buf)
  return vim.endswith(vim.api.nvim_buf_get_name(buf), "test.slang")
end

-- the groups and tests of a buffer: {kind, name, range, children}
function M.list(buf, callback)
  local client = lsp.client(buf)
  if not client then
    callback({})
    return
  end
  client:request("slang/tests", { uri = vim.uri_from_bufnr(buf) }, function(err, result)
    callback(not err and result and result.tests or {})
  end, buf)
end

-- the path ("group / test") of the innermost group or test around a line
function M.nearest(tests, line)
  local function find(nodes, prefix)
    for _, node in ipairs(nodes) do
      if node.range.start.line <= line and line <= node.range["end"].line then
        local path = prefix and (prefix .. " / " .. node.name) or node.name
        return find(node.children or {}, path) or path
      end
    end
  end
  return find(tests, nil)
end

-- every group and test by its path
local function index(nodes, prefix, out)
  for _, node in ipairs(nodes) do
    local path = prefix and (prefix .. " / " .. node.name) or node.name
    out[path] = node
    index(node.children or {}, path, out)
  end
  return out
end

local function within(path, only)
  return only == nil or path == only or vim.startswith(path, only .. " / ")
end

local function mark(buf, node, text, hl)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line = node.range.start.line
  if line >= vim.api.nvim_buf_line_count(buf) then
    return
  end
  -- one mark per line, replaced as the test's state changes
  vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
    id = line + 1,
    virt_text = { { text, hl } },
    virt_text_pos = "eol",
  })
end

-- runs the tests: spec.file (else all of the project in spec.cwd), only the
-- group or test spec.only, marked in spec.buf when it shows spec.tests
function M.run(spec)
  local args = { config.slang(), "test", "--json" }
  if spec.only then
    vim.list_extend(args, { "--only", spec.only })
  end
  if spec.file then
    table.insert(args, spec.file)
  end
  local buf = spec.buf
  local nodes = index(spec.tests or {}, nil, {})
  local status = {} -- path -> "passed" | "failed"
  if buf then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.diagnostic.reset(ns, buf)
    for path, node in pairs(nodes) do
      if within(path, spec.only) then
        mark(buf, node, " …", "Comment")
      end
    end
  end

  local failures, diagnostics, other = {}, {}, {}
  local passed, failed = 0, 0
  local function absolute(file)
    return vim.fs.normalize(vim.fn.fnamemodify(file:sub(1, 1) == "/" and file or (spec.cwd .. "/" .. file), ":p"))
  end
  local this_file = spec.file and absolute(spec.file)

  local function on_line(line)
    local ok, e = false, nil
    if line:sub(1, 1) == "{" then
      ok, e = pcall(vim.json.decode, line)
    end
    if not ok or type(e) ~= "table" then
      table.insert(other, line)
      return
    end
    if e.event ~= "test" or type(e.path) ~= "table" then
      return
    end
    local path = table.concat(e.path, " / ")
    local node = nodes[path]
    status[path] = e.status
    if e.status == "passed" then
      passed = passed + 1
      if buf and node then
        mark(buf, node, " ✓", "DiagnosticOk")
      end
      return
    end
    failed = failed + 1
    local message = e.message or "failed"
    local item = { text = path .. ": " .. message, type = "E" }
    local where = e.location and absolute(e.location.origin)
    if where then
      item.filename, item.lnum, item.col = where, e.location.line, e.location.column
    elseif this_file then
      item.filename, item.lnum = this_file, node and node.range.start.line + 1 or 1
    end
    table.insert(failures, item)
    if buf and node then
      mark(buf, node, " ✗ " .. message:gsub("\n.*", ""), "DiagnosticError")
      local here = where == this_file and e.location
      table.insert(diagnostics, {
        lnum = here and math.max(0, here.line - 1) or node.range.start.line,
        col = here and math.max(0, here.column - 1) or node.range.start.character,
        message = path .. ": " .. message,
        severity = vim.diagnostic.severity.ERROR,
        source = "slang test",
      })
    end
  end

  local function finish(code)
    if buf and vim.api.nvim_buf_is_valid(buf) then
      -- a group passed when all of its tests did
      local function group(nodes_, prefix)
        local result
        for _, node in ipairs(nodes_) do
          local path = prefix and (prefix .. " / " .. node.name) or node.name
          local s = node.kind == "group" and group(node.children or {}, path) or status[path]
          if node.kind == "group" and s then
            status[path] = s
            mark(buf, node, s == "passed" and " ✓" or " ✗", s == "passed" and "DiagnosticOk" or "DiagnosticError")
          elseif s == nil and within(path, spec.only) then
            -- did not run (the file stopped early)
            vim.api.nvim_buf_del_extmark(buf, ns, node.range.start.line + 1)
          end
          if s == "failed" or (s == "passed" and result == nil) then
            result = s
          end
        end
        return result
      end
      group(spec.tests or {}, nil)
      vim.diagnostic.set(ns, buf, diagnostics)
    end
    if passed + failed == 0 and code ~= 0 then
      -- nothing ran: the file does not load
      local items = vim.fn.getqflist({ lines = other, efm = config.errorformat }).items
      items = vim.tbl_filter(function(i)
        return i.valid == 1
      end, items)
      vim.fn.setqflist({}, " ", { title = "slang test", items = items })
      local tail = vim.list_slice(other, math.max(1, #other - 20))
      vim.notify("slang test failed:\n" .. table.concat(tail, "\n"), vim.log.levels.ERROR)
      if #items > 0 then
        vim.cmd("botright cwindow")
        vim.cmd.wincmd("p")
      end
      return
    end
    vim.fn.setqflist({}, " ", { title = "slang test", items = failures })
    if failed == 0 then
      vim.notify(("slang test: %d passed"):format(passed), vim.log.levels.INFO)
    else
      vim.notify(("slang test: %d passed, %d failed"):format(passed, failed), vim.log.levels.WARN)
      vim.cmd("botright cwindow")
      vim.cmd.wincmd("p")
    end
  end

  local pending = ""
  local function on_stdout(_, data)
    if not data then
      return
    end
    pending = pending .. data
    local lines = {}
    for line in pending:gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
    pending = pending:match("[^\n]*$")
    vim.schedule(function()
      for _, line in ipairs(lines) do
        on_line(line)
      end
    end)
  end
  local function on_stderr(_, data)
    if data then
      vim.schedule(function()
        vim.list_extend(other, vim.split(data:gsub("\n$", ""), "\n", { plain = true }))
      end)
    end
  end
  local ok, err = pcall(vim.system, args, { cwd = spec.cwd, stdout = on_stdout, stderr = on_stderr }, function(out)
    vim.schedule(function()
      if pending ~= "" then
        on_line(pending)
      end
      finish(out.code)
    end)
  end)
  if not ok then
    vim.notify("slang: cannot run " .. args[1] .. ": " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function save(buf)
  if vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent update")
    end)
  end
end

-- the tests of the buffer's file; of its project when it is no test file
function M.file(buf)
  if not M.is_test_file(buf) then
    M.project(buf)
    return
  end
  save(buf)
  M.list(buf, function(tests)
    M.run({ file = vim.api.nvim_buf_get_name(buf), buf = buf, tests = tests, cwd = config.root(buf) })
  end)
end

-- the test or group under the cursor
function M.nearest_run(buf, line)
  save(buf)
  M.list(buf, function(tests)
    M.run({
      file = vim.api.nvim_buf_get_name(buf),
      only = M.nearest(tests, line),
      buf = buf,
      tests = tests,
      cwd = config.root(buf),
    })
  end)
end

-- every test of the project (slang test in its folder)
function M.project(buf)
  local dir = config.project(buf) or config.root(buf)
  M.run({ cwd = dir })
end

function M.clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.diagnostic.reset(ns, buf)
end

return M
