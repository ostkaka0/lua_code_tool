#!/usr/bin/lua
-- Author: John Emanuelsson
-- File created 2025-04-05 15:46:33 CEST

local lfs = require "lfs"
local inspect =  require "inspect"
-- local fs = require "fs"
local uv = require "luv"

local path = require("lua_code_tool.path")


-- local USE_LUV = true

local lct = {}

-- Fetch username
lct.user = os.getenv("USER") or os.getenv("USERNAME") or os.getenv("LOGNAME")
if not lct.user then
  error("Expected environment variable $USER, $USERNAME or $LOGNAME")
end

-- Fetch home path
lct.home = os.getenv("HOME")
if not lct.home then
  error("Expected enviornment variable $HOME")
end

-- function lct.get_home_relative_path(path)
-- end

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
    write_flags = 6*64 + 4*8 + 4
    read_flags = 6*64 + 4*8 + 4
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
  out_dir = "/tmp/lua_code_tool/" .. lct.user .. "/",
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

return lct
