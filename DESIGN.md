# Slang
## Macros
### Lisp Style Macros
Code is loaded in "Layers" (not sure if this is the actual term just writing down what i remember), each layer can take quoted code from the previous layer is input, and output new code. This way we can construct new kinds of operations using the code of previous layers. Lisp can do this because even if some operator is not known to lisp, it will always be written as a list (operator ...operands) so it can always be parsed.
- Parse everything first
- Take the highest layer, convert it's lists to executable functions, execute them, putting any defines in there into the enviromnment
- Continue with the next layer (the enviromnet now contain the defines from the previous layer, some of which may manipulate the code of this layer)

Problems: 
- Requires one unchanging syntax that the parser can always understand or some way of ignoring lower layer code until changes to the parser have been made that allow that code the be understood.
  - Maybe we can go the other way around? Have some special section that marks a section of the code as being a "lower layer" that would be skipped by the parser at first and would be parsed once the current layer has finished it's work => Problem, how would this work in packages? how to import a macro? Easy if the import can define a higher layer, hard if the imported programm has to define itself as a lower layer...
- How to handle imports? Want macros to appear immediately before the rest of the code is parsed, so maybe required function needs to be some ∞-layer macro ? ensure it's always executed first, then the rest of the code is parsed / executed

Universal syntax:
function call -> identifier '(' params ')' block? | identifier block
block -> '{' (statement ';'?)* '}'
params -> (expr,(',' expr)*)?

#### Use Case: Adding switch case
```slang
local node = ast.root; ///use case: processing ast
/// Before the macro is loaded this would be read as
/// function call(params('node'),block(...))
switch(node){
  //currently would fail to parse 'local body'... maybe switch with variable assignment is not possible?
  // rest of the case would be parsed as a function call
  case({type:'block',local body}){
    ...
  }
  ...
}
```
no having a switch case with pattern matching that allows for variable assignment is a problem, currently this is supported by slang for if statements so switch should be abled to do it, otherwise the macro system is weaker than the language is originally

Maybe something like a block that quotes it's content would be a solution?
```slang
quoteblock -> '!' block
```
We can just treat the whole block as something that we don't parse for now and parse after some point when we have finished our modification of the parser to understand the content of the block (again layering "downwards" instead of "upwards")

#### Layering upwards
- Parse everything first, either ignore unknown syntax or use some universal syntax (like lisp)
- Find highest layer (this means the layer that is the deepest macro definition, so maybe a macro that is used to define other macros)
- Execute the code of that layer, putting any defines into the enviroment and modifying the parser
- reparse the code with the new parser and (somehow) keep in mind that we are done with the current layer
- repeat with the next layer

possible `ayer syntax:
``` ebnf 
syntax layer -> 'syntax' block
``` 
Example:

``` slang
syntax {
  parser.addStatement('switch',func(){
    return seq(
      token('switch'),
      token('('),
      ref('expr'),
      token(')'),
      ref('switch_body'),
    );
  });
  parser.add('switch_body',func(){
    return seq(
      token('{'),
      (ref('case') | ref('default')).star(),
      token('}')
    );
  });
  parser.add('case',func(){
    return seq(
      token('case'),
      ref('pattern'),
      token(':'),
      ref('chunk'),
    );
  });
  parser.add('default',func(){
    return seq(
      token('default'),
      token(':'),
      ref('chunk'),
    );
  });
}

somevalue = {type:"hello",value:"world"};
switch(somevalue){
  case({type:'hello',value:'world'}){
    print('hello world');
  }
  default:{
    print('default');
  }
}
```
This example is missing the actual implementation of the switch statement, which would be done by mapping the results of the parser to an ast that the basic interpreter can understand.
For example:
``` slang
for(let local value in list){
  print(value);
}
```
would be mapped to the following basic syntax
``` slang
{ //outer block to ensure correct scope for local variables
  local ittr = iterator(list);
  for(local value = ittr.next(); value != null; value = ittr.next()){
    print(value);
  } 
}
```
This could be done using a printf like template function
``` slang
  templ = syntax_template("""
  { 
    local ittr = iterator(%list:expr%);
    for(local %value:name% = ittr.next(); %value:name% != null; %value:name% = ittr.next())
      %for_in_body:block%
  }
  """) // this would parse the template into a preliminary ast that has placeholders where the actual parsed asts from the code can be inserted, the %name:type% format specifies both the type that the placeholder should be regarded as and the type of ast node that must be inserted there in the final ast (this allows the parser to check if the ast template is correct even before the actual value are inserted) it also means the values are not inserted as strings but as actual ast nodes. The syntax templates can also contain any special syntax defined in a layer that was previously loaded
```

### Metalua
Add modifications to the parser and lexer, can then transform those into lua code. For these to work the load order has to be such that it's guaranteed that the parser modifications are loaded first.
Do we rerun the parser completely once a modification was made?
Maybe we can write a robust parser that can deal with unknown syntax and just continue and ignore it? 


#### Quoting
```ebnf
quote -> '+' quoteblock
quoteblock -> '{' ast_type ':' ast_node '}' //ast_node must be an ast node of the type ast_type
splice -> '-' quoteblock
```

Where the quote means:
parse the contents and return the ast node that represents the contents of this block
and splice means:
Evaluate the contents of this block during parsing and insert the resulting ast node into the ast that is currently being built by the parser