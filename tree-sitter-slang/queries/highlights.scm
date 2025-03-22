

([
  "func" 
  "local" 
  "if" 
  "else" 
  "return" 
  "for" 
] @keyword (#set! "priority" 200))

(function_definition_statement name:([
 (var_ref (name) @function !suffix)
 (var_ref (var_suffix (dot_suffix (name) @function)) .)
        ]) (#set! "priority" 200))
(name_and_args name:(name) @function.method (#set! "priority" 200))
(prefix_expression  [
 (var_ref (name) @function !suffix)
 (var_ref (var_suffix (dot_suffix (name) @function)) .)
        ] . (name_and_args !name) (#set! "priority" 200))
(function_call name:[
 (var_ref (name) @function !suffix)
 (var_ref (var_suffix (dot_suffix (name) @function)) .)
        ]. (name_and_args !name) (#set! "priority" 200))
(declaration "local" (var_ref) @variable (#set! "priority" 200))
(declaration (var_ref) @variable (#set! "priority" 200))
(var_pattern (name) @variable (#set! "priority" 200))
(assignment (var_ref) @variable (#set! "priority" 200))
(params (name) @variable.parameter (#set! "priority" 200))
(field_key (name) @identifier (#set! "priority" 200))
((string) @string (#set! "priority" 200)) 
([
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
] @operator (#set! "priority" 200))
(dot_suffix (name) @property (#set! "priority" 200))
(bracket_suffix (expression) @index (#set! "priority" 200))
(
[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket (#set! "priority" 200))
(
[
  "."
  ":"
  ","
  "=>"
] @punctuation.delimiter (#set! "priority" 200))
(
[
  (true)
  (false)
] @boolean (#set! "priority" 200))
((string) @string (#set! "priority" 200))
(
[
 (int)
 (double)
]@number (#set! "priority" 200))

(
(null) @constant.null (#set! "priority" 200))


