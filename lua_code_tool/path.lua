-- © 2025 John Emanuelsson
-- File created 2025-11-28 22:36:59 CET
-- TODO: Windows support
local lfs = require("lfs")

local path = {}

-- Note that the first / on a full path will not become a part.
function path.to_parts(p)
  return p:gmatch("[^/]")
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
  if path.is_absolute(b) then
    return nil
  end
  a = a:gsub("/+$", "") -- Remove trailing /
  return a .. "/" .. b
end

function path.split(p)
  dir, filename = p:match("^(.-)([^/\\]*)$")
  basename, ext = filename:match("^(.-)(%.[^%.]*)$")
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
  local inspect = require("inspect")
  print(inspect(shortcut_map))
  local best_p = p
  local best_p_part_cnt = #path.to_parts(p)
  for k, v in pairs(shortcut_map) do
    print("key")
    print(k)
    print("val")
    print(v)
    local new_p = p:gsub(k, v)
    local new_p_part_cnt = #path.to_parts(new_p)
    if new_p_part_cnt < best_p_part_cnt then
      best_p = new_p
      best_p_part_cnt = new_p_part_cnt
    end
  end
  return best_p
end

return path
