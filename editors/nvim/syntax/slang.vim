" Vim syntax file for slang: the core language, as the VS Code grammar
" (editors/vscode/syntaxes) colours it. The language server's semantic
" tokens go over it with the real parser's view, extensions and dialects
" included.
if exists("b:current_syntax")
  finish
endif

syn keyword slangTodo contained TODO FIXME XXX NOTE
syn match slangComment "//.*$" contains=slangTodo,@Spell

syn match slangEscape contained "\\\(x\x\x\|u{\x\+}\|.\)"
syn region slangString start=+"+ skip=+\\.+ end=+"+ contains=slangEscape,@Spell
syn region slangString start=+"""+ end=+"""+ contains=@Spell

syn match slangNumber "\v<(0[xX]\x(_?\x)*|0[oO]\o(_?\o)*|0[bB][01](_?[01])*|\d(_?\d)*(\.\d(_?\d)*)?([eE][+-]?\d(_?\d)*)?)>"

" -{ and +{: quoted code
syn match slangQuote "[+-]{"

syn match slangCall "\v<\h\w*\ze\s*\("
syn match slangFuncName "\v(<func\s+)@<=\h[A-Za-z0-9_.:]*"

syn keyword slangConditional if else
syn keyword slangRepeat for in let
syn keyword slangStatement return break continue
syn keyword slangException try catch defer
syn keyword slangStorage local func extension global
syn keyword slangConstant true false null
syn keyword slangWordOperator and or not

hi def link slangTodo Todo
hi def link slangComment Comment
hi def link slangEscape SpecialChar
hi def link slangString String
hi def link slangNumber Number
hi def link slangQuote Special
hi def link slangCall Function
hi def link slangFuncName Function
hi def link slangConditional Conditional
hi def link slangRepeat Repeat
hi def link slangStatement Statement
hi def link slangException Exception
hi def link slangStorage StorageClass
hi def link slangConstant Constant
hi def link slangWordOperator Operator

let b:current_syntax = "slang"
