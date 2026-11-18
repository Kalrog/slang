// slang/pkg: packages: `slang get`, `slang update [name...]`, `slang deps`,
// and their executables: `slang exec`, `slang install`, `slang uninstall`.
//
// A project lists what it uses in its slang.project:
//
//   name: "app",
//   dependencies: {
//     json5: {git: "https://github.com/someone/json5", version: "^1.2"},
//     util: {path: "../util"},
//   },
//
// A package is a git repository whose slang.project gives its name (the
// name it is required by, the same in every project that uses it) and
// whose tags vMAJOR.MINOR.PATCH are its versions. `version: "1.2"` (or
// "^1.2") asks for 1.2.0 or later within major 1 (within 0.2 for a 0.x
// version); a path dependency is a directory, for working on two packages
// at once. `require("json5/parse")` loads parse.slang of the package
// (`require("json5")` its init.slang), compiled under the package's own
// slang.project: its extensions never reach the project that uses it.
//
// Versions are chosen as Go does (minimal version selection): every
// package gets the highest of the minimums asked for it, by the project,
// by other packages, or by slang.lock, which pins what was chosen (the
// version, its commit and a hash of its files). So a build is the same
// until someone asks for more: `slang update` moves the named packages (or
// all) to their newest version within the same major. Two majors of one
// package, or two packages under one name, are errors: one program never
// mixes them.
//
// Packages are fetched with git into the package cache ($SLANG_PKG_DIR,
// else ~/.slang/pkg; a git mirror per repository under .mirrors), one
// directory per version; with the cache complete nothing needs the
// network. Nothing in a package runs when it is fetched: there are no
// install scripts. Compiling a package runs its grammar extensions, as
// compiling any slang does; the hashes in slang.lock pin exactly what that
// is.
//
// A package offers programs in its slang.project:
//
//   executables: {notebook: "bin/notebook.slang"},
//
// `slang exec notebook args...` runs one, and so does `slang notebook
// args...`, as long as no command of slang has the name. The executables
// in reach are those of the project (the nearest slang.project above the
// working directory), of the packages it depends on directly, and of the
// installed packages, found in that order; `package:name` says which
// package is meant. An executable of the project or of one of its
// dependencies runs under the project, as `slang run` of its file would.
//
// `slang install` makes a package's executables available everywhere:
// from a directory (`slang install ../notebook`, no argument for the
// package in the working directory) or a repository (`slang install
// https://... [version]`). An installed package is a project of its own
// under tools/<name> in slang's home ($SLANG_HOME, else ~/.slang): a
// generated slang.project with the one dependency and its slang.lock, so
// what an installed program runs with is pinned like any build. Each
// executable also gets a launcher in the home's bin, a script to put on
// PATH. Installing runs nothing of the package.
local str = require("slang/string")
local os = require("slang/os")
local encoding = require("slang/encoding")
local compiler = require("slang/compiler")
local hash = require("slang/hash")
local regex = require("slang/regex")
local tbl = require("slang/table")

local all_digits = regex.compile("^[0-9]+$")

local pkg = {}

// A version: vMAJOR.MINOR.PATCH.
// type Version = {major: int, minor: int, patch: int, text: string,
//   tag?: string}
// [text]: "1.2.3", without the v
// [tag]: the git tag it was read from, for a repository's versions

// A package of a build list, as [resolve] chooses it.
// type Chosen = {name: string, git?: string, path?: string,
//   version?: Version, dir?: string, manifest?: table,
//   required: {{from: string, asked: string}}, commit?: string, hash?: string}
// [git]: the repository, for a package fetched with git
// [path]: the directory, for a path dependency (then dir is the same)
// [version]: the version chosen, for a package fetched with git
// [dir]: where its files are (a git package's once [get] installed it)
// [manifest]: its slang.project, for a path dependency
// [required]: who asked for it and what they asked for
// [commit]: the commit of its tag, once installed
// [hash]: [tree_hash] of its files, once installed

local func hex(data){
  return encoding.hex.encode(data)
}

// ------------------------------------------------------------ versions

