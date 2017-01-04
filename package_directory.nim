#
# Nimble package directory
#
# Copyright 2016 Federico Ceratto <federico.ceratto@gmail.com>
# Released under GPLv3 License, see LICENSE file
#

from algorithm import sort, sorted, sortedByIt
from times import epochTime
import asyncdispatch,
 httpclient,
 httpcore,
 json,
 logging,
 os,
 osproc,
 parseopt,
 sequtils,
 streams,
 strutils,
 tables,
 times

from htmlgen import pre

#from nimblepkg import getTagsListRemote, getVersionList
import jester

import github,
  signatures,
  email,
  persist


const
  template_path = "./templates"
  timeout = 60
  github_readme_tpl = "https://api.github.com/repos/$#/readme"
  github_tags_tpl = "https://api.github.com/repos/$#/tags"
  github_latest_version_tpl = "https://api.github.com/repos/$#/releases/latest"
  github_doc_index_tpl = "https://$#.github.io/$#/index.html"
  github_readme_header = "Accept:application/vnd.github.v3.html\c\L"
  github_caching_time = 600
  #github_caching_time = 2 #FIXME
  git_bin_path = "/usr/bin/git"
  nim_bin_path = "/usr/bin/nim"
  nimble_bin_path = "/usr/bin/nimble"
  tmp_nimble_root_dir = "/dev/shm/nim_package_dir"
  build_expiry_time = 300.Time # 5 mins
  cache_fn = ".cache.json"

# init

let conf = parseFile("conf.json")
let github_token = "Authorization: token $#\c\L" % conf["github_token"].str
let packages_list_fname = conf["packages_list_fname"].str
var port = if conf.has_key("port"): conf["port"].getNum.Port else: 5000.Port

# parse CLI opts

for kind, key, val in getopt():
  case kind
  of cmdShortOption:
    case key
    of "p": port = val.parseInt.Port
  else: discard


let fl = newFileLogger(conf["log_fname"].str, fmtStr = "$datetime $levelname ")
fl.addHandler

proc log_debug(args: varargs[string, `$`]) =
  debug args
  fl.file.flushFile()

proc log_info(args: varargs[string, `$`]) =
  info args
  fl.file.flushFile()

type
  ProcessError = object of Exception
  Pkg* = JsonNode
  strSeq = seq[string]
  PkgName = distinct string
  PkgBuildStatus {.pure.} = enum OK, Failed, Timeout
  PkgDocMetadata = ref object of RootObj
    fnames: strSeq
    ready: bool
    expire_time: Time
    last_commitish: string
    build_output: string
    build_status: PkgBuildStatus
    version: string
  Cache = object of RootObj
    # package creation/update history - new ones at bottom
    pkgs_history: seq[string]
    # pkgs list. Extra data from GH is embedded
    pkgs: TableRef[string, Pkg]

  RssItem = tuple
    title, desc, url, guid, pubDate: string

var cache: Cache
# the pkg name is normalized
var pkgs = newTable[string, Pkg]()
var pkgs_doc_files = newTable[string, PkgDocMetadata]()

# tag -> package name
var packages_by_tag = newTable[string, seq[string]]()
# word -> package name
var packages_by_description_word = newTable[string, seq[string]]()

include "templates/base.tmpl"
include "templates/home.tmpl"
include "templates/pkg.tmpl"
include "templates/pkg_list.tmpl"
include "templates/doc_files_list.tmpl"
include "templates/loader.tmpl"
include "templates/rss.tmpl"

const
  success_badge = slurp "templates/success.svg"
  fail_badge = slurp "templates/fail.svg"
  version_badge_tpl = slurp template_path / "version-template-blue.svg"

# proc setup_seccomp() =
#   ## Setup seccomp sandbox
#   const syscalls = """accept,access,arch_prctl,bind,brk,close,connect,epoll_create,epoll_ctl,epoll_wait,execve,fcntl,fstat,futex,getcwd,getrlimit,getuid,ioctl,listen,lseek,mmap,mprotect,munmap,open,poll,read,readlink,recvfrom,rt_sigaction,rt_sigprocmask,sendto,set_robust_list,setsockopt,set_tid_address,socket,stat,uname,write"""
#   let ctx = seccomp_ctx()
#   for sc in syscalls.split(','):
#     ctx.add_rule(Allow, sc)
#   ctx.load()

