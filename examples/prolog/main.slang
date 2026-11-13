// The Prolog toplevel.
//
//   bin/slang run examples/prolog/main.slang [file.pl ...] [-g Goal ...]
//
// Consults the files, runs the -g goals (and exits when there were any),
// else asks for queries at a ?- prompt. After an answer that may have
// more, type ; (and return) for the next one, or just return to stop.
// halt. or the end of input leaves.
local prolog = require("prolog")
local engine = require("engine")
local os = require("slang/os")
local str = require("slang/string")

local system = prolog.new()

// error_text(e) -> what to show for an error raised by a query
local func error_text(e){
  if(error.is(e, "prolog")){
    return prolog.error_message(e.ball, system.db.ops)
  }
  return error.message(e)
}

// read_query() -> the text of the next query, read until a line ends with
// "." (a query may span lines); null at the end of input
local func read_query(){
  print("?- ")
  local text = ""
  for(true){
    local line = os.read_line()
    if(line == null){
      if(str.trim(text) == ""){
        return null
      }
      return text
    }
    text = concat(text, line, "\n")
    local trimmed = str.trim(text)
    if(str.ends_with(trimmed, ".")){
      return trimmed
    }
    if(trimmed != ""){
      print("|    ")
    }
  }
}

// run(text, interactive) shows the answers of a query: all of them on
// demand when interactive, else only the first
local func run(text, interactive){
  local answers = null
  try {
    answers = system:query(text)
  } catch(local e) {
    print(error_text(e), "\n")
    return
  }
  try {
    for(true){
      if(not answers.next()){
        print("false.\n")
        break
      }
      local shown = answers.text()
      if(not interactive or not answers.has_more()){
        print(shown, ".\n")
        break
      }
      print(shown, " ")
      local reply = os.read_line()
      if(reply == null or not str.starts_with(str.trim(reply), ";")){
        print(".\n")
        break
      }
      print(";\n")
    }
  } catch(local e) {
    if(error.is(e, "halt")){
      raise(e)
    }
    print(error_text(e), "\n")
  }
  answers.close()
}

local func main(){
  local argv = args()
  local goals = {}
  local i = 0
  for(i < len(argv)){
    if(argv[i] == "-g" and i + 1 < len(argv)){
      append(goals, argv[i + 1])
      i = i + 2
    } else {
      system:consult_file(argv[i])
      i = i + 1
    }
  }
  if(len(goals) > 0){
    for(let local goal in values(goals)){
      run(goal, false)
    }
    return
  }
  print("Prolog in slang. Type a query ending in \".\"; halt. leaves.\n")
  for(true){
    local text = read_query()
    if(text == null){
      print("\n")
      return
    }
    run(text, true)
  }
}

try {
  main()
} catch(local e) {
  if(error.is(e, "halt")){
    os.exit(e.status)
  }
  raise(e)
}
