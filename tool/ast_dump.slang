// prints the AST of a file as parsed by the self-hosted parser (see tool/ast_oracle.sh)
local compiler = require("slang/compiler")
local ast = require("slang/ast")
local os = require("slang/os")
local path = args()[0]
print(ast.to_string(compiler.parse(os.read_file(path), path)), "\n")