from marshal import store, load
from posix import onSignal, SIGINT, SIGTERM

proc save_cache() =
  store(newFileStream(cache_fn, fmWrite), cache)

proc load_cache() =
  try:
    load(newFileStream(cache_fn, fmRead), cache)
  except:
    # init cache
    cache.pkgs = newTable[string, Pkg]()
    cache.pkgs_history = @[]
    save_cache()

proc load_packages*() =
  ## Load packages.json
  ## Rebuild packages_by_tag, packages_by_description_word
  log_debug "loading $#" % packages_list_fname
  pkgs.clear()
  let pkg_list = packages_list_fname.parseFile
  for pdata in pkg_list:
    if not pdata.hasKey("name"):
      continue
    # Normalize pkg name
    pdata["name"].str = pdata["name"].str.normalize()
    if pdata["name"].str in pkgs:
      warn "Duplicate pkg name $#" % pdata["name"].str
      continue

    pkgs.add (pdata["name"].str, pdata)

    for tag in pdata["tags"]:
      if not packages_by_tag.hasKey(tag.str):
        packages_by_tag[tag.str] = @[]
      packages_by_tag[tag.str].add pdata["name"].str

    # collect packages matching a word in their descriptions
    let orig_words = pdata["description"].str.split({' ', ','})
    for orig_word in orig_words:
      if orig_word.len < 3:
        continue  # ignore short words
      let word = orig_word.toLower
      if not packages_by_description_word.hasKey(word):
        packages_by_description_word[word] = @[]
      packages_by_description_word[word].add pdata["name"].str


  log_info "Loaded ", $pkgs.len, " packages"


proc cleanupWhitespace(s: string): string

proc save_packages() =
  ## Save packages.json
  var new_pkgs = newJArray()
  for pname in toSeq(pkgs.keys()).sorted(system.cmp):
    new_pkgs.add pkgs[pname]

  packages_list_fname.writeFile(new_pkgs.pretty.cleanupWhitespace)

proc search_packages*(query: string): CountTable[string] =
  ## Search packages by name, tag and keyword
  let query = query.split({' ', ','})
  var found_pkg_names = initCountTable[string]()
  for item in query:

    # matching by pkg name, weighted for full or partial match
    for pn in pkgs.keys():
      if item.normalize() == pn:
        found_pkg_names.inc(pn, val=5)
      elif pn.contains(item.normalize()):
        found_pkg_names.inc(pn, val=3)

    if packages_by_tag.has_key(item):
      for pn in packages_by_tag[item]:
        # matching by tags is weighted more than by word
        found_pkg_names.inc(pn, val=3)

    # matching by description, weighted 1
    if packages_by_description_word.has_key(item.toLower):
      for pn in packages_by_description_word[item.toLower]:
        found_pkg_names.inc(pn, val=1)

  # sort packages by best match
  found_pkg_names.sort()
  return found_pkg_names

proc fetch_github_readme*(pkg: Pkg, owner_repo_name: string) =
  ## Fetch README.* from GitHub
  log_debug "fetching ", github_readme_tpl % owner_repo_name
  try:
    let readme = getContent(github_readme_tpl % owner_repo_name,
    extraHeaders=github_readme_header & github_token)
    pkg["github_readme"] = newJString readme
  except:
    log_debug "failed to fetch GH readme"
    log_debug getCurrentExceptionMsg()
    pkg["github_readme"] = newJString ""

proc fetch_github_latest_version_data(pkg: Pkg, owner_repo_name: string) =
  ## Fetch version data from GitHub
  log_debug "fetching ", github_latest_version_tpl % owner_repo_name
  try:
    let latest_version = getContent(github_latest_version_tpl % owner_repo_name,
      extraHeaders=github_token).parseJson
    var latest_version_name = latest_version["name"].str
    if latest_version_name.startsWith("v"):
      latest_version_name = latest_version_name[1..^0]
    pkg["github_latest_version"] = newJString latest_version_name
    pkg["github_latest_version_url"] = newJString latest_version["tarball_url"].str
    pkg["github_latest_version_time"] = newJString latest_version["published_at"].str
  except:
    pkg["github_latest_version"] = newJString "none"
    pkg["github_latest_version_url"] = newJString ""
    pkg["github_latest_version_time"] = newJString ""

