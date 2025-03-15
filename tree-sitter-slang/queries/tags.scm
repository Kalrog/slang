(function_definition_statement 
  name: ([
 (var_ref (name) @name !suffix)
 (var_ref (var_suffix (dot_suffix (name) @name)) .)
         ])
  ) @definition.function
(assignment . ([
 (var_ref (name) @name !suffix)
 (var_ref (var_suffix (dot_suffix (name) @name)) .)
         ]) (expression (function_expression))) @definition.function 
(declaration ([
 (var_ref (name) @name !suffix)
 (var_ref (var_suffix (dot_suffix (name) @name)) .)
         ])
 (expression (function_expression))) @definition.function 

(function_call name:([
 (var_ref (name) @name !suffix)
 (var_ref (var_suffix (dot_suffix (name) @name)) .)
         ]) (name_and_args !name)) @reference.call
(name_and_args name:(_) @name) @reference.call
(prefix_expression . ([
 (var_ref (name) @name !suffix)
 (var_ref (var_suffix (dot_suffix (name) @name)) .)
        ])  (name_and_args !name)) @reference.call
