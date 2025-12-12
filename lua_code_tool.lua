#!/usr/bin/lua
-- Author: John Emanuelsson
-- File created 2025-04-05 15:46:33 CEST

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

-- local USE_LUV = true

local lfs = require "lfs"
local inspect =  require "inspect"
-- local fs = require "fs"
local uv
---@diagnostic disable: undefined-global
if USE_LUV then
  uv = require "luv"
end

local lct = {} -- Exported module

-- path ------------------------------------------------------------------------
local path = {} -- path "submodule"
lct.path = path
-- Note that the first / on a full path will not become a part.
function path.to_parts(p)
  return p:gmatch("[^/]+")
end
function path.to_parts_arr(p)
  local parts = {}
  for part in path.to_parts(p) do
    table.insert(parts, part)
  end
  return parts
end

-- Normalize path, note because we don't convert to full path, we may get a few leading "..". There is a special case for leading ".." when the path was a full path, then we get a "/" and a number of "..", this is an invalid path, but is the best we can do, anyways the path will be unusable and always result in an error somewhere, since the os won't let us open any file ever with such paths.
function path.normalize(p)
  -- Use / instead of \
  p = p:gsub("\\", "/")
  -- Split path into parts, remove previous part when "..", do't insert for ".".
  local parts = {} -- The first few parts can all be "..", but the rest must be neither "." or "..".
  local depth = 0 -- length of parts excluding initial ".." as well as an "/" if we had a full path.
  if path.is_full(p) then
    parts.insert("/")
  end
  for part in path.to_parts(p) do
    if part == "~" and #parts == 0 then
      table.insert(parts, "~") -- TODO: perhaps implement a path.get_first or split_root. This code would then be simplified away.
    elseif part == ".." then
      if depth == 0 then
        table.insert(parts, "..")
      else
        table.remove(parts)
        depth = depth - 1
      end
    elseif part ~= "." and part ~= "" then
      table.insert(parts, part)
      depth = depth + 1
    end
  end
  -- Merge parts into a path
  local r = ""
  for i, part in ipairs(parts) do
    if i ~= 0 then
      r = r .. "/"
    end
    r = r .. part
  end
  return r
end

function path.is_absolute(p)
  return p:match("^[/\\]") or p:match("^%w:[/\\]") or p:match("^\\\\")
end

function path.join(a, b)
  assert(not path.is_absolute(b))
  if     a == "." then
    return b
  elseif b == "." then
    return a
  else
    a = a:gsub("/+$", "") -- Remove trailing /
    return a .. "/" .. b
  end
end

function path.split(p)
  local dir, filename = p:match("^(.-)([^/\\]*)$")
  local basename, ext = filename:match("^(.-)(%.[^%.]*)$")
  if basename then
    return dir, filename, basename, ext
  else
    return dir, filename, filename, ""
  end
end


function path.is_full(p)
  return p:match("^[/\\]") or p:match("^[a-zA-Z]%:[/\\]")
end

function path.user_home()
  return os.getenv("HOME")
end

function path.current_dir()
  lfs.currentdir()
end

function path.full(p)
  if not path.is_full(p) then
    if p:sub(1, 1) == "~" then
      p = path.join(path.user_home(), p:sub(2))
    else
      p = path.join(path.current_dir(), p)
    end
  end
  return path.normalize(p)
end

-- shortcut_map is a map with normalized input path-patterns for keys, and and shortcuts for values(may use captures). Only alternative paths with less parts may be picked.
function path.choose_best_shortcut(p, shortcut_map)
  print("sdfsdfdsf")
  print(inspect(shortcut_map))
  local best_p = p
  local best_p_part_cnt = #path.to_parts_arr(p)
  for k, v in pairs(shortcut_map) do
    print("key")
    print(k)
    print("val")
    print(v)
    local new_p = p:gsub(k, v)
    local new_p_part_cnt = #path.to_parts_arr(new_p)
    if new_p_part_cnt < best_p_part_cnt then
      best_p = new_p
      best_p_part_cnt = new_p_part_cnt
    end
  end
  return best_p
end

function path.first_part(p)
  local parts = path.to_parts_arr(p)
  local num_parts = #parts
  assert(num_parts > 0)
  return parts[1]