proc fetch_github_doc_pages(pkg: Pkg, owner, repo_name: string) =
  ## Fetch documentation pages from GitHub
  let url = github_doc_index_tpl % [owner.toLower, repo_name]
  log_debug "Checking ", url
  if get(url).status.startsWith("200"):
    pkg["doc"] = newJString url

proc `+`(t1, t2: Time): Time {.borrow.}

proc run_process(bin_path, desc, work_dir: string,
    timeout: int, log_output: bool,
    args: varargs[string, `$`]): string {.discardable.} =
  ## Run command with timeout
  # TODO: async

  log_debug "running: <" & bin_path & " " & join(args, " ") & "> in " & work_dir

  var p = startProcess(
    bin_path, args=args,
    workingDir=work_dir
  )
  if p.waitForExit(timeout=timeout * 1000) == 0:
    log_debug "$# successful" % desc
    let stdout_str = p.outputStream().readAll()
    if log_output:
      log_debug "Stdout: ---\n$#---" % stdout_str
      log_debug "Stderr: ---\n$#---" % p.errorStream().readAll()
    return stdout_str

  error "$# failed" % desc
  error "Stdout: ---\n$#---" % p.outputStream().readAll()
  error "Stderr: ---\n$#---" % p.errorStream().readAll()
  raise newException(ProcessError, "$# failed" % desc)

proc fetch_github_versions(pkg: Pkg, owner_repo_name: string) =
  ## Fetch versions from GH
  var version_names = newJArray()
  log_debug "fetching ", github_tags_tpl % owner_repo_name
  let tags = getContent(github_tags_tpl % owner_repo_name,
  extraHeaders=github_token).parseJson
  for t in tags:
    var name = t["name"].str
    if name.startsWith("v"):
      name = name[1..^0]
    if name.len > 0:
      version_names.add newJString name

  pkg["github_versions"] = version_names
  log_debug "fetched $# GH versions" % $len(version_names)


proc fetch_using_git(pname, url: string): bool =
  let repo_dir =  tmp_nimble_root_dir / pname
  if not repo_dir.existsDir():
    log_debug "checking out $#" % url
    run_process(git_bin_path, "git clone", tmp_nimble_root_dir, 60, false,
    "clone", url, pname)
  else:
    log_debug "git pull-ing $#" % url
    run_process(git_bin_path, "git pull", repo_dir, 60, false,
    "pull")

  let commitish = run_process(git_bin_path, "git rev-parse", repo_dir,
  1, false,
  "rev-parse", "--verify", "HEAD")

  if commitish == pkgs_doc_files[pname].last_commitish:
    pkgs_doc_files[pname].expire_time = getTime() + build_expiry_time
    pkgs_doc_files[pname].ready = true # unlock
    log_debug "no changes to repo"
    return false

  return true

proc fetch_and_build_pkg_using_nimble_old(pname: string): bool =
  let tmp_dir = "/tmp/nimble_install_test/" / pname
  let
    p = startProcess(
      nimble_binpath,
      args=["install", $pname, "--nimbleDir=$#" % tmp_dir, "-y"],
      options={poStdErrToStdOut}
    )

  var exit_code = -3
  for time_cnt in 0..timeout:
    exit_code = p.peekExitCode()
    if exit_code == -1:
      sleep(100)
      log_debug "waiting..."
    else:
      break

  let test_result =
    case exit_code
  of -1:
    p.kill()
    PkgBuildStatus.TIMEOUT
  of 0:
    PkgBuildStatus.OK
  else:
    PkgBuildStatus.Failed

  discard p.waitForExit()
  let
    output = p.outputStream().readAll()
  log_debug output

  pkgs_doc_files[pname].build_output = output
  pkgs_doc_files[pname].build_status = test_result
  return true

proc fetch_pkg_using_nimble(pname: string): bool =
  let pkg_install_dir = tmp_nimble_root_dir / pname

  var outp = run_process(nimble_bin_path, "nimble update",
    tmp_nimble_root_dir, 10, true,
    "update", " --nimbleDir=" & tmp_nimble_root_dir)
  assert outp.contains("Done")

  #if not tmp_nimble_root_dir.existsDir():
  outp = ""
  if true:
    # First install
    log_debug tmp_nimble_root_dir, " is not existing"
    outp = run_process(nimble_bin_path, "nimble install", tmp_nimble_root_dir,
      60, true,
      "install", pname, " --nimbleDir=./nyan", "-y")
    log_debug "Install successful"

  else:
    # Update pkg
    #outp = run_process(nimble_bin_path, "nimble install", "/", 60, true,
    #  "install", pname, " --nimbleDir=" & tmp_nimble_root_dir, "-y")
    #  FIXME
    log_debug "Update successful"

  pkgs_doc_files[pname].build_output = outp
  return true

