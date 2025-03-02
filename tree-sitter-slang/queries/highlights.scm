
"func" @keyword
"local" @keyword
"if" @keyword
"else" @keyword
"return" @keyword
"for" @keyword
(functionDefinitionStatement name:(varRef) @function)
(functionCall name:(varRef) @function (nameAndArgs !name))
(nameAndArgs name:(_) @function.method)
(prefixExpression . (varRef) @function (nameAndArgs !name))
(assignment "local" (varRef) @variable)
(params (name) @variable.parameter)
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
(dotSuffix (name) @property)
(bracketSuffix (expression) @index)
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
] @punctuation
[
  (true)
  (false)
  (null)
] @constant


