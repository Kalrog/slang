local args_list = args();

for(let local path in values(args_list)) {
    local file = open(path, "r")
    local content = file:read()
    file:close()
    print(content)
}


