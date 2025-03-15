         
         

[
  "func" 
  "local" 
  "if" 
  "else" 
  "return" 
  "for" 
]@keyword
(function_definition_statement name:([
 (var_ref (name) @function !suffix)
 (var_ref (var_suffix (dot_suffix (name) @function)) .)
         ]))
(name_and_args name:(name) @function.method)
(prefix_expression  [
 (var_ref (name) @function !suffix)
 (var_ref (var_suffix (dot_suffix (name) @function)) .)
         ] . (name_and_args !name))
(function_call name:[
 (var_ref (name) @function !suffix)
 (var_ref (var_suffix (dot_suffix (name) @function)) .)
         ]. (name_and_args !name))
(declaration "local" (var_ref) @variable)
(declaration (var_ref) @variable)
(var_pattern (name) @variable)
(assignment (var_ref) @variable)
(params (name) @variable.parameter)
(field_key (name) @identifier)
(string) @string
[
  "+"
  "-"
  "*"
  "/"
  "%"
  "="
  "=="
  "!="
  "<"
  ">"
  "<="
  ">="
  "and"
  "or"
  "not"
] @operator
(dot_suffix (name) @property)
(bracket_suffix (expression) @index)
[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  "."
  ":"
  ","
] @punctuation.delimiter
[
  (true)
  (false)
] @boolean
(string) @string
[
 (int)
 (double)
]@number

(null) @constant.null


