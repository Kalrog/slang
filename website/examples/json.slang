// JSON in and out
local json = require("slang/json")
local str = require("slang/string")

local text = """{"users": [{"name": "ada", "admin": true}, {"name": "bob"}]}"""
local data = json.decode(text)
for(let local user in values(data.users)){
  local role = user.admin and "admin" or "user"
  print(str.upper(user.name), ": ", role, "\n")
}
append(data.users, {name: "cy", admin: false})
print(json.encode(data), "\n")
