#!/usr/bin/lua
-- Author: John Emanuelsson
-- File created 2025-04-06 06:05:15 CEST

-- TODO: Windows support
-- TODO: Safety guards
-- TODO: Config file
-- TODO: Search
-- TODO: /... for search, /.../.../ for replace, ... for lua
-- TODO: Flag -s --pipe-search, otherwise search never writes to file, or maybe /.../ for piped search
-- TODO: Print files only
-- TODO: Allow multiple processing commands, including search
-- TODO: Perhaps use /tmp/ on linux, %TMP% on windows
-- TODO: Individual file inputs
-- TODO: Consider replacing argparse, and remove requirement for " and ' of code-arguments

local function file_exists(filename)
  local f = io.open(filename, "r")
  if f ~= nil then
    io.close(f)
    return true
  else
    return false
  end
end

-- -- Weird hack to load local script files:
-- -- print(debug.getinfo(1, "S").source:match("@(.*)"))
-- -- print(debug.getinfo(1, "S").source:match("@(.*[\\/])") or "./")
-- local script_dir = debug.getinfo(1, "S").source:match("@(.*[\\/])") or "./"
-- -- print(script_dir)
-- package.path = package.path .. ";" .. script_dir .. "?.lua"
-- -- print(package.path)
-- -- local libpath = (...)match(".-)[^%.]+$")
-- -- print(libpath)

local lct = require("lib_lua_code_tool")
local argparse = require("argparse")
local inspect = require("inspect")
local lfs = require "lfs"

-- local function process_src_print(s, args)
--   s = "// " .. inspect(args):gsub("\n","\n// ") .. "\n" .. s
--   s=s:gsub("(class %w+ {)", "export default %1")
--   return s
-- end
-- process_files({process_src = process_src_print, in_dirs = {"src", "games"}})

-- local argparser = argparse("my-script", "A program here")
-- parser:argument("cow", "A cow eating grass")

local parser = argparse()
  :name "lua_code_tool"
  :description "A tool for refactoring, searching and generating code."

parser:flag "-a" "--all"
parser:mutex(
  parser:flag "-v" "--verbose",
  parser:flag "-q" "--quiet"
)
parser:flag "-i" "--in-place"
parser:mutex(
  parser:flag "-y" "--yes",
  parser:flag "-n" "--no"
)
parser:mutex(
  parser:flag "-k" "--keep",
  parser:flag "-c" "--clean"
)
-- parser:mutex(
--   parser:flag "-g" "--gsub",
--   parser:flag "-l" "--lua"
--   -- parser:flag "-s" "--search"
-- )
parser:flag "--no-read"
parser:flag "-p" "--no-pager"
parser:flag "--debug"
-- parser:flag  "--unsafe" -- Disables safety guards

parser:option "-D" "--directory"
  :count "*"
-- parser:option "-O" "--output-directory"
--   :args(1)
parser:option "-X" "--exclude-dir"
  :count "*"
parser:option "-E" "--extension"
  :count "*"



parser:argument "file_patterns" :args("*")

-- Seperate arguments before "--" and after. Everything after "--" is input-code.
local args_for_argparse = {}
local parse_as_code = false
local code = nil
for i, a in ipairs(arg) do
  if parse_as_code then
    if input_code == nil then
      code = a
    else
      code = code.." "..a
    end
  else
    if a == "--" then
      parse_as_code = true
    else
      table.insert(args_for_argparse, a)
    end
  end
end

local args = parser:parse(args_for_argparse)
if args.verbose then print("Args: " .. inspect(args)) end
if args.debug then lct.debug = true end