// parse_version(s: string) -> Version?
// Reads "v1.2.3", "1.2" or "^1.2" (missing parts are 0); null for anything
// else, pre-releases included.
func pkg.parse_version(s){
  if(type(s) != "string"){
    return null
  }
  if(str.starts_with(s, "^")){
    s = str.substring(s, 1)
  }
  if(str.starts_with(s, "v")){
    s = str.substring(s, 1)
  }
  local parts = str.split(s, ".")
  if(len(parts) < 1 or len(parts) > 3){
    return null
  }
  local n = {0, 0, 0}
  for(local i = 0; i < len(parts); i = i + 1){
    local p = parts[i]
    if(not all_digits:matches(p)){
      return null
    }
    n[i] = to_int(p)
  }
  return {
    major: n[0], minor: n[1], patch: n[2],
    text: concat(string(n[0]), ".", string(n[1]), ".", string(n[2]))
  }
}

// compare(a: Version, b: Version) -> int
// -1, 0 or 1 as a is lower than b, the same or higher.
func pkg.compare(a, b){
  for(let local k in values({"major", "minor", "patch"})){
    if(a[k] != b[k]){
      return a[k] < b[k] and -1 or 1
    }
  }
  return 0
}

// compatible(a: Version, b: Version) -> bool
// Whether b can stand in for a: the same major (and minor below 1.0). It
// does not compare them: see [compare].
func pkg.compatible(a, b){
  return a.major == b.major and (a.major > 0 or a.minor == b.minor)
}

// ------------------------------------------------------------ git

local func run(argv, cwd){
  local r = try { os.exec(argv, cwd) } catch(local e) {
    raise(error.wrap(e, str.join(argv, " ")))
  }
  if(r.status != 0){
    raise(error.new(error.kinds.error,
      concat(str.join(argv, " "), ": ", str.trim(r.stderr)), {status: r.status}))
  }
  return r.stdout
}

local fetched = {}

local func mirror_dir(url){
  return concat(
    compiler.package_root(),
    "/.mirrors/",
    str.substring(hex(hash.sha256(url)), 0, 16),
  )
}

// the local mirror of a repository: cloned the first time, fetched again
// when refresh is set (once per run)
local func mirror(url, refresh){
  local dir = mirror_dir(url)
  if(not os.exists(dir)){
    os.mkdir_all(concat(compiler.package_root(), "/.mirrors"))
    print("fetching ", url, "\n")
    run({"git", "clone", "--mirror", "--quiet", url, dir})
    fetched[url] = true
  } else if(refresh and not fetched[url]){
    print("fetching ", url, "\n")
    run({"git", "-C", dir, "remote", "update", "--prune"})
    fetched[url] = true
  }
  return dir
}

local func sorted_versions(list){
  return tbl.sort(tbl.slice(list), func(a, b){ return pkg.compare(a, b) < 0 })
}

// the versions of a repository, from its tags, oldest first
local func versions_of(url, refresh){
  local out = {}
  local text = run({"git", "-C", mirror(url, refresh), "tag", "--list", "v*"})
  for(let local line in values(str.split(text, "\n"))){
    local tag = str.trim(line)
    local v = pkg.parse_version(tag)
    if(v != null){
      v.tag = tag
      append(out, v)
    }
  }
  return sorted_versions(out)
}

local func file_at(url, v, file){
  local r = os.exec({
    "git", "-C", mirror(url, false), "show", concat(v.tag, ":", file)
  })
  if(r.status != 0){
    return null
  }
  return r.stdout
}

local func commit_of(url, v){
  return str.trim(run({
    "git", "-C", mirror(url, false), "rev-parse", concat(v.tag, "^{commit}")
  }))
}

// the files of a version, into dest
local func export(url, v, dest){
  os.mkdir_all(dest)
  local tar = concat(dest, ".tar")
  run({
    "git", "-C", mirror(url, false), "archive", "--format=tar", "-o", tar, v.tag
  })
  run({"tar", "-xf", tar, "-C", dest})
  run({"rm", "-f", tar})
}

// ------------------------------------------------------------ hashes

local func sorted_names(list){
  return tbl.sort(tbl.slice(list))
}

// the keys of a table, sorted
local func sorted_keys(t){
  return tbl.sort(tbl.keys(t))
}

// files_under(dir, rel, out) -> out with {rel, path} appended for every file
// under dir, in order (rel is relative to dir, after the prefix rel)
local func files_under(dir, rel, out){
  for(let local name in values(sorted_names(os.list_dir(dir)))){
    local path = concat(dir, "/", name)
    local r = rel == "" and name or concat(rel, "/", name)
    if(os.is_dir(path)){
      files_under(path, r, out)
    } else {
      append(out, {rel: r, path: path})
    }
  }
  return out
}

