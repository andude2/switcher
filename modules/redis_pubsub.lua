-- modules/redis_pubsub.lua
local mq = require('mq')
local socket = require("socket")
local dkjson = require("dkjson")

local M = {}
M.subscriptions = {}
M.connected = false
M.host = "127.0.0.1"
M.port = 6379
M.peer_list = {}

-- Pub/Sub internals
local buffer = {}
local subscriber = nil

-- Command handling
local command_queue = {}
local channel_prefix = "cmd/"
local myname = mq.TLO.Me.CleanName() or "unknown"
local myserver = mq.TLO.EverQuest.Server() or "unknown"
local my_channel_id = myserver .. "_" .. myname

local function connect()
    local client = socket.tcp()
    client:settimeout(0)
    local success, err = client:connect(M.host, M.port)
    if not success and err ~= "timeout" then
        print("\ar[Redis] Connection failed: " .. err)
        return nil
    end
    return client
end

local function read_line(sock)
    local data, err = sock:receive("*l")
    if not data and err ~= "timeout" then
        return nil, err
    end
    return data
end

function M.publish(channel, message)
    local client = connect()
    if not client then return end
    local cmd = string.format("*3\r\n$7\r\nPUBLISH\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n",
        #channel, channel, #message, message)
    client:send(cmd)
    client:close()
end

function M.subscribe(name, callback)
    if M.subscriptions[name] then return end
    M.subscriptions[name] = callback
    
    -- If subscriber is already active, we need to update subscriptions
    if subscriber then
        local sub_cmd = string.format("*2\r\n$9\r\nSUBSCRIBE\r\n$%d\r\n%s\r\n", #name, name)
        subscriber:send(sub_cmd)
    end
    
    print("\ag[Redis] Subscribed to channel: " .. name)
end

function M.poll()
    if not subscriber then
        subscriber = connect()
        if not subscriber then return end

        local subs = {}
        for ch in pairs(M.subscriptions) do
            table.insert(subs, string.format("$%d\r\n%s", #ch, ch))
        end

        if #subs > 0 then
            local sub_cmd = string.format("*%d\r\n$9\r\nSUBSCRIBE\r\n%s\r\n", #subs + 1, table.concat(subs, "\r\n"))
            subscriber:send(sub_cmd)
        else
            -- At minimum, subscribe to our own command channel
            local cmd_channel = channel_prefix .. my_channel_id
            local sub_cmd = string.format("*2\r\n$9\r\nSUBSCRIBE\r\n$%d\r\n%s\r\n", #cmd_channel, cmd_channel)
            subscriber:send(sub_cmd)
            M.subscriptions[cmd_channel] = handleIncoming
            print("\ag[Redis] Auto-subscribed to: " .. cmd_channel)
        end
    end

    while true do
        local line, err = read_line(subscriber)
        if not line then break end
        table.insert(buffer, line)

        if #buffer >= 7 and buffer[1] == "*3" and buffer[3] == "message" then
            local channel = buffer[5]
            local payload = buffer[7]
            local callback = M.subscriptions[channel]
            if callback then callback(payload) end
            buffer = {}
        elseif #buffer > 7 then
            buffer = {}
        elseif line == "*3" and #buffer > 1 then
            buffer = {line}
        end
    end
end

-- ============================================
-- COMMAND SYSTEM
-- ============================================

-- Queue a command for execution
local function queueCommand(cmd)
    table.insert(command_queue, cmd)
end

-- Process queued commands
function M.processQueuedCommands()
    while #command_queue > 0 do
        local cmd = table.remove(command_queue, 1)
        if cmd then
            mq.cmdf("%s", cmd)
        end
    end
end

-- Handle incoming Redis command messages
local function handleIncoming(payload)
    local decoded, pos, err = dkjson.decode(payload, 1, nil)
    if not decoded then
        print("\ar[Redis] JSON decode error: " .. tostring(err))
        return
    end
    
    if decoded.command then
        print("\ag[Redis] Received command: " .. decoded.command)
        queueCommand(decoded.command)
    end
end

-- Set the peer list from the main module
function M.setPeerList(peers)
    M.peer_list = peers
end

-- Send command to a single peer
function M.sendToPeer(peer, command)
    local target_id
    
    -- First check if this is a servername_peername format
    if peer:find("_") then
        target_id = peer
    else
        -- Otherwise, find the peer in our peer list
        for id, data in pairs(M.peer_list) do
            if data.name == peer or data.display_name == peer then
                target_id = id
                break
            end
        end
    end
    
    if not target_id then
        print("\ar[Redis] Peer not found: " .. peer)
        return
    end
    
    local payload = { source = my_channel_id, target = target_id, command = command }
    local message = dkjson.encode(payload)
    local channel = channel_prefix .. target_id
    
    print("\ag[Redis] Sending to " .. target_id .. ": " .. command)
    M.publish(channel, message)
end

-- Send command to partial match peers
function M.sendToPartial(partial, command)
    local matched = false
    for id, data in pairs(M.peer_list) do
        local name = data.name or data.display_name or ""
        if name:lower():find(partial:lower(), 1, true) and id ~= my_channel_id then
            M.sendToPeer(id, command)
            matched = true
        end
    end
    
    if not matched then
        print("\ar[Redis] No peers matched pattern: " .. partial)
    end
end

-- Send command to all peers EXCEPT self
function M.sendToAllExceptSelf(command)
    local sent = 0
    for id, _ in pairs(M.peer_list) do
        if id ~= my_channel_id then
            M.sendToPeer(id, command)
            sent = sent + 1
        end
    end
    
    print("\ag[Redis] Command sent to " .. sent .. " peers")
end

-- Send command to all peers INCLUDING self
function M.sendToAllIncludingSelf(command)
    local sent = 0
    for id, _ in pairs(M.peer_list) do
        if id ~= my_channel_id then
            M.sendToPeer(id, command)
            sent = sent + 1
        end
    end
    
    queueCommand(command) -- locally queue for self
    print("\ag[Redis] Command sent to " .. sent .. " peers (including self)")
end

-- ============================================
-- INITIALIZE
-- ============================================

-- Create personal command channel name and subscribe to it
local my_cmd_channel = channel_prefix .. my_channel_id
M.subscribe(my_cmd_channel, handleIncoming)

return M