# Slang
scripting language written in dart
heavily inspired by lua

## Syntax
### Variables
```slang
// are automatically declared when assigned to
a = 1
b = 2
// are global by default
if (true) {
    c = 3
}
print(a, b, c) // 1 2 3
// can be declared as local
if (true) {
    local d = 4
    print(d) // 4
}
print(d) // null
```
### Types
```slang
// integers
a = 1
// floats
b = 1.0
// strings
c = "hello"
// booleans
d = true
// null
e = null
// tables
f = {a: 1, b: 2, 3,4}
// functions
g = function() {
    print("hello")
}
```
### Operators
```slang
// arithmetic
+ - * / % ^
// comparison
== != < > <= >=
// logical
and or not
```
### Control Flow
```slang
// if
if (true) {
    print("true")
} else if (false) {
    print("false")
} else {
    print("else")
}

// for
for(i = 0; i < 10; i = i + 1) {
    print(i)
}
//but also
run = true
for(run){
    print("running")
}
// and
local i = len(list)
for(i >= 0; i = i - 1){
    print(list[i])
}
for([init(optional)]; [condition]; [update(optional)]){
    // body
}
```
### Functions
```slang
// normal
func add(a, b) {
    return a + b
}
// anonymous (normal is acutally just a shorthand for this)
add = func(a, b) {
    return a + b
}
// varargs
func add(a, b, ...more) {
    sum = a + b
    for(i = 0; i < len(more); i = i + 1) {
        sum = sum + more[i]
    }
    return sum
}
```
### Tables
```slang
// can be used as arrays
a = {1, 2, 3}
print(a[0]) // 1
// can be used as maps
b = {a: 1, b: 2}
print(b["a"]) // 1
// can be used as structures
c = {a: 1, b: 2}
print(c.a) // 1
// have a special element called "meta" which can be used to define operators on the table
vector = {}
func vector.add(a, b) {
    return {x: a.x + b.x, y: a.y + b.y}
}
a = {x: 1, y: 2}
a.meta = vector
b = {x: 3, y: 4}
a.add(a,b)
// special shorthand for functions whos first argument is the table they are inside of
// think of it as a method
a:add(b)
// this will be very familiar to lua users
```
### Pattern Matching
```slang
// matches a value against a pattern
patient = {name: "John", age: 30}
print(let {name: "John"} = patient) // true
// can assign value from the pattern to variables
if (let {name: name, age: 30} = patient) {
    print("the 30 year old patient is called", name) // the 30 year old patient is called John
}
// can be used in for loops
patients = [{name: "John", age: 30}, {name: "Jane", age: 40}]
for({name: local name, age: local age} in values(patients)) {
    print(name, "is", age, "years old")
}
// loops stop when they encounter a value that does not match the pattern
patients = [{name: "John", age: 30}, {name: "Jane", age: 40}{name: "John", age: 45},]
for({name: "John", age: local age} in values(patients)) {
    print(name, "is", age, "years old") // Would only print once
}
```
### Passing Functions as arguments
```slang
// Some functions take a function as an argument
run(func(){
  ... //do something  
})
// if the function is the last argument passed and takes no arguments there is a special syntax for this
run{
    ... //do something
}
// these two ways of writing it are equivalent
// the standard library includes some functions that use this to structure code

// module, allows you to declare global functions in a block and capture them in a table (called a module)
calc = module{
    func add(a,b){
        return a + b
    }
    func sub(a,b){
        return a - b
    }
    local func private(){
        print("this function is not visible in the calc module")
    }
}
// run allows you to treat a block of statements as an expression
a = run{
    print("current a: ",a)
    return a
} + 1
```


## Ideas
- [-] add run time type checks
    - [x] check if patterns can be matched against table
    - [ ] allow for type check as part of patterns
- [x] add varargs 
- [x] multitasking
    - [x] cooperative (coroutines,yield,resume)
    - [x] preemptive (threads,atomic,semaphores,channels)
- [ ] user data (like in lua)
- [ ] bitwise operators
- [ ] break/continue
- [ ] metaprogramming
    - [ ] macros?
    - [ ] reflection (for functions)
    - [ ] manipulate AST, add to grammar
- [ ] add static typing
    - [ ] struct types
    - [ ] function types
    - [ ] type inference
    - [ ] interfaces
    - [ ] generics
- [ ] write language server