// files_under(dir: string, rel: string, out: {table}) -> {table}
// out with {rel, path} appended for every file under dir, in name order,
// directories walked; rel is the file's path relative to dir after the
// prefix rel ("" for none).
pkg.files_under = files_under

// tree_hash(dir: string) -> string
// "sha256:..." of the files under dir: their relative paths and contents,
// in order. What slang.lock records to pin a package's files.
func pkg.tree_hash(dir){
  local parts = {}
  for(let local f in values(files_under(dir, "", {}))){
    append(parts, concat(
      f.rel, "\n", hex(hash.sha256(os.read_file(f.path))), "\n"
    ))
  }
  return concat("sha256:", hex(hash.sha256(str.join(parts, ""))))
}

// ------------------------------------------------------------ manifests

local name_re = regex.compile("^[a-z0-9_]+$")

local func check_name(name, where){
  if(type(name) != "string" or not name_re:matches(name)){
    raise(error.new(error.kinds.format, concat(
      where, ": a package name is lowercase letters, digits and _: ",
      string(name)
    )))
  }
  if(name == "slang"){
    raise(error.new(error.kinds.format,
      concat(where, ": the name slang belongs to slang's own library")))
  }
}

local func parse_manifest(text, origin){
  if(text == null){
    return {}
  }
  local t = compiler.compile(concat("return ", text), origin)()
  if(type(t) != "table"){
    raise(error.new(error.kinds.format,
      concat(origin, ": a table literal expected")))
  }
  return t
}

// the requirements a manifest makes: {name, git | path, min, from}
local func requirements_of(manifest, dir, from, allow_path){
  local out = {}
  for(let local e in entries(manifest.dependencies or {})){
    local name = e[0]
    local spec = e[1]
    check_name(name, from)
    if(spec.path != null){
      if(not allow_path){
        raise(error.new(error.kinds.format, concat(
          from, ": ", name,
          ": a package fetched with git cannot depend on a path"
        )))
      }
      local path = spec.path
      if(not str.starts_with(path, "/")){
        path = concat(dir, "/", path)
      }
      append(out, {name: name, path: compiler.absolute_path(path), from: from})
    } else if(spec.git != null){
      local v = pkg.parse_version(spec.version or "0")
      if(v == null){
        raise(error.new(error.kinds.format, concat(
          from, ": ", name, ": a version like \"^1.2\" expected, not ",
          string(spec.version)
        )))
      }
      append(out, {
        name: name, git: spec.git, min: v, from: from,
        asked: spec.version or "any"
      })
    } else {
      raise(error.new(error.kinds.format,
        concat(from, ": ", name, ": {git: url, version} or {path} expected")))
    }
  }
  return out
}

// ------------------------------------------------------------ selection

// the lowest version (the newest, when updating) of a repository that
// stands in for min; fetches once more before giving up
local func pick(url, min, newest, refresh){
  for(local attempt = 0; attempt < 2; attempt = attempt + 1){
    local found = null
    for(let local v in values(versions_of(url, refresh or attempt > 0))){
      if(pkg.compatible(min, v) and pkg.compare(v, min) >= 0){
        if(found == null or newest){
          found = v
        }
      }
    }
    if(found != null){
      return found
    }
    if(fetched[url]){
      break
    }
  }
  raise(error.new(error.kinds.not_found, concat(
    "no version of ", url, " stands in for ", min.text, " (tags v", min.text,
    " and up, same major)"
  )))
}

