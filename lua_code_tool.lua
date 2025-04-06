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

-- Weird hack to load local script files:
local script_dir = debug.getinfo(1, "S").source:match("@(.*[\\/])")
-- print(script_dir)
package.path = package.path .. ";" .. script_dir .. "?.lua"
-- local libpath = (...)match(".-)[^%.]+$")
-- print(libpath)

local cf = require("lib_lua_code_tool")
local argparse = require("argparse")
local inspect = require("inspect")

-- local function process_src_print(s, args)
--   s = "// " .. inspect(args):gsub("\n","\n// ") .. "\n" .. s
--   s=s:gsub("(class %w+ {)", "export default %1")
--   return s
-- end
-- process_files({process_src = process_src_print, in_dirs = {"src", "games"}})

-- local argparser = argparse("my-script", "A program here")
-- parser:argument("cow", "A cow eating grass")

local parser = argparse()
  :name "Codeforge"
  :description "A tool refactoring, searching and generating code."

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
parser:mutex(
  parser:flag "-g" "--gsub",
  parser:flag "-l" "--lua"
  -- parser:flag "-s" "--search"
)
parser:flag "-p" "--no-pager"
-- parser:flag  "--unsafe" -- Disables safety guards

parser:option "-D" "--directory"
  :count "*"
parser:option "-O" "--output-directory"
  :args(1)
parser:option "-X" "--exclude-dir"
  :count "*"
parser:option "-E" "--extension"
  :count "*"


parser:argument "code" :args("?")

local args = parser:parse()
if args.verbose then print("Args: " .. inspect(args)) end

local out_dir = args.output_directory or cf.default_options.out_dir
local modified_out_dir = out_dir:gsub("[./\\]", "")
-- print("here: " .. modified_out_dir)
assert(#modified_out_dir > 0, "output directory is incorrect")
if #modified_out_dir == 0 then os.exit(-1) end

code = nil
if args.gsub then
  assert(args.code, "-g requires code")
  code_ = args.code:gsub("\\/", "\0")
  local A, B = code_:match("^([^/]*)/([^/]*)$")
  if A and B then
    A = A:gsub("\0", "/")
    B = B:gsub("\0", "/")
    -- print(A)
    -- print(B)
    code = [[s, _ = ...; return s:gsub("]] .. A .. [[", "]] .. B .. [[")]]
  -- else
  end
end
if args.lua then
  assert(args.code, "-g requires code")
  code = [[s, args = ...; ]] .. args.code
end

local env = {
  inspect = require("inspect"),
  print = print
}

if args.clean or (code and not args.keep) then
  local cmd = "rm -rf ./" .. out_dir
  if args.verbose then print(cmd) end
  os.execute(cmd)
end
if code then
  if args.verbose then print("Code: " .. code) end
  if args.verbose then print("Processing...") end
  local func, err = load(code, "chunk", "t", env)
  assert(err == nil)
  -- print(func)
  -- print(err)
  -- print("cf: " .. inspect(cf))

  local function print_func(_, _)
    print('HELLO from print_func')
  end

  -- func("LOOK HERE", {})
  -- print_func("here", {})
  cf.process_files({process_src = func, in_dirs = args.directory, out_dir = args.output_directory, in_exts = args.extension, verbose = args.verbose, quiet = args.quiet})
end

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
  os.execute(diff_cmd)
end

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
