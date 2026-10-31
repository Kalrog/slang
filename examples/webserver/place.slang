// place(path) -> where one of the program's files is: under
// examples/webserver when it runs from the repository (bin/slang run
// examples/webserver/main.slang), as it is when it was built into an
// executable (slang build: its static files are bundled, its data is in the
// current directory).
local bundle = require("slang/bundle")

return func(path){
  if(bundle.active()){
    return path
  }
  return concat("examples/webserver/", path)
}