// resolve(dir: string, manifest: table, lock: table,
//   update?: bool | {[string]: bool}) -> {[string]: Chosen}
// The build list of a project: every package it needs, directly or not,
// by name, with versions chosen by minimal version selection. Fetches the
// repositories it needs into their mirrors, but installs nothing. Raises on
// a conflict (two majors, two packages under one name) or a version no tag
// satisfies.
// [dir]: the project's directory
// [manifest]: its slang.project
// [lock]: its slang.lock ({} without one)
// [update]: null keeps slang.lock's versions; true updates all, a set some
func pkg.resolve(dir, manifest, lock, update){
  local func updating(name){
    return update == true or (update != null and update[name] == true)
  }
  local chosen = {}
  local seen = {}
  local queue = requirements_of(manifest, dir, "slang.project", true)
  for(len(queue) > 0){
    local r = remove(queue, 0)
    local name = r.name
    local existing = chosen[name]
    if(r.path != null){
      if(existing != null and existing.path != r.path){
        raise(error.new(error.kinds.error, concat(
          "package ", name, " is two packages: ", r.path, " (", r.from,
          ") and ", existing.path or existing.git
        )))
      }
      if(existing == null){
        local m_path = concat(r.path, "/slang.project")
        if(not os.exists(r.path)){
          raise(error.new(error.kinds.not_found,
            concat(r.from, ": ", name, ": no directory ", r.path),
            {path: r.path}))
        }
        local m = {}
        if(os.exists(m_path)){
          m = compiler.read_table_file(m_path)
        }
        if(m.name != null and m.name != name){
          raise(error.new(error.kinds.format, concat(
            r.from, ": ", r.path, " is the package ", m.name, ", not ", name
          )))
        }
        chosen[name] = {
          name: name, path: r.path, dir: r.path, manifest: m, required: {}
        }
        for(let local q in values(requirements_of(m, r.path, name, true))){
          append(queue, q)
        }
      }
      append(chosen[name].required, {from: r.from, asked: "path"})
    } else {
      if(existing != null and existing.git != r.git){
        raise(error.new(error.kinds.error, concat(
          "package ", name, " is two packages: ", r.git, " (", r.from, ") and ",
          existing.git or existing.path
        )))
      }
      // the version slang.lock has raises the minimum, unless updating
      local l = lock[name]
      if(l != null and l.git == r.git and not updating(name)){
        local lv = pkg.parse_version(l.version)
        if(lv != null and pkg.compatible(r.min, lv) and
          pkg.compare(lv, r.min) > 0){
          r.min = lv
        }
      }
      local v = pick(r.git, r.min, updating(name), updating(name))
      if(existing != null and not pkg.compatible(existing.version, v)){
        raise(error.new(error.kinds.error, concat(
          "package ", name, " is wanted in two majors: ", existing.version.text,
          " and ", v.text, " (", r.from, "); one program cannot mix them"
        )))
      }
      if(existing == null){
        existing = {name: name, git: r.git, version: v, required: {}}
        chosen[name] = existing
      } else if(pkg.compare(v, existing.version) > 0){
        existing.version = v
      }
      append(existing.required, {from: r.from, asked: r.asked})
      // every version reached adds its requirements (minimal version
      // selection: the highest minimum wins in the end)
      local key = concat(name, "@", v.text)
      if(not seen[key]){
        seen[key] = true
        local m = parse_manifest(
          file_at(r.git, v, "slang.project"),
          concat(name, "@", v.text, "/slang.project"),
        )
        if(m.name != name){
          raise(error.new(error.kinds.format, concat(
            r.git, " at ", v.tag, " is the package ", string(m.name), ", not ",
            name, " (its slang.project names it)"
          )))
        }
        for(let local q in values(
          requirements_of(m, null, concat(name, " ", v.text), false),
        )){
          append(queue, q)
        }
      }
    }
  }
  return chosen
}

// ------------------------------------------------------------ the lock

local func quote(s){
  return concat(
    "\"", str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\""), "\""
  )
}

local func relative(path, dir){
  local d = concat(dir, "/")
  if(str.starts_with(path, d)){
    return str.substring(path, len(d))
  }
  // up from dir until a common directory
  local up = ""
  local base = dir
  for(not str.starts_with(path, concat(base, "/"))){
    local i = len(base) - 1
    for(i > 0 and str.char_at(base, i) != "/"){
      i = i - 1
    }
    base = str.substring(base, 0, i)
    up = concat(up, "../")
    if(base == ""){
      return path
    }
  }
  return concat(up, str.substring(path, len(base) + 1))
}

local func lock_text(chosen, dir){
  local lines = {
    "// slang.lock: the packages this project uses, as slang get chose them.",
    "// Written by slang get and slang update; keep it with the project.",
    "{",
  }
  for(let local name in values(sorted_keys(chosen))){
    local c = chosen[name]
    if(c.path != null){
      append(lines, concat(
        "  [", quote(name), "]: {path: ", quote(relative(c.path, dir)), "},"
      ))
    } else {
      append(lines, concat("  [", quote(name), "]: {"))
      append(lines, concat(
        "    git: ", quote(c.git), ", version: ", quote(c.version.text), ","
      ))
      append(lines, concat("    commit: ", quote(c.commit), ","))
      append(lines, concat("    hash: ", quote(c.hash), ","))
      append(lines, "  },")
    }
  }
  append(lines, "}")
  return concat(str.join(lines, "\n"), "\n")
}

