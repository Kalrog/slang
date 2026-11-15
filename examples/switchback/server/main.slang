// The daily run's server: Switchback's site (make switchback-web) and
// everyone's times of the day, kept in SQLite.
//
//   make switchback-daily
//   bin/slang run examples/switchback/server/main.slang [port] [site] [database]
//
// By default port 8080, the site in examples/switchback/web and the
// times in examples/switchback/daily.db. It listens on 127.0.0.1; put it
// behind the web server that faces the world (which adds TLS).
local async = require("slang/async")
local os = require("slang/os")
local store = require("server/store")
local app_lib = require("server/app")
local day = require("server/day")

local argv = args()
local port = to_int(argv[0] or "8080")
local site = argv[1] or "examples/switchback/web"
local database = argv[2] or "examples/switchback/daily.db"
if(not os.exists(concat(site, "/index.html"))){
  os.write_stderr(concat("no site in ", site, ": make switchback-web first\n"))
  os.exit(1)
}

local s = store.open(database)
local app = app_lib.app({store: s, site: site})
async.main(func(){
  local server = app:listen("127.0.0.1", port)
  local today = day.today()
  print("switchback daily: day ", today.day, " (", today.date, ", valley ", today.seed,
    ") at http://127.0.0.1:", server.port, "/, times in ", database, "\n")
  async.await(server.done)
})
