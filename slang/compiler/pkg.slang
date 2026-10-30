// slang/pkg: packages: `slang get`, `slang update [name...]`, `slang deps`.
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
local str = require("slang/string")
local os = require("slang/os")
local encoding = require("slang/encoding")
local compiler = require("slang/compiler")

local pkg = {}

local func hex(data){
  return encoding.hex_encode(data)
}

// ------------------------------------------------------------ versions

// parse_version("v1.2.3" | "1.2" | "^1.2") -> {major, minor, patch, text},
// or null for anything else (pre-releases included)
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
    if(len(p) == 0 or str.class_run(str.char_class("0-9"), p, 0) != len(p)){
      return null
    }
    n[i] = to_int(p)
  }
  return {
    major: n[0], minor: n[1], patch: n[2],
    text: concat(string(n[0]), ".", string(n[1]), ".", string(n[2])),
  }
}

func pkg.compare(a, b){
  for(let local k in values({"major", "minor", "patch"})){
    if(a[k] != b[k]){
      return a[k] < b[k] and - 1 or 1
    }
  }
  return 0
}

// whether b can stand in for a: the same major (and minor below 1.0)
func pkg.compatible(a, b){
  return a.major == b.major and (a.major > 0 or a.minor == b.minor)
}

// ------------------------------------------------------------ git

local func run(argv, cwd){
  local r = os.exec(argv, cwd)
  if(r.status != 0){
    error(str.join(argv, " "), ": ", str.trim(r.stderr))
  }
  return r.stdout
}

local fetched = {}

local func mirror_dir(url){
  return concat(
    compiler.package_root(),
    "/.mirrors/",
    str.substring(hex(encoding.sha256(url)), 0, 16)
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
  local out = {}
  for(let local v in values(list)){
    local i = len(out)
    append(out, v)
    for(i > 0 and pkg.compare(out[i - 1], v) > 0){
      out[i] = out[i - 1]
      i = i - 1
    }
    out[i] = v
  }
  return out
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
    "git", "-C", mirror(url, false), "show", concat(v.tag, ":", file),
  })
  if(r.status != 0){
    return null
  }
  return r.stdout
}

local func commit_of(url, v){
  return str.trim(run({
    "git", "-C", mirror(url, false), "rev-parse", concat(v.tag, "^{commit}"),
  }))
}

// the files of a version, into dest
local func export(url, v, dest){
  os.mkdir_all(dest)
  local tar = concat(dest, ".tar")
  run({
    "git", "-C", mirror(url, false), "archive", "--format=tar", "-o", tar, v.tag,
  })
  run({"tar", "-xf", tar, "-C", dest})
  run({"rm", "-f", tar})
}

// ------------------------------------------------------------ hashes

local func sorted_names(list){
  local out = {}
  for(let local s in values(list)){
    local i = len(out)
    append(out, s)
    for(i > 0 and str.compare(out[i - 1], s) > 0){
      out[i] = out[i - 1]
      i = i - 1
    }
    out[i] = s
  }
  return out
}

// the keys of a table, sorted
local func sorted_keys(t){
  local list = {}
  for(let local k in keys(t)){
    append(list, k)
  }
  return sorted_names(list)
}

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

// tree_hash(dir) -> "sha256:..." of the files under dir: their paths and
// contents, in order
func pkg.tree_hash(dir){
  local parts = {}
  for(let local f in values(files_under(dir, "", {}))){
    append(parts, concat(
      f.rel, "\n", hex(encoding.sha256(os.read_file(f.path))), "\n"
    ))
  }
  return concat("sha256:", hex(encoding.sha256(str.join(parts, ""))))
}

// ------------------------------------------------------------ manifests

local name_class = str.char_class("a-z0-9_")

local func check_name(name, where){
  if(type(name) != "string" or len(name) == 0 or
    str.class_run(name_class, name, 0) != len(name)){
    error(
      where, ": a package name is lowercase letters, digits and _: ",
      string(name)
    )
  }
  if(name == "slang"){
    error(where, ": the name slang belongs to slang's own library")
  }
}

local func parse_manifest(text, origin){
  if(text == null){
    return {}
  }
  local t = compiler.compile(concat("return ", text), origin)()
  if(type(t) != "table"){
    error(origin, ": a table literal expected")
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
        error(
          from, ": ", name,
          ": a package fetched with git cannot depend on a path"
        )
      }
      append(out, {
        name: name, path: compiler.absolute_path(concat(dir, "/", spec.path)),
        from: from,
      })
    } else if(spec.git != null){
      local v = pkg.parse_version(spec.version or "0")
      if(v == null){
        error(
          from, ": ", name, ": a version like \"^1.2\" expected, not ",
          string(spec.version)
        )
      }
      append(out, {
        name: name, git: spec.git, min: v, from: from,
        asked: spec.version or "any",
      })
    } else {
      error(from, ": ", name, ": {git: url, version} or {path} expected")
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
  error(
    "no version of ", url, " stands in for ", min.text, " (tags v", min.text,
    " and up, same major)"
  )
}

// resolve(dir, manifest, lock, update) -> the build list {name: {name,
// git, version, path, dir, manifest, required}}, version a parsed version;
// update is null (keep slang.lock's versions), true (everything) or
// {name: true}
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
        error(
          "package ", name, " is two packages: ", r.path, " (", r.from,
          ") and ", existing.path or existing.git
        )
      }
      if(existing == null){
        local m_path = concat(r.path, "/slang.project")
        if(not os.exists(r.path)){
          error(r.from, ": ", name, ": no directory ", r.path)
        }
        local m = {}
        if(os.exists(m_path)){
          m = compiler.read_table_file(m_path)
        }
        if(m.name != null and m.name != name){
          error(
            r.from, ": ", r.path, " is the package ", m.name, ", not ", name
          )
        }
        chosen[name] = {
          name: name, path: r.path, dir: r.path, manifest: m, required: {},
        }
        for(let local q in values(requirements_of(m, r.path, name, true))){
          append(queue, q)
        }
      }
      append(chosen[name].required, {from: r.from, asked: "path"})
    } else {
      if(existing != null and existing.git != r.git){
        error(
          "package ", name, " is two packages: ", r.git, " (", r.from, ") and ",
          existing.git or existing.path
        )
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
        error(
          "package ", name, " is wanted in two majors: ", existing.version.text,
          " and ", v.text, " (", r.from, "); one program cannot mix them"
        )
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
          concat(name, "@", v.text, "/slang.project")
        )
        if(m.name != name){
          error(
            r.git, " at ", v.tag, " is the package ", string(m.name), ", not ",
            name, " (its slang.project names it)"
          )
        }
        for(let local q in values(
          requirements_of(m, null, concat(name, " ", v.text), false)
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
          error(
            name, " ", c.version.text,
            ": its files are not the ones slang.lock ", "recorded (", l.hash,
            ", now ", c.hash, "); the tag may have moved, ", "or the cache (",
            dest, ") was changed"
          )
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

// get(dir) -> the build list, installed and locked
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

local USAGE = "usage: slang get | slang update [package...] | slang deps\n"

// main(command, args) -> exit code
func pkg.main(arguments){
  local command = arguments[0]
  local dir = find_project()
  if(dir == null){
    os.write_stderr("no slang.project here or in a directory above\n")
    return 1
  }
  local r = pcall(func(){
    if(command == "get"){
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
  })
  if(r[0] == "err"){
    local e = r[1]
    os.write_stderr(concat(
      "slang ", command, ": ", type(e) == "table" and e.message or string(e),
      "\n"
    ))
    return 1
  }
  return r[1]
}

return pkg
