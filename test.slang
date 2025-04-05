-{block:require("extensions/parser_syntax")}
local p = require("slang/parser")

local c_struct = parser{
  start -> struct_def
  struct_def -> ("struct" identifier "{" field* "}") P(name:1,fields:3)
  field -> (type identifier ";") P(type:0,name:1)
  type -> primitive_type (array| pointer)*
  primitive_type -> "int" | "float" | "char" | "bool" | "void"
  array -> ("[" integer "]") P(index:1)
  pointer -> "*"
  integer -> [0-9]+_
  identifier -> ([a-zA-Z_][a-zA-Z0-9_]*)_
}

print(c_struct:parse("""
struct car{
  int id;
  char* name;
  float price;
  bool is_sold;
  int*[5]  parts;
}
"""))