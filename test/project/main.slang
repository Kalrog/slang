// compiled under test/project/slang.project by test/project_test.slang
local data = require("data")
local m = require("module")
return {
  doubled: twice 21, name: data.name, list: data.list, module: m.value,
  plain: m.plain
}