end

function path.last_part(p)
  print(p)
  local parts = path.to_parts_arr(p)
  local num_parts = #parts
  assert(num_parts > 0)
  return parts[num_parts]
end

function path.get_home()
  local home = os.getenv("HOME")
  if not home then
    error("Expected enviornment variable $HOME")
  end
  return home
end
--------------------------------------------------------------------------------

-- Events that are triggered once and can only once
lct.Event = {}
lct.Event.__index = lct.Event
function lct.Event:new()
  return setmetatable({
    val = nil, -- nil until triggered
    waiters = {}, -- Coroutine threads waiting on this event
  }, self)
end

function lct.Event:await()
  if lct.debug then print("await called") end
  if self.val == nil then
    local co = coroutine.running()
    table.insert(self.waiters, co)
    return coroutine.yield()
  else
    return self.val
  end
end

function lct.Event:trigger(val)
  assert(self.val == nil)
  assert(self.waiters ~= nil)

  self.val = val
  local waiters = self.waiters
  self.waiters = nil

  for _, co in ipairs(waiters) do
    local ok, err = coroutine.resume(co, self.val)
    if not ok then error(debug.traceback(co, err), 2) end
  end
end

function lct.Event:trigger_and_invalidate(val)
  if lct.debug then print("trigger_and_invalidate called") end
  assert(self.val == nil)
  assert(self.waiters ~= nil)

  local waiters = self.waiters
  self.waiters = nil
  setmetatable(self, nil)

  for _, co in ipairs(waiters) do
    local ok, err = coroutine.resume(co, val)
    if not ok then error(debug.traceback(co, err), 2) end
  end
end

function lct.create_events_table()
  return setmetatable({}, {
    __index = function(events, key)
      local e = lct.Event:new()
      rawset(events, key, e)
      return e
    end
  })
end

function lct.set_defaults(trgt, src)
  for k, v in pairs(src) do
    if trgt[k] == nil then
      trgt[k] = v
    end
  end
end

function lct.set_defaults_strict(trgt, src)
  lct.set_defaults(trgt, src)
  -- print(inspect(src))
  -- print(inspect(trgt))
  for k, _ in pairs(trgt) do
    assert(src[k] ~= nil, k .. " set to target table, but not found among default-values")
  end
end

function lct.filter_ext(ext, options)
  local found = false
  local empty = true
  if not options.in_exts then return true end
  for _, e in ipairs(options.in_exts) do
    empty = false
    if e == ext then found = true end
  end
  return empty or found
end