// fetches what the build list needs into the cache, checks it against
// slang.lock and writes the lock
local func install(dir, chosen, lock){
  for(let local name in values(sorted_keys(chosen))){
    local c = chosen[name]
    if(c.git != null){
      local dest = compiler.package_dir(name, c.version.text)
      if(not os.exists(dest)){
        print("installing ", name, " ", c.version.text, "\n")
        export(c.git, c.version, dest)
      }
      c.dir = dest
      c.commit = commit_of(c.git, c.version)
      c.hash = pkg.tree_hash(dest)
      local l = lock[name]
      if(l != null and l.git == c.git and l.version == c.version.text){
        if(l.hash != null and l.hash != c.hash){
          raise(error.new(error.kinds.unauthorized, concat(
            name, " ", c.version.text,
            ": its files are not the ones slang.lock ", "recorded (", l.hash,
            ", now ", c.hash, "); the tag may have moved, ", "or the cache (",
            dest, ") was changed"
          ), {reason: "hash"}))
        }
      }
    }
  }
  os.write_file(concat(dir, "/slang.lock"), lock_text(chosen, dir))
}

// ------------------------------------------------------------ commands

local func find_project(){
  local dir = compiler.absolute_path(".")
  for(true){
    if(os.exists(concat(dir, "/slang.project"))){
      return dir
    }
    if(dir == "/" or dir == ""){
      return null
    }
    local i = len(dir) - 1
    for(i > 0 and str.char_at(dir, i) != "/"){
      i = i - 1
    }
    dir = i == 0 and "/" or str.substring(dir, 0, i)
  }
}

local func load(dir){
  local manifest = compiler.read_table_file(concat(dir, "/slang.project"))
  local lock = {}
  local lock_path = concat(dir, "/slang.lock")
  if(os.exists(lock_path)){
    lock = compiler.read_table_file(lock_path)
  }
  return {manifest: manifest, lock: lock}
}

local func describe(c){
  if(c.path != null){
    return concat(c.name, " (path ", c.path, ")")
  }
  return concat(c.name, " ", c.version.text)
}

local func report(chosen){
  local names = sorted_keys(chosen)
  if(len(names) == 0){
    print("no dependencies\n")
  }
  for(let local name in values(names)){
    print("  ", describe(chosen[name]), "\n")
  }
}

// get(dir: string, update?: bool | {[string]: bool}) -> {[string]: Chosen}
// `slang get` (and `slang update` with update): resolves the build list of
// the project in dir, installs what is missing into the package cache,
// checks the files against slang.lock's hashes and writes slang.lock.
// [update]: as for [resolve]; the named repositories are fetched again
func pkg.get(dir, update){
  local p = load(dir)
  if(update != null){
    // newer tags may exist: ask the repositories again
    for(let local e in entries(p.lock)){
      if(e[1].git != null and (update == true or update[e[0]])){
        mirror(e[1].git, true)
      }
    }
  }
  local chosen = pkg.resolve(dir, p.manifest, p.lock, update)
  install(dir, chosen, p.lock)
  return chosen
}

local func deps(dir){
  local p = load(dir)
  local chosen = pkg.resolve(dir, p.manifest, p.lock, null)
  for(let local name in values(sorted_keys(chosen))){
    local c = chosen[name]
    local by = {}
    for(let local r in values(c.required)){
      append(by, concat(r.from, " (", r.asked, ")"))
    }
    print(describe(c), "\n    required by ", str.join(by, ", "), "\n")
  }
}

// ------------------------------------------------------------ executables

// A program a package offers, as [executables] lists it.
// type Executable = {name: string, package?: string, file: string,
//   project: string, from: string}
// [package]: the package that offers it; null for a project without a name
// [file]: its main file
// [project]: the project file it runs under
// [from]: "project", "dependency" or "installed"

local exe_re = regex.compile("^[a-z0-9][a-z0-9_-]*$")