proc build_docs(pname: string): strSeq =
  let pkg_install_dir = tmp_nimble_root_dir / pname

  result = @[]
  for fname in pkg_install_dir.walkDirRec(filter={pcFile}):
    if not fname.endswith(".nim"):
      continue
    log_debug "running nim doc for $#" % fname
    run_process(nim_bin_path, "nim doc", pkg_install_dir, 60, true,
      "doc", fname)
    result.add fname[pkg_install_dir.len..^1][1..^4] & "html"
    log_debug "adding ", fname[pkg_install_dir.len..^1][1..^4] & "html"

proc fetch_and_build_pkg_if_needed(pname: string) =
  ## Fetch package and build docs
  ## Modifies pkgs_doc_files

  # PkgDocMetadata state machine: nothing -> building <-> ready
  if not pkgs_doc_files.hasKey(pname):
    let pm = PkgDocMetadata(
      expire_time: getTime(),
      fnames: @[],
      ready: true,
      )
    pkgs_doc_files[pname] = pm

  # Wait on any existing pkg building task
  while pkgs_doc_files[pname].ready == false:
    log_debug "waiting build..."
    sleep 200

  # Fetch or update pkg
  let url = pkgs[pname]["url"].str
  if pkgs_doc_files[pname].expire_time > getTime():
    return

  pkgs_doc_files[pname].ready = false # lock

  #if fetch_using_git(pname, url) == false:
  #if fetch_pkg_using_nimble(pname) == false:
  if fetch_and_build_pkg_using_nimble_old(pname) == false:
    pkgs_doc_files[pname].expire_time = getTime() + build_expiry_time
    return

  let fnames = build_docs(pname)
  pkgs_doc_files[pname].fnames = fnames

  pkgs_doc_files[pname].expire_time = getTime() + build_expiry_time
  #pkgs_doc_files[pname].last_commitish = commitish
  pkgs_doc_files[pname].version = pkgs[pname]["github_latest_version"].str
  pkgs_doc_files[pname].ready = true # unlock



# Jester settings

settings:
    port = port

# routes

