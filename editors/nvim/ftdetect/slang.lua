-- .slang files and slang.project (the server completes, explains and checks
-- its keys); a project's dialect suffixes are added once the server reports them
vim.filetype.add({
  extension = { slang = "slang" },
  filename = { ["slang.project"] = "slang" },
})
