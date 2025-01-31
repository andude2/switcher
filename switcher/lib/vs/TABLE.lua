-- LUA Table library.
-- Cobbled together from code snippets on gist.github.com and other places.

local TABLE = {}

function TABLE.name()
  return 'TABLE'
end

function TABLE.version()
  return 1, 0
end

function TABLE.checkVersion(req_major,req_minor)
  local major, minor = TABLE.version()
  if major < req_major or (major == req_major and minor < req_minor) then
    print(string.format('Error: %s library version %d.%d detected. Program requires %s library version %d.%d or later.',TABLE.name(),major,minor,TABLE.name(),req_major,req_minor))
    return false
  end
end

-- Deep compare two tables.
function TABLE.compare(t1, t2, ignore_mt)

  if type(t1) ~= type(t2) then
    return false
  end
      
  if type(t1) ~= 'table' and type(t2) ~= 'table' then
    return t1 == t2
  end  
  
  local mt = getmetatable(t1)
  if not ignore_mt and mt and mt.__eq then
    return t1 == t2
  end

  for k1, v1 in pairs(t1) do
    local v2 = t2[k1]
    if v2 == nil or not TABLE.compare(v1, v2) then
      return false
    end
  end

  for k2, _ in pairs(t2) do
    if t1[k2] == nil then
        return false
    end
  end
  
  return true
  
end

-- Deep copy two tables.
function TABLE.copy(t1, seen)

  if t1 == nil or type(t1) ~= 'table' then
    return t1
  end
  
  seen = seen or {}
  if seen[t1] then return seen[t1] end

  local new_t1 = {}
  seen[t1] = new_t1

  for k, v in next, t1, nil do
    new_t1[TABLE.copy(k, seen)] = TABLE.copy(v, seen)
  end
  
  return setmetatable(new_t1, TABLE.copy(getmetatable(t1), seen))

end

return TABLE