routes:

  get "/":
    resp base_page(generate_home_page())

  get "/search":
    let found_pkg_names = search_packages(@"query")

    var pkgs_list: seq[Pkg] = @[]
    for pn in found_pkg_names.keys():
      pkgs_list.add pkgs[pn]

    resp base_page(generate_pkg_list_page(pkgs_list))


  get "/pkg/@pkg_name/?":
    let pname = normalize(@"pkg_name")
    if not pkgs.has_key(pname):
      resp base_page "Package not found"

    let
      pkg = pkgs[pname]
      url = pkg["url"].str

    if url.startswith("https://github.com/") or url.startswith("http://github.com/"):
      if not pkg.has_key("github_last_update_time") or pkg["github_last_update_time"].num +
          github_caching_time < epochTime().int:
        # pkg is on GitHub and needs updating
        pkg["github_last_update_time"] = newJInt epochTime().int
        let owner = url.split('/')[3]
        let repo_name = url.split('/')[4]
        let owner_repo_name = "$#/$#" % url.split('/')[3..4]
        pkg["github_owner"] = newJString owner
        pkg.fetch_github_readme(owner_repo_name)
        pkg.fetch_github_latest_version_data(owner_repo_name)
        pkg.fetch_github_versions(owner_repo_name)
        pkg.fetch_github_doc_pages(owner, repo_name)

    resp base_page(generate_pkg_page(pkg))

  post "/update_package":
    ## Create or update a package description
    const required_fields = @["name", "url", "method", "tags", "description",
      "license", "web", "signatures", "authorized_keys"]
    var pkg_data: JsonNode
    try:
      pkg_data = parseJson(request.body)
    except:
      log_info "Unable to parse JSON payload"
      halt Http400, "Unable to parse JSON payload"

    for field in required_fields:
      if not pkg_data.hasKey(field):
        log_info "Missing required field $#" % field
        halt Http400, "Missing required field $#" % field

    let signature = pkg_data["signatures"][0].str

    try:
      let pkg_data_copy = pkg_data.copy()
      pkg_data_copy.delete("signatures")
      let key_id = verify_gpg_signature(pkg_data_copy, signature)
      log_info "received key", key_id
    except:
      log_info "Invalid signature"
      halt Http400, "Invalid signature"

    let name = pkg_data["name"].str

    # TODO: locking
    load_packages()

    # the package exists with identical name
    let pkg_already_exists = pkgs.hasKey(name)

    if not pkg_already_exists:
      # scan for naming collisions
      let norm_name = name.normalize()
      for existing_pn in pkgs.keys():
        if norm_name == existing_pn.normalize():
          info "Another package named $# already exists" % existing_pn
          halt Http400, "Another package named $# already exists" % existing_pn

    if pkg_already_exists:
      try:
        let old_keys = pkgs[name]["authorized_keys"].getElems.mapIt(it.str)
        let pkg_data_copy = pkg_data.copy()
        pkg_data_copy.delete("signatures")
        let key_id = verify_gpg_signature_is_allowed(pkg_data_copy, signature, old_keys)
        log_info "$# updating package $#" % [key_id, name]
      except:
        log_info "Key not accepted"
        halt Http400, "Key not accepted"

    pkgs[name] = pkg_data
    save_packages()
    log_info if pkg_already_exists: "Updated existing package $#" % name
      else: "Added new package $#" % name
    resp base_page("OK")

  get "/packages.json":
    ## Serve the packages list file
    resp packages_list_fname.readFile

  get "/docs/@pkg_name/?@doc_path?":
    ## Serve hosted docs for a package
    let pname = normalize(@"pkg_name")
    let doc_path = @"doc_path"
    if not pkgs.hasKey(pname):
      resp base_page("<p>Package not found</p>")
    let pkg = pkgs[pname]

    # Check out pkg and build docs. Modifies pkgs_doc_files
    fetch_and_build_pkg_if_needed(pname)

    # Show files summary
    if doc_path == "":
      resp base_page(
        generate_doc_files_list_page(pname, pkgs_doc_files[pname])
      )

    # Serve doc file
    let fn = tmp_nimble_root_dir / pname / doc_path
    if existsFile(fn):
      log_debug "serving $#" % fn
      resp base_page(fn.readFile())
    else:
      log_info "serving $# - not found" % fn
      halt


  get "/loader":
    resp base_page(
      generate_loader_page()
    )

  get "/packages.xml":
    ## New and updated packages feed
    var rss_items: seq[RssItem] = @[]
    for pn in cache.pkgs_history:
      let pkg = pkgs[pn]
      let i:RssItem = (pn, pkg["description"].str, "", "FIXME", "")
      rss_items.add i

    let r = generate_rss_feed(
      "Nim packages",
      "New and updated Nim packages",
      "FIXME",
      "FIXME",
      "FIXME",
      3600,
      rss_items
    )
    resp(r, contentType="application/rss+xml")


  # CI Routing

  get "/ci":
    ## CI summary
    #@bottle.view('index')
    #refresh_build_num()
    discard

  get "/ci/install_report":
    discard

  get "/ci/badges/@pkg_name/version.svg":
    ## Version badge
    let pname = normalize(@"pkg_name")
    fetch_and_build_pkg_if_needed(pname)
    let md =
      try:
        pkgs_doc_files[pname]
      except KeyError:
        halt
        nil
    let version = md.version
    let badge = version_badge_tpl % [version, version]
    resp(badge, contentType = "image/svg+xml")

  get "/ci/badges/@pkg_name/nimdevel/status.svg":
    ## Status badge
    let pname = normalize(@"pkg_name")
    fetch_and_build_pkg_if_needed(pname)
    let md =
      try:
        pkgs_doc_files[pname]
      except KeyError:
        halt
        nil
    case md.build_status
    of PkgBuildStatus.OK:
      resp(success_badge, contentType = "image/svg+xml")
    of PkgBuildStatus.Failed:
      resp(fail_badge, contentType = "image/svg+xml")
    of PkgBuildStatus.Timeout:
      resp(fail_badge, contentType = "image/svg+xml")

  get "/ci/badges/@pkg_name/nimdevel/output.html":
    ## Build output
    let pname = normalize(@"pkg_name")
    try:
      let outp = pkgs_doc_files[pname].build_output
      resp base_page(pre(outp))
    except KeyError:
      halt



