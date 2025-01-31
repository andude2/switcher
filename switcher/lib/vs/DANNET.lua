local mq = require 'mq'

local DANNET = {}

--[[ Return the library name.
      @return   the library name
]]
function DANNET.name()
  return 'DANNET'
end

--[[ Return the library version.
      @return   major, minor - DANNET version
]]
function DANNET.version()
  return 1, 1
end

--[[ Checks library version.
      @param    req_major, req_minor - the required minimum library version
      @return   true if required minimum version met
]]
function DANNET.checkVersion(req_major,req_minor)
  local major, minor = DANNET.version()
  if major < req_major or (major == req_major and minor < req_minor) then
    print(string.format('Error: %s library version %d.%d detected. Program requires %s library version %d.%d or later.',DANNET.name(),major,minor,DANNET.name(),req_major,req_minor))
    return false
  end
  return true
end

--[[ Add an observer.
      @param    peer        - name of the peer to observe
      @param    query       - query (e.g., 'Me.Invis[1]')
      @timeout  timeout_ms  - optional timeout in ms, default is 1000ms
      @return   true if successful (or observer already present)
]]
function DANNET.addObserver(peer,query,timeout_ms)
  if not mq.TLO.DanNet(peer).OSet(query)() then
    mq.cmdf('/dobserve %s -q "%s"', peer, query)
  end
  mq.delay(timeout_ms or 1000, function() return mq.TLO.DanNet(peer).OSet(query)() == true end)
  return mq.TLO.DanNet(peer).OSet(query)()
end

--[[ Remove an observer.
      @param    peer        - name of the peer to observe
      @param    query       - query (e.g., 'Me.Invis[1]')
      @timeout  timeout_ms  - optional timeout in ms, default is 1000ms
      @return   true if successful (or observer already dropped)
]]
function DANNET.dropObserver(peer,query,timeout_ms)
  if mq.TLO.DanNet(peer).OSet(query)() then
    mq.cmdf('/dobserve %s -q "%s" -drop', peer, query)
  end
  mq.delay(timeout_ms or 1000, function() return mq.TLO.DanNet(peer).OSet(query)() == false end)
  return not mq.TLO.DanNet(peer).OSet(query)()
end

--[[ Determine if we have an observer.
      @param    peer        - name of the peer to observe
      @param    query       - query (e.g., 'Me.Invis[1]')
      @return   true if observer exists
]]
function DANNET.observing(peer,query)
  return mq.TLO.DanNet(peer).OSet(query)()
end

--[[ Returns the most recent observation result.
      @param    peer        - name of the peer to observe
      @param    query       - query (e.g., 'Me.Invis[1]')
      @timeout  timeout_ms  - optional timeout in ms, default is 1000ms
      @return   observation result (or nil if no result)
]]
function DANNET.observe(peer,query,timeout_ms)
  mq.delay(timeout_ms or 1000, function() return mq.TLO.DanNet(peer).O(query)() ~= nil end)
  local result = mq.TLO.DanNet(peer).O(query)()
  if type(result) == 'string' then
    if result == 'TRUE' then return true end
    if result == 'FALSE' then return false end
    if result == 'NULL' then return nil end
  end
  return result
end

--[[ Performs an on-demand query.
      @param    peer        - name of the peer to observe
      @param    query       - query (e.g., 'Me.Invis[1]')
      @timeout  timeout_ms  - optional timeout in ms, default is 1000ms
      @return   query result (or nil if no result)
]]
function DANNET.query(peer,query,timeout_ms)
  mq.cmdf('/dquery %s -q "%s"', peer, query)
  mq.delay(timeout_ms or 1000, function() return mq.TLO.DanNet(peer).Q(query)() ~= nil end)
  local result = mq.TLO.DanNet(peer).Q(query)()
  if type(result) == 'string' then
    if result == 'TRUE' then return true end
    if result == 'FALSE' then return false end
    if result == 'NULL' then return nil end
  end
  return mq.TLO.DanNet(peer).Q(query)()
end

--[[ Obtain list of peers.
      @return   table of peer names
     Useful until issue with DanNet.Peers() is resolved.
]]
function DANNET.getPeers()
  local peers = {}
  local peerList = mq.TLO.DanNet.Peers()
  for peer in string.gmatch(peerList, '([^|]+)') do
    table.insert(peers,peer)
  end
  mq.delay(200) -- A delay seems to be required to prevent next query/obs from being messed up
  return peers
end

--[[ Create an empty observer list.
      @return   empty observer list table
]]
function DANNET.newObserverList()
  return { peers={}, queries={} }
end

--[[ Add any missing queries in an observer list.
      @param    list  - the observer list
      @return   none
]]
function DANNET.addObserversForList(list)
  for i, peer in ipairs(list.peers) do
    for j, query in ipairs(list.queries) do
      if not DANNET.observing(peer,query) then
        DANNET.addObserver(peer,query)
      end
    end
  end
end

--[[ Drops all observers for a peer.
      @param    list  - the observer list
      @param    peer  - the peer name
      @return   none
]]
function DANNET.dropObserversForPeer(list,peer)
  for i, query in ipairs(list.queries) do
    DANNET.dropObserver(peer,query)
  end
end

--[[ Drops all observers for a query.
      @param    list  - the observer list
      @param    query - the query
      @return   none
]]
function DANNET.dropObserversForQuery(list,query)
  for i, peer in ipairs(list.peers) do
    DANNET.dropObserver(peer,query)
  end
end

--[[ Add a peer to an observer list.
      @param    list  - the observer list
      @param    peer  - the peer name
      @return   none
]]
function DANNET.addPeer(list,peer)
  for i, p in ipairs(list.peers) do
    if p == peer then return end
  end
  table.insert(list.peers,peer)
  DANNET.addObserversForList(list)
end

--[[ Remove a peer from an observer list.
      @param    list  - the observer list
      @param    peer  - the peer name
      @return   none
]]
function DANNET.removePeer(list,peer)
  for i, p in ipairs(list.peers) do
    if p == peer then
      DANNET.dropObserversForPeer(list,peer)
      table.remove(list.peers,i)
    end
  end
end

--[[ Add a query to an observer list.
      @param    list  - the observer list
      @param    query - the query (e.g., 'Me.Invis[]')
      @return   none
]]
function DANNET.addQuery(list,query)
  for i, q in ipairs(list.queries) do
    if q == query then return end
  end
  table.insert(list.queries,query)
  DANNET.addObserversForList(list)
end

--[[ Remove a query from an observer list.
      @param    list  - the observer list
      @param    query - the query (e.g., 'Me.Invis[]')
      @return   none
]]
function DANNET.removeQuery(list,query)
  for i, q in ipairs(list.queries) do
    if q == query then
      DANNET.dropObserversForQuery(list,query)
      table.remove(list.queries,i)
    end
  end
end

--[[ Remove all peers and queries from an observer list.
      @param    list  - the observer list
      @return   none
]]
function DANNET.removeAll(list)
  for i, peer in ipairs(list.peers) do
    for j, query in ipairs(list.queries) do
      DANNET.dropObserver(peer,query)
    end
  end
  list.peers = {}
  list.queries = {}
end

--[[ Outputs the observers in an observer list.
      @param    list  - the observer list
      @return   none
]]
function DANNET.showObservers(list)
  for i, peer in ipairs(list.peers) do
    print(peer..':')
    for j, query in ipairs(list.queries) do
      print(' '..query..'='..tostring(DANNET.observing(peer,query)))
    end
  end
end

return DANNET