function lct.process_file_default(filepath, options, events, sync_event, return_type)
  local dir, filename, basename, ext = path.split(filepath)
  if not lct.filter_ext(ext, options) then return end
  -- for k, v in pairs(options.in_exts) do print(k .. " " .. v) end 
  -- if not ext then return end
  -- if options.in_exts and next(options.in_exts) then -- Filter by in_exts
  --   if not options.in_exts[ext] then return end
  -- end
  for _, d in ipairs(options.exclude_dirs) do -- filter out exclude_dirs
    if dir:sub(1, #d) == d then return end
  end
  if dir:sub(1, #options.out_dir) == options.our_dir then return end -- Output can't be input
  if options.verbose then print("# " .. filename .. ":") end

  local full_out_path = options.out_dir .. "/" .. filepath
  -- print("out_path:" .. full_out_path)

  if USE_LUV then
    -- local fd, err = uv.fs_open(filepath)
    -- local stat = uv.fs_stat(fd)
    -- local src, err = uv.fs_read(fd, stat.size, 0)
    -- uv.fs_close(fd)
    -- if not src then error("Failed to read " .. fullpath) end
    local write_flags = 6*64 + 4*8 + 4
    local read_flags = 6*64 + 4*8 + 4
    uv.fs_open(filepath, "r", read_flags, function(err, fd)
      -- print("A: " .. filepath)
      if err then error("Failed to open " .. filepath) end
      uv.fs_fstat(fd, function(err, stat)
        -- print("B: " .. filepath)
        if err then error("fs_fstat() failed for " .. filepath) end
        uv.fs_read(fd, stat.size, read_flags, function(err, src)
          -- print("C: " .. filepath)
          if err then error("Failed reading " .. filepath) end
          local out_src = options.process_src(src, {dir=dir, filename=filename, filepath=filepath, prnt=prnt, basename=basename, ext=ext, options=options})
          -- print("out:" .. out_src)
          if not out_src then return end
          uv.fs_open(full_out_path, "w", write_flags, function(err, out_fd)
            -- print("D: " .. filepath)
            if err then error("fs_open() failed for " .. full_out_path) end
            uv.fs_write(out_fd, out_src, -1, function(err)
              -- print("E: " .. filepath)
              if err then error("fs_write failed for " .. full_out_path) end
            end)
          end)
        end)
      end)
    end)

  else
    local src = nil
    if not options.no_read then
      local file = io.open(filepath)
      assert(file)
      src = file:read("*a")
      file:close()
    end

    local out_val = options.process_src(src, events, sync_event, {filepath=filepath, prnt=prnt, options=options})
    if out_val == nil then return end
    if return_type.val == nil then
      return_type.val = type(out_val)
    else
      -- We assert that the code return an object with the same type for each file. Either string, bool or function(iterator), except nil is ignored.
      assert(type(out_val) == return_type.val)
    end

    if type(out_val) == "string" then
      local out_src = out_val
      os.execute("mkdir -p " .. options.out_dir .. "/" .. dir)
      local out_file, err = io.open(full_out_path, "w+")
      assert(out_file)
      out_file:write(out_src)
      out_file:close()
    elseif type(out_val) == "boolean" then
      if out_val == true then
        print(filepath)
      end
    elseif type(out_val) == "function" then
      -- The code returned search results in the form of an iterator
      local line_offsets = {}
      local lines = {}
      for offset, line in src:gmatch("()([^\n]*)\n?") do
        table.insert(line_offsets, offset)
        table.insert(lines, line)
      end

      local prev_a = 0
      local prev_b = -1
      local line_num = 0
      local line_offset = 0
      for a, b in out_val do
        if a == nil or b == nil then break end
        a = a
        b = b - 1
        local match_str = src:sub(a, b)

        assert(a ~= nil and b ~= nil)
        assert(a >= prev_a)
        if a == prev_a then
          assert(b > prev_b)
        end

        -- Loop until we find the correct line number
        while true do
          local next_line_offset = line_offsets[line_num + 1]
          if next_line_offset == nil then break end
          if next_line_offset > a then break end
          line_num = line_num + 1
          line_offset = next_line_offset
        end
        -- Calc line count of match
        local line_cnt = 1
        for _ in match_str:gmatch("\n") do
          line_cnt = line_cnt + 1
        end
        -- print("match:")
        -- print(match_str)
        -- print("line_cnt is "..line_cnt)
        -- Calculate the column
        local col = a - line_offset + 1

        -- We can now finally print the search result
        print()
        print(filepath .. ":" .. line_num .. ":" .. col)
        for i = line_num, line_num + line_cnt - 1 do
          local line = lines[i]
          if line == nil then break end
          io.write("    ")
          io.write(line)
          io.write("\n")
          io.write("    ")
          for j = 1, #line do
            if line_offsets[i] + j <= a then
              io.write(" ")
            elseif line_offsets[i] + j <= b + 1 then
              io.write("‾")
            end
          end
          io.write("\n")
        end

        prev_a = a
        prev_b = b
      end
    end
  end
end

lct.default_options = {
  process_src = false,
  process_file = lct.process_file_default,
  in_dirs = {"."},
  out_dir = "/tmp/lua_code_tool/" .. path.last_part(path.get_home()) .. "/",
  exclude_dirs = {},
  in_exts = false,
  verbose = false,
  quiet = false,
  hidden_dirs = false,
  no_read = false,
}

-- TODO: detect duplicate filepaths
-- TODO: detect when a symbol link leads back to a previously iterated filepath
function lct.process_files(options)
  lct.set_defaults_strict(options, lct.default_options)
  if options.verbose then print("options: " .. inspect(options)) end
  if #options.in_dirs == 0 then
    options.in_dirs = lct.default_options.in_dirs
  end

  assert(options.process_src, "process_src must be set")
  assert(options.in_dirs, "in_dirs must be set")
  assert(next(options.in_dirs), "in_dirs must be set")

  -- filepaths is initialized to options.in_dirs
  local filepaths = {}
  for i, filepath in ipairs(options.in_dirs) do
    filepaths[i] = filepath
  end

  local coros = {}
  local return_type = {val = nil}
  -- Iterate files recursively
  local events = lct.create_events_table()
  local sync_event = lct.Event:new()
  for _, filepath in ipairs(filepaths) do
    local dir, filename, basename, ext = path.split(filepath)
    local attr = lfs.attributes(filepath)
    local filetype = attr.mode
    if options.verbose then
      print("Walking path: " .. filepath)
      print("filetype: " .. filetype)
      print("filename:" .. filename)
    end
    -- Exclude files
    for _, d in ipairs(options.exclude_dirs) do -- filter out exclude_dirs
      if filepath:sub(-#d) == d then goto continue end
    end
    -- Call process_file as coroutine if filetype is file
    if filetype == "file" then
      -- TODO: Use io.popen
      local co = coroutine.create(options.process_file)
      coros[filepath] = {co = co}
    -- Recurse if filetype is directory
    elseif filetype == "directory" then
      for child_filename in lfs.dir(filepath) do
        if child_filename ~= "." and
           child_filename ~= ".." and
           (options.hidden_dirs or child_filename:sub(1, 1) ~= ".") -- Don't recurse through hidden directories
        then
          local child_filepath = path.join(filepath, child_filename)
          table.insert(filepaths, child_filepath)
        end
      end
    end
    ::continue::
  end

  -- Run all coroutines
  -- Note, some coroutines may yield on events, but all of them should be resumed by other coroutines in the end.
  for filepath, co_obj in pairs(coros) do
    local co = co_obj.co
    local status = coroutine.status(co)
    assert(status == "suspended")
    local ok, err = coroutine.resume(co, filepath, options, events, sync_event, return_type)
    if not ok then error(debug.traceback(co, err), 2) end
  end

  -- Trigger the syncrhonize event, but don't allow coroutines to "await" afterwards.

  sync_event:trigger_and_invalidate()
  -- Check for deadlock. After resuming every coroutine once, we expect all coroutines to be finished, except if we got a deadlock.
  for filename, co_obj in pairs(coros) do
    local co = co_obj.co
    local status = coroutine.status(co)
    assert(status == "dead")
  end
 end

local function main()
  local argparse = require("argparse")

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

  -- Lua environment
  local env = {
    inspect = require("inspect"),
    print = print
  }

  -- Check if code is fennel
  local use_fennel = false
  if code and code:sub(1, 1) == "(" and code:sub(-1, -1) == ")" then
    use_fennel = true
  end

  -- Translate fennel to lua
  if code and use_fennel then
    local fennel = require("fennel")
    -- table.insert(package.loaders or package.searchers, fennel.searcher)

    local fennel_code = code:sub(2, -2)
    code = fennel.compileString(fennel_code)
    if args.verbose then
      print("Fennel code:")
      print(fennel_code)
      print("Transpiled lua code:")
      print(code)
    end
  end

  -- Add hidden parameters to our code
  if code then
    code = [[s, events, sync_event, args = ...; ]] .. code
  end

  -- Load the code
  local func = nil
  if code then
    local err = nil
    if args.verbose then print("Code: " .. code) end
    if args.verbose then print("Processing...") end
    func, err = load(code, "chunk", "t", env)
    if err then error(err) end

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
  end

  -- Delete previous files at output directory
  if args.clean or (code and not args.keep) then
    assert(out_dir:match("^/tmp/")) -- Only allow /tmp/ for now
    local cmd = "rm -rf " .. out_dir
    if args.verbose then print(cmd) end
    os.execute(cmd)
  end

  -- Process files with out code
  if code then
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
  local diff_cmd = "diff -ru --color=always ./ " .. out_dir  .. " | grep -v '^Only in ' | grep -v -F '+++ ' | grep -v 'diff -ru '"
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
      local cp_cmd = "cp -r " .. out_dir .. "/. ./"
      if args.verbose then print(cp_cmd) end
      os.execute(cp_cmd)
    end
  end
end

local is_main_file = not pcall(debug.getlocal, 4, 1)
if is_main_file then
  main()
end

return lct
