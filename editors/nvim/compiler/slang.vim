" :compiler slang: :make runs `slang test` (:make build, :make run x.slang
" and so on run those); errors and failed tests go to the quickfix list
if exists("current_compiler")
  finish
endif
let current_compiler = "slang"

CompilerSet makeprg=slang\ test
execute "CompilerSet errorformat=" .. escape(luaeval('require("slang.config").errorformat'), ' \|"')
