-- LUA FIFO Queue library.

local FIFO={}

--[[ Return the library name.
     Return.: name - the library name
  ]]
function FIFO.name()
  return 'FIFO'
end

--[[ Return the library version.
     Return.: major, minor - FIFO version
  ]]
function FIFO.version()
  return 1, 0
end

--[[ Checks library version.
     Param..: req_major, req_minor - the required minimum library version
  ]]
function FIFO.checkVersion(req_major,req_minor)
  local major, minor = FIFO.version()
  if major < req_major or (major == req_major and minor < req_minor) then
    print(string.format('Error: %s library version %d.%d detected. Program requires %s library version %d.%d or later.',FIFO.name(),major,minor,FIFO.name(),req_major,req_minor))
    return false
  end
end

--[[ Create a new empty FIFO. ]]
function FIFO.new()
    return {head=0,tail=-1}
end

--[[ Flush the FIFO. ]]
function FIFO.flush(fifo)
  while FIFO.empty(fifo) == false do
    FIFO.pop(fifo)
  end
end

--[[ Insert a value at the end of the FIFO.
  ]]
function FIFO.push(fifo,value)
  local tail=fifo.tail+1
  fifo.tail=tail
  fifo[tail]=value
end

--[[ Remove a value from the front of the FIFO.
  ]]
function FIFO.pop(fifo)
  local head=fifo.head
  local tail=fifo.tail
  local value=nil
  if head<=tail then
    value=fifo[head]
    fifo[head]=nil
    fifo.head=head+1
  end
  return value
end

--[[ Determine if the FIFO is empty.
  ]]
function FIFO.empty(fifo)
  return fifo.head > fifo.tail
end

--[[ Return number of items in the FIFO.
  ]]
function FIFO.count(fifo)
  if FIFO.empty(fifo) then return 0 end
  return fifo.tail - fifo.head + 1
end

return FIFO