local func read_manifest(dir){
  local path = concat(dir, "/slang.project")
  if(not os.exists(path)){
    return {}
  }
  return compiler.read_table_file(path)
}

// the executables a manifest declares, appended to out
local func executables_of(manifest, dir, package, project, from, out){
  local list = manifest.executables or {}
  for(let local name in values(sorted_keys(list))){
    local file = list[name]
    if(type(name) != "string" or not exe_re:matches(name) or
      type(file) != "string"){
      raise(error.new(error.kinds.format, concat(
        dir, "/slang.project: executables: ", string(name),
        ": a name of lowercase letters, digits, - and _, and its main file, expected"
      )))
    }
    append(out, {
      name: name, package: package,
      file: compiler.absolute_path(compiler.join_path(dir, file)),
      project: project, from: from
    })
  }
}

// the directory of each direct dependency of the project in dir, by name
// (null for one not fetched): where slang.lock has it, else its path
local func dependency_dirs(dir, manifest){
  local out = {}
  local lock = {}
  local lock_path = concat(dir, "/slang.lock")
  if(os.exists(lock_path)){
    lock = compiler.read_table_file(lock_path)
  }
  for(let local e in entries(manifest.dependencies or {})){
    local name = e[0]
    local l = lock[name]
    local found = null
    if(l != null and l.path != null){
      found = compiler.absolute_path(compiler.join_path(dir, l.path))
    } else if(l != null and l.version != null){
      found = compiler.package_dir(name, l.version)
    } else if(type(e[1]) == "table" and e[1].path != null){
      found = compiler.absolute_path(compiler.join_path(dir, e[1].path))
    }
    if(found != null and not os.is_dir(found)){
      found = null
    }
    out[name] = found
  }
  return out
}

// the executables of the direct dependencies of the project in dir
local func dependency_executables(dir, manifest, from, out){
  local dirs = dependency_dirs(dir, manifest)
  for(let local name in values(sorted_keys(dirs))){
    if(dirs[name] != null){
      executables_of(
        read_manifest(dirs[name]), dirs[name], name,
        concat(dir, "/slang.project"), from, out,
      )
    }
  }
}

local func tools_dir(){
  return concat(compiler.home(), "/tools")
}

local func bin_dir(){
  return concat(compiler.home(), "/bin")
}

// executables() -> {Executable}
// The executables in reach of the working directory, those found first
// first: the project's own, those of its direct dependencies, the
// installed ones. A name may come up more than once: the first is the one
// `slang exec name` runs.
func pkg.executables(){
  local out = {}
  local dir = find_project()
  if(dir != null){
    local manifest = read_manifest(dir)
    executables_of(
      manifest, dir, manifest.name, concat(dir, "/slang.project"), "project",
      out,
    )
    dependency_executables(dir, manifest, "dependency", out)
  }
  local tools = tools_dir()
  if(os.is_dir(tools)){
    for(let local name in values(sorted_names(os.list_dir(tools)))){
      local tool = concat(tools, "/", name)
      if(os.exists(concat(tool, "/slang.project"))){
        dependency_executables(tool, read_manifest(tool), "installed", out)
      }
    }
  }
  return out
}

// find_executable(name: string) -> Executable?
// The executable `slang exec name` runs: the first of [executables] with
// the name; "package:name" takes only that package's. Null when there is
// none.
func pkg.find_executable(name){
  local package = null
  local colon = str.index_of(name, ":")
  if(colon >= 0){
    package = str.substring(name, 0, colon)
    name = str.substring(name, colon + 1)
  }
  for(let local e in values(pkg.executables())){
    if(e.name == name and (package == null or e.package == package)){
      return e
    }
  }
  return null
}

// load_executable(name: string) -> function?
// The main function of the executable [find_executable] finds, loaded as
// `slang run` loads a main file, under the executable's project; null
// when there is no such executable. What `slang exec` calls.
func pkg.load_executable(name){
  local e = pkg.find_executable(name)
  if(e == null){
    return null
  }
  if(not os.exists(e.file)){
    raise(error.new(error.kinds.not_found, concat(
      "executable ", e.name, ": ", e.file, " does not exist"
    ), {path: e.file}))
  }
  compiler.load_project(e.project)
  return compiler.load_main(e.file)
}

