#!/usr/bin/lua
-- Author: John Emanuelsson
-- File created 2025-04-05 15:46:33 CEST

local lfs = require("lfs")
local inspect =  require("inspect")

local cf = {}

function cf.set_defaults(trgt, src)
  for k, v in pairs(src) do
    if trgt[k] == nil then
      trgt[k] = v
    end
  end
end

function cf.set_defaults_strict(trgt, src)
  cf.set_defaults(trgt, src)
  -- print(inspect(src))
  -- print(inspect(trgt))
  for k, _ in pairs(trgt) do
    assert(src[k] ~= nil, k .. " set to target table, but not found among default-values")
  end
end

function cf.process_file_default(dir, filepath, options)
  local full_path = dir .. "/" .. filepath
  -- local prnt, filename, ext = filepath:match("^(.*/)?(.?[^/%.]+)(%..*)?$")
  -- local filename, ext = filepath:match("^(.?[^/%.]+)(%..*)?$")
  -- local filename, ext = filepath:match("([^/%.]+)(%..*)?")
  local filename, ext = filepath:match("([^/%.]+)%.(.*)")
  -- print(filename)
  -- print(ext)
  if not ext then return end
  if options.in_exts and next(options.in_exts) then -- Filter by in_exts
    if not options.in_exts[ext] then return end
  end
  for _, d in ipairs(options.exclude_dirs) do -- filter out exclude_dirs
    if dir:sub(1, #d) == d then return end
  end
  if dir:sub(1, #options.out_dir) == options.our_dir then return end -- Output can't be input
  if options.verbose then print("# " .. filepath .. ":") end
  local file = io.open(full_path)
  local src = file:read("*a")
  file:close()
  local out_src = options.process_src(src, {dir=dir, filepath=filepath, full_path=full_path, prnt=prnt, filename=filename, ext=ext, options=options})
  -- print("out:" .. out_src)
  if not out_src then return end
  local full_out_path = options.out_dir .. "/" .. full_path
  -- print("out_path:" .. full_out_path)
  
  local out_file, err = io.open(full_out_path, "w+")
  -- print(out_file)
  -- print(err)
  out_file:write(out_src)
  out_file:close()
end

cf.default_options = {
  process_src = false,
  process_file = cf.process_file_default,
  in_dirs = false, --{"./"},
  out_dir = "./cf_tmp",
  exclude_dirs = {},
  in_exts = false,
  verbose = false,
  quiet = false,
}

function cf.process_files(options)
  assert(options.process_src, "process_src must be set")
  assert(options.in_dirs, "in_dirs must be set")
  assert(next(options.in_dirs), "in_dirs must be set")
  cf.set_defaults_strict(options, cf.default_options)
  if options.verbose then print("options: " .. inspect(options)) end

  local dirs = {}
  for i, dir in ipairs(options.in_dirs) do
    dirs[i] = dir
  end
  for _, dir in ipairs(dirs) do
    if options.verbose then print("mkdir -p " .. options.out_dir .. "/" .. dir) end
    os.execute("mkdir -p " .. options.out_dir .. "/" .. dir)
    -- print("dir:" .. dir)
    for filepath in lfs.dir(dir) do
      local attr = lfs.attributes(dir .. "/" .. filepath)
      -- print("Walking path: " .. dir .. "/" .. filepath)
      -- print("mode:" .. attr.mode)
      if filepath ~= "." and filepath ~= ".." then
        if attr.mode == "file" then
          -- TODO: Use io.popen
          options.process_file(dir, filepath, options)
        elseif attr.mode == "directory" then
          table.insert(dirs, dir .. "/" .. filepath)
        end
      end
    end
  end
end

return cf
