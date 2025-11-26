#!/usr/bin/lua
-- Author: John Emanuelsson
-- File created 2025-04-05 15:46:33 CEST

local lfs = require "lfs"
local inspect =  require "inspect"
-- local fs = require "fs"
local uv = require "luv"



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

function lct.Event:trigger(val)
  assert(val ~= nil)
  assert(self.val == nil)

  self.val = val
  local waiters = self.waiters
  self.waiters = nil

  for co in waiters do
    coroutine.resume(co, self.val)
  end
end

function lct.Event:await()
  if self.val == nil then
    local co = coroutine.running()
    table.insert(self.waiters, co)
    return coroutine.yield()
  else
    return self.val
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

function lct.process_file_default(dir, filepath, options, events)
  local full_path = dir .. "/" .. filepath
  -- local prnt, filename, ext = filepath:match("^(.*/)?(.?[^/%.]+)(%..*)?$")
  -- local filename, ext = filepath:match("^(.?[^/%.]+)(%..*)?$")
  -- local filename, ext = filepath:match("([^/%.]+)(%..*)?")
  local filename, ext = filepath:match("([^/%.]+)%.(.*)")
  if not ext then return end
  if options.in_exts and next(options.in_exts) then -- Filter by in_exts
    if not options.in_exts[ext] then return end
  end
  for _, d in ipairs(options.exclude_dirs) do -- filter out exclude_dirs
    if dir:sub(1, #d) == d then return end
  end
  if dir:sub(1, #options.out_dir) == options.our_dir then return end -- Output can't be input
  if options.verbose then print("# " .. filepath .. ":") end

  local full_out_path = options.out_dir .. "/" .. full_path
  -- print("out_path:" .. full_out_path)

  if USE_LUV then
    -- local fd, err = uv.fs_open(full_path)
    -- local stat = uv.fs_stat(fd)
    -- local src, err = uv.fs_read(fd, stat.size, 0)
    -- uv.fs_close(fd)
    -- if not src then error("Failed to read " .. fullpath) end
    write_flags = 6*64 + 4*8 + 4
    read_flags = 6*64 + 4*8 + 4
    uv.fs_open(full_path, "r", read_flags, function(err, fd)
      -- print("A: " .. full_path)
      if err then error("Failed to open " .. full_path) end
      uv.fs_fstat(fd, function(err, stat)
        -- print("B: " .. full_path)
        if err then error("fs_fstat() failed for " .. fullpath) end
        uv.fs_read(fd, stat.size, read_flags, function(err, src)
          -- print("C: " .. full_path)
          if err then error("Failed reading " .. fullpath) end
          local out_src = options.process_src(src, {dir=dir, filepath=filepath, full_path=full_path, prnt=prnt, filename=filename, ext=ext, options=options})
          -- print("out:" .. out_src)
          if not out_src then return end
          uv.fs_open(full_out_path, "w", write_flags, function(err, out_fd)
            -- print("D: " .. full_path)
            if err then error("fs_open() failed for " .. full_out_path) end
            uv.fs_write(out_fd, out_src, -1, function(err)
              -- print("E: " .. full_path)
              if err then error("fs_write failed for " .. full_out_path) end
            end)
          end)
        end)
      end)
    end)

  else
    local file = io.open(full_path)
    local src = file:read("*a")
    file:close()
    local out_src = options.process_src(src, {dir=dir, filepath=filepath, full_path=full_path, prnt=prnt, filename=filename, ext=ext, options=options})
    -- print("out:" .. out_src)
    if not out_src then return end
    local out_file, err = io.open(full_out_path, "w+")
    -- print(out_file)
    -- print(err)
    out_file:write(out_src)
    out_file:close()
  end
end

lct.default_options = {
  process_src = false,
  process_file = lct.process_file_default,
  in_dirs = false, --{"./"},
  out_dir = "/tmp/lua_code_tool/" .. lct.user .. "/",
  exclude_dirs = {},
  in_exts = false,
  verbose = false,
  quiet = false,
}

function lct.process_files(options)
  assert(options.process_src, "process_src must be set")
  assert(options.in_dirs, "in_dirs must be set")
  assert(next(options.in_dirs), "in_dirs must be set")
  lct.set_defaults_strict(options, lct.default_options)
  if options.verbose then print("options: " .. inspect(options)) end

  local dirs = {}
  for i, dir in ipairs(options.in_dirs) do
    dirs[i] = dir
  end

  local coros = {}
  local events = lct.create_events_table()
  for _, dir in ipairs(dirs) do
    -- if options.verbose then print("mkdir -p " .. options.out_dir .. "/" .. dir) end
    -- os.execute("mkdir -p " .. options.out_dir .. "/" .. dir)
    -- print("dir:" .. dir)

    for filepath in lfs.dir(dir) do
      local full_path = dir .. "/" .. filepath
      local attr = lfs.attributes(dir .. "/" .. filepath)
      local filetype = attr.mode
    -- for _, filepath in ipairs(fs.readdirSync(dir)) do
    --   local full_path = dir .. "/" .. filepath
    --   local stat = fs.stat(full_path)
    --   print(inspect(stat))
    --   local filetype = stat.type
      if options.verbose then
        print("Walking path: " .. dir .. "/" .. filepath)
        print("filetype: " .. filetype)
        print("filepath:" .. filepath)
      end
      for _, d in ipairs(options.exclude_dirs) do -- filter out exclude_dirs
        if dir:sub(-#d) == d then goto continue end
      end
      if filepath == "lock.lock" then
        error("Directory contains file lock.lock, suggesting it's an output directory")
      end
      if filepath ~= "." and filepath ~= ".." then
        if filetype == "file" then
          -- TODO: Use io.popen
          local co = coroutine.create(options.process_file)
          coros[filepath] = {co = co, dir = dir, filepath = filepath}
        elseif filetype == "directory" then
          table.insert(dirs, dir .. "/" .. filepath)
        end
      end
      ::continue::
    end
  end

  -- Run all coroutines
  -- Note, some coroutines may yield on events, but all of them should be resumed by other coroutines in the end.
  for filename, co_obj in pairs(coros) do
    local co = co_obj.co
    local dir = co_obj.dir
    local filepath = co_obj.filepath
    local status = coroutine.status(co)
    assert(status == "suspended")
    coroutine.resume(co, dir, filepath, options, events)
  end
  -- Check for deadlock. After resuming every coroutine once, we expect all coroutines to be finished, except if we got a deadlock.
  for filename, co_obj in pairs(coros) do
    local co = co_obj.co
    local status = coroutine.status(co)
    assert(status == "dead")
  end
 end

return lct