proc cleanupWhitespace(s: string): string =
  ## Removes trailing whitespace and normalizes line endings to LF.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == ' ':
      var j = i+1
      while s[j] == ' ': inc j
      if s[j] == '\c':
        inc j
        if s[j] == '\L': inc j
        result.add '\L'
        i = j
      elif s[j] == '\L':
        result.add '\L'
        i = j+1
      else:
        result.add ' '
        inc i
    elif s[i] == '\c':
      inc i
      if s[i] == '\L': inc i
      result.add '\L'
    elif s[i] == '\L':
      result.add '\L'
      inc i
    else:
      result.add s[i]
      inc i
  if result[^1] != '\L':
    result.add '\L'



#def refresh_nim_version(basepath):
#    """Refresh Nim version from the last successful build
#    """
#    global last_successful_nim_version
#    try:
#        r = requests.get(basepath + 'release_tarball_name')
#        v = r.text.strip().split('/')[-1]
#        assert v.startswith('nim-')
#        last_successful_nim_version = v[4:-7]
#    except Exception as e:
#        print(e)
#        pass
#
#
#
#def start_build_if_needed():
#    rebuild_nim, run_install_test, reason = \
#        repo_monitor.check(rebuild_nim=False, run_install_test=False)
#    if reason:
#        start_build(rebuild_nim=rebuild_nim, reason=reason,
#                    run_install_test=run_install_test)
#        return True
#    return False
#
#
#def timed_start_build_if_needed():
#    Timer(REBUILD_CHECK_TIME, timed_start_build_if_needed).start()
#    start_build_if_needed()
#
#def send_status_email_if_needed():
#    pass
#
#def timed_send_status_email_if_needed():
#    Timer(REBUILD_CHECK_TIME, timed_start_build_if_needed).start()
#    send_status_email_if_needed()




#status_fn = os.path.expanduser("~/.nimci_cronjob.json")
#def load_status():
#    try:
#        with open(status_fn) as f:
#            return json.load(f)
#    except IOError:
#        return dict(nim_commit=None, nimble_commit=None, pkgs_commit=None)
#
#def save_status(st):
#    with open(status_fn, 'w') as f:
#        json.dump(st, f)



#
#def check(rebuild_nim=False, run_install_test=False):
#    changed_components = []
#    if not rebuild_nim:
#        status = load_status()
#        # rebuild Nim only if needed
#        last_nim_commit = fetch_last_commit(nim_commit_url)
#        last_nimble_commit = fetch_last_commit(nimble_commit_url)
#        if status['nim_commit'] != last_nim_commit:
#            changed_components.append('Nim')
#
#        if status['nimble_commit'] != last_nimble_commit:
#            changed_components.append('Nimble')
#
#        if changed_components:
#            rebuild_nim = True
#            status['nim_commit'] = last_nim_commit
#            status['nimble_commit'] = last_nimble_commit
#            save_status(status)
#
#    packages_changed = False
#    last_pkgs_commit = fetch_last_commit(pkgs_commit_url)
#    if status['pkgs_commit'] != last_pkgs_commit:
#        packages_changed = True
#        changed_components.append('Packages list')
#        status['pkgs_commit'] = last_pkgs_commit
#        save_status(status)
#
#    run_install_test = run_install_test or rebuild_nim or packages_changed
#
#    reason = "change in %s" % ', '.join(changed_components) \
#        if changed_components else None
#    return rebuild_nim, run_install_test, reason
#


proc start_nim_commit_polling(poll_time: TimeInterval) {.async.} =
  while true:
    await sleepAsync(poll_time.milliseconds)
    #FIXME asyncCheck




onSignal(SIGINT, SIGTERM):
  info "Exiting"
  save_cache()
  save_packages()
  quit()

proc main() =
  #setup_seccomp()
  log_info "starting"
  tmp_nimble_root_dir.createDir()
  load_packages()
  load_cache()
  #asyncCheck start_nim_commit_polling(github_nim_commit_polling_time)
  #FIXME
  cache.pkgs_history = @["jester", "libsodium", "aporia"]

  info "Starting"
  runForever()

when isMainModule:
  main()