local func list_executables(){
  local list = pkg.executables()
  if(len(list) == 0){
    print("no executables: none in this project or its dependencies, none installed\n")
    return
  }
  local seen = {}
  for(let local e in values(list)){
    local label = e.name
    if(seen[e.name]){
      // hidden by an earlier one of the name
      label = concat(e.package or "", ":", e.name)
    }
    seen[e.name] = true
    local where = e.from
    if(e.package != null and e.from != "project"){
      where = concat(e.from, ", package ", e.package)
    }
    print(str.format("%-20s", label), " ", where, "\n")
  }
}

// ------------------------------------------------------------ install

local func is_repository(source){
  return str.contains(source, "://") or str.starts_with(source, "git@") or
    str.ends_with(source, ".git")
}

local func launcher_text(name, package){
  return concat(
    "#!/bin/sh\n",
    "# slang install: ", name, " of the package ", package, "\n",
    "slang=", quote(os.executable()), "\n",
    "[ -x \"$slang\" ] || slang=slang\n",
    // (the home it was installed into, whatever the caller's is)
    "SLANG_HOME=", quote(compiler.absolute_path(compiler.home())), "\n",
    "export SLANG_HOME\n",
    "exec \"$slang\" exec ", name, " \"$@\"\n"
  )
}

// the package a launcher was written for, or null
local func launcher_owner(path){
  if(not os.exists(path)){
    return null
  }
  local marker = " of the package "
  for(let local line in values(str.split(os.read_file(path), "\n"))){
    local i = str.index_of(line, marker)
    if(str.starts_with(line, "# slang install: ") and i >= 0){
      return str.substring(line, i + len(marker))
    }
  }
  return null
}

local func remove_launchers(name, keep){
  local bin = bin_dir()
  if(not os.is_dir(bin)){
    return
  }
  for(let local file in values(sorted_names(os.list_dir(bin)))){
    local path = concat(bin, "/", file)
    if(not keep[file] and launcher_owner(path) == name){
      os.remove(path)
    }
  }
}

// install(source?: string, version?: string) -> {name: string,
//   executables: {Executable}, bin: string}
// Installs a package's executables for every directory: `slang install`.
// The package becomes the one dependency of a project of its own,
// tools/<name> under slang's home, fetched and pinned as [get] does, and
// each executable gets a launcher in the home's bin (given as bin).
// Installing a package again replaces what was installed. Raises when the
// package has no name or no executables.
// [source]: a directory (the working directory by default) or a
//   repository's URL
// [version]: for a repository, the least version wanted ("1.2": the newest
//   within major 1); the newest of all by default
func pkg.install(source, version){
  source = source or "."
  local manifest = null
  local spec = null
  if(is_repository(source)){
    local found = null
    if(version != null){
      local min = pkg.parse_version(version)
      if(min == null){
        raise(error.new(error.kinds.format, concat(
          "a version like \"1.2\" expected, not ", version
        )))
      }
      found = pick(source, min, true, true)
    } else {
      local all = versions_of(source, true)
      if(len(all) == 0){
        raise(error.new(error.kinds.not_found, concat(
          source, " has no versions (tags vMAJOR.MINOR.PATCH)"
        )))
      }
      found = all[len(all) - 1]
    }
    manifest = parse_manifest(
      file_at(source, found, "slang.project"),
      concat(source, "@", found.text, "/slang.project"),
    )
    spec = concat(
      "{git: ", quote(source), ", version: ", quote(concat("^", found.text)), "}"
    )
  } else {
    local dir = compiler.absolute_path(source)
    if(not os.is_dir(dir)){
      raise(error.new(error.kinds.not_found, concat(
        "no directory ", dir, " (a repository is given by its URL)"
      ), {path: dir}))
    }
    manifest = read_manifest(dir)
    spec = concat("{path: ", quote(dir), "}")
  }
  local name = manifest.name
  if(name == null){
    raise(error.new(error.kinds.format, concat(
      source, ": its slang.project gives it no name, so it is no package"
    )))
  }
  check_name(name, source)
  if(count(manifest.executables or {}) == 0){
    raise(error.new(error.kinds.format, concat(
      "package ", name, " has no executables (executables: {name: \"main.slang\"} in its slang.project)"
    )))
  }
  local tool = concat(tools_dir(), "/", name)
  os.mkdir_all(tool)
  os.write_file(concat(tool, "/slang.project"), concat(
    "// made by slang install; slang uninstall ", name, " removes it\n",
    "{\n  dependencies: {\n    [", quote(name), "]: ", spec, ",\n  },\n}\n"
  ))
  // chosen anew: the version asked for now, not the one locked before
  if(os.exists(concat(tool, "/slang.lock"))){
    os.remove(concat(tool, "/slang.lock"))
  }
  local chosen = pkg.get(tool, null)
  local list = {}
  executables_of(
    read_manifest(chosen[name].dir), chosen[name].dir, name,
    concat(tool, "/slang.project"), "installed", list,
  )
  local bin = bin_dir()
  os.mkdir_all(bin)
  local kept = {}
  for(let local e in values(list)){
    local path = concat(bin, "/", e.name)
    local owner = launcher_owner(path)
    if(owner != null and owner != name){
      print(e.name, ": replaces the launcher of the package ", owner, "\n")
    }
    os.write_file(path, launcher_text(e.name, name))
    run({"chmod", "+x", path})
    kept[e.name] = true
  }
  remove_launchers(name, kept)
  return {name: name, executables: list, bin: bin}
}