local out_dir = args.output_directory or lct.default_options.out_dir
local modified_out_dir = out_dir:gsub("[./\\]", "")
-- print("here: " .. modified_out_dir)
assert(#modified_out_dir > 0, "output directory is incorrect")
if #modified_out_dir == 0 then os.exit(-1) end

-- If code has no non-space-characters, then make it nil
if code and code:match("^%s*$") then
  code = nil
end
-- If we got input-code, then check if it was written with /A/ or /A/B/ pattern for search or replace(otherwise it's arbitrary lua-code).
-- TODO: Improve our match, so we can include / characters by writing \/, because we can't!
if code and code:sub(1, 1) == "/" then
  -- /A/B/ pattern
  local A, B = code:match("^/([^/]*)/([^/]*)/$")
  -- //A/ pattern
  if A == "" then
    A = nil
    B = code:match("^//([^/]*)/$")
  end
  -- /A/ pattern
  if not A then
    A = code:match("^/([^/]*)/$")
  end
  
  assert(A or B, "Input code starts with /, but could't interpreted as /A/B/ or /A/ or //A/")

  -- Replace
  if A and B then
    code = [[return s:gsub("]] .. A .. [[", "]] .. B .. [[")]]
  -- Search
  elseif A then
    code = [[return s:gmatch("()]] .. A .. [[()")]]
  -- Search but list files only
  else
    assert(B)
    code = [[return s:gmatch("]] .. B .. [[") ~= nil]]
  end
end

-- If no code is provided, then simply print the filepaths
if not code then
  code = "print(args.filepath)"
  args.no_read = true
end

-- Add hidden parameters to our code
if code then
  code = [[s, events, sync_event, args = ...; ]] .. code
end

-- Lua environment
local env = {
  inspect = require("inspect"),
  print = print
}

-- Delete previous files at output directory
if args.clean or (code and not args.keep) then
  assert(out_dir:match("^/tmp/")) -- Only allow /tmp/ for now
  local cmd = "rm -rf " .. out_dir
  if args.verbose then print(cmd) end
  os.execute(cmd)
end



-- Process files with out code
if code then
  if args.verbose then print("Code: " .. code) end
  if args.verbose then print("Processing...") end
  local func, err = load(code, "chunk", "t", env)
  assert(err == nil)
  -- print(func)
  -- print(err)
  -- print("lct: " .. inspect(lct))

  local function print_func(_, _)
    print('HELLO from print_func')
  end

  -- func("LOOK HERE", {})
  -- print_func("here", {})
  -- do
  --   print("mkdir -p " .. out_dir)
  --   os.execute("mkdir -p " .. out_dir)
  --   local f = io.open(lock_filename, "w")
  --   assert(f)
  --   f:write("")
  --   f:close()
  -- end
  lct.process_files({process_src = func, in_dirs = args.file_patterns, out_dir = args.output_directory, in_exts = args.extension, verbose = args.verbose, quiet = args.quiet, exclude_dirs = args.exclude_dir, hidden_dirs = args.all, no_read = args.no_read})
  -- os.remove(lock_filename)
end
-- Delete output-directory if empty
if args.verbose then
  print('rmdir "'.. out_dir ..'" 2>/dev/null')
end
os.execute('rmdir "'.. out_dir ..'" 2>/dev/null')

-- Show diffs
-- if args.directory and next(args.directory) then
--   for _, d in ipairs(args.directory) do
--     os.execute("diff -ru --color=always " .. d .. " " .. out_dir .. "/" .. d .. " | grep -v '^Only in '")
--   end
-- else
diff_cmd = "diff -ru --color=always ./ " .. out_dir  .. " | grep -v '^Only in ' | grep -v -F '+++ ' | grep -v 'diff -ru '"
if not args.quiet then
  if not args.no_pager then
    diff_cmd = diff_cmd .. " | less --raw-control-chars -FX"
  end
  if args.verbose then
    print(diff_cmd)
  end
  os.execute("if [ -d " .. out_dir .. " ]; then\n " .. diff_cmd .. "\nfi")
end

-- Copy back to files if args.in_place, but first prompt the user.
if args.in_place then
  local y_n = false
  while true do
    if not args.quiet or not(args.yes or args.no) then
      io.write("Accept changes? (y/n): ")
    end
    if args.yes then
      y_n = true
      if not args.quiet then io.write("Yes\n") end
      break
    elseif args.no then
      y_n = false
      if not args.quiet then io.write("No\n") end
      break
    else
      local answer = string.lower(io.read())
      if answer == "y" then y_n = true break end
      if answer == "n" or answer == "" then break end
    end
  end
  if y_n then
    local cp_cmd = "cp -r " .. out_dir .. " ./funny_dir/"
    if args.verbose then print(cp_cmd) end
    os.execute(cp_cmd)
  end
end