// uninstall(name: string) -> bool
// Takes back [install]: the package's project under tools and its
// launchers. False when no such package is installed.
func pkg.uninstall(name){
  local tool = concat(tools_dir(), "/", name)
  if(not name_re:matches(name) or not os.is_dir(tool)){
    return false
  }
  remove_launchers(name, {})
  os.remove_all(tool)
  return true
}

local func on_path(dir){
  for(let local part in values(str.split(os.getenv("PATH") or "", ":"))){
    if(part == dir){
      return true
    }
  }
  return false
}

local func install_command(arguments){
  local source = arguments[1]
  local version = arguments[2]
  // url@1.2 as well as url 1.2
  if(source != null and version == null and is_repository(source)){
    local at = str.last_index_of(source, "@")
    if(at > 0 and pkg.parse_version(str.substring(source, at + 1)) != null){
      version = str.substring(source, at + 1)
      source = str.substring(source, 0, at)
    }
  }
  local r = pkg.install(source, version)
  local names = {}
  for(let local e in values(r.executables)){
    append(names, e.name)
  }
  print("installed ", r.name, ": ", str.join(names, ", "), "\n")
  print("run with `slang ", names[0], "`")
  if(not on_path(r.bin)){
    print("; with ", r.bin, " on PATH, as `", names[0], "`")
  }
  print("\n")
}

local USAGE = concat(
  "usage: slang get | slang update [package...] | slang deps\n",
  "       slang exec [[package:]name [args...]]\n",
  "       slang install [dir | url [version]] | slang uninstall package\n"
)

// main(arguments: {string}) -> int: the exit code
// The commands: {"get"}, {"update", names...} or {"deps"}, for the project
// in the working directory or the nearest one above it; {"exec"} (lists
// the executables: slang itself runs one), {"install", source?, version?}
// and {"uninstall", name}.
func pkg.main(arguments){
  local command = arguments[0]
  local dir = find_project()
  local anywhere = command == "exec" or command == "install" or
    command == "uninstall"
  if(dir == null and not anywhere){
    os.write_stderr("no slang.project here or in a directory above\n")
    return 1
  }
  try {
    if(command == "exec"){
      list_executables()
    } else if(command == "install"){
      install_command(arguments)
    } else if(command == "uninstall"){
      if(arguments[1] == null){
        os.write_stderr(USAGE)
        return 2
      }
      if(not pkg.uninstall(arguments[1])){
        os.write_stderr(concat(
          "slang uninstall: no package ", arguments[1], " is installed\n"
        ))
        return 1
      }
      print("uninstalled ", arguments[1], "\n")
    } else if(command == "get"){
      report(pkg.get(dir, null))
      print("slang.lock written\n")
    } else if(command == "update"){
      local names = null
      for(local i = 1; i < len(arguments); i = i + 1){
        names = names or {}
        names[arguments[i]] = true
      }
      report(pkg.get(dir, names or true))
      print("slang.lock written\n")
    } else if(command == "deps"){
      deps(dir)
    } else {
      os.write_stderr(USAGE)
      return 2
    }
    return 0
  } catch(local e) {
    os.write_stderr(concat("slang ", command, ": ", error.message(e), "\n"))
    return 1
  }
}

return pkg
