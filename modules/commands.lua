-- peercommands.lua - centralized actor-based command system
local mq = require('mq')
local actors = require('actors')
local json = require('dkjson')

local M = {}

local MAILBOX_NAME = 'peer_command'
local actor = nil
local connectedPeers = {} -- Table to track connected peers and timestamps
local last_peer_refresh = 0
local PEER_REFRESH_INTERVAL = 60 -- More frequent refresh than before
local initialized = false

-- Util: get clean peer ID
local function peer_id()
    return mq.TLO.EverQuest.Server() .. '_' .. mq.TLO.Me.CleanName()
end

-- Util: get character short name only
local function peer_name()
    return mq.TLO.Me.CleanName()
end

-- Extract character name from peer ID
local function extract_peer_name(peer_id)
    local _, _, name = string.find(peer_id, "([^_]+)$")
    return name
end

-- Check if a peer is still connected and remove if not
local function check_remove_peer(peer)
    return function(status, content)
        if status < 0 then
            print("[PeerCommand] Lost connection to peer: " .. peer)
            connectedPeers[peer] = nil
        end
    end
end

-- Announce our presence and handle registration
local function announce_presence()
    --print("[PeerCommand] Broadcasting presence announcement")
    actor:send({type = 'Announce', from = peer_name()})
end

-- Command handler (executes incoming commands)
local function handle_message(message)
    local data = message()
    
    if not data or type(data) ~= 'table' then
        print('\ar[PeerCommand] Invalid message received\ax')
        return
    end
    
    -- Handle different message types
    if data.type == 'Announce' then
        -- Someone announced their presence, register them
        if data.from then
            --print(string.format('\ag[PeerCommand] Peer %s announced presence\ax', data.from))
            connectedPeers[data.from] = mq.gettime()
            -- Respond with our own registration
            message:send({type = 'Register', from = peer_name()})
        end
    elseif data.type == 'Register' then
        -- Someone registered with us
        if data.from then
            --print(string.format('\ag[PeerCommand] Registered peer %s\ax', data.from))
            connectedPeers[data.from] = mq.gettime()
        end
    elseif data.type == 'Command' then
        -- Execute a command
        local cmd = data.command
        local intended = data.target
        local me_name = peer_name()
        
        if not intended or intended == me_name then
            print(string.format('\ag[PeerCommand] Executing: \ay%s\ax', cmd))
            mq.cmd(cmd)
        else
            print(string.format('[PeerCommand] Ignoring command intended for %s', tostring(intended)))
        end
    end
end

-- Send command to one peer
function M.send(peer_name, command)
    if not peer_name or not command then return false end
    
    if connectedPeers[peer_name] then
        print(string.format('[PeerCommand] Sending to %s: %s', peer_name, command))
        actor:send({character = peer_name}, {type = 'Command', command = command}, check_remove_peer(peer_name))
        return true
    else
        print(string.format('\ar[PeerCommand] Peer %s not connected or registered\ax', peer_name))
        return false
    end
end

-- Send command to all peers
function M.broadcast(command)
    if not command then return 0 end
    
    local sent = 0
    print(string.format('[PeerCommand] Broadcasting command: %s', command))
    
    for peer, _ in pairs(connectedPeers) do
        if peer ~= peer_name() then
            actor:send({character = peer}, {type = 'Command', command = command}, check_remove_peer(peer))
            sent = sent + 1
        end
    end
    
    if sent > 0 then
        print(string.format('[PeerCommand] Command sent to %d peers', sent))
    else
        print('\ay[PeerCommand] No peers connected to receive command\ax')
    end
    
    return sent
end

-- Periodically refresh connections and announce presence
local function maintain_connections()
    local now = mq.gettime()
    
    -- Check for stale connections (no activity for 5 minutes)
    for peer, last_seen in pairs(connectedPeers) do
        if now - last_seen > 300 then -- 5 minutes
            --print(string.format('\ay[PeerCommand] Peer %s connection timed out\ax', peer))
            connectedPeers[peer] = nil
        end
    end
    
    -- Re-announce presence periodically
    if now - last_peer_refresh >= PEER_REFRESH_INTERVAL then
        announce_presence()
        last_peer_refresh = now
    end
end

-- List connected peers
function M.list_peers()
    local count = 0
    print('\ag[PeerCommand] Connected peers:\ax')
    
    for peer, _ in pairs(connectedPeers) do
        print(string.format('  - %s', peer))
        count = count + 1
    end
    
    if count == 0 then
        print('  No peers connected')
    end
    
    return count
end

-- Bind commands
mq.bind("/actexec", function(...) -- local execution
    local cmd = table.concat({...}, " ")
    print(string.format('[PeerCommand] Executing locally: %s', cmd))
    mq.cmd(cmd)
end)

mq.bind("/acaa", function(...) -- broadcast to all
    local cmd = table.concat({...}, " ")
    if cmd == '' then
        print("Usage: /acaa <command>")
        return
    end
    M.broadcast(cmd)
    mq.cmdf("%s", cmd)
end)

mq.bind("/aca", function(...) -- broadcast to all except self
    local cmd = table.concat({...}, " ")
    if cmd == '' then
        print("Usage: /aca <command>")
        return
    end
    
    local sent = 0
    for peer, _ in pairs(connectedPeers) do
        if peer ~= peer_name() then
            M.send(peer, cmd)
            sent = sent + 1
        end
    end
    
    print(string.format('Sent to %d peers: %s', sent, cmd))
end)

mq.bind("/actell", function(...) -- send to one peer
    local args = {...}
    if #args < 2 then
        print("Usage: /actell <peer> <command>")
        return
    end
    local peer = args[1]
    local cmd = table.concat(args, " ", 2)
    
    if not M.send(peer, cmd) then
        print(string.format('\ar[PeerCommand] Failed to send command to %s\ax', peer))
    end
end)

mq.bind("/aclist", function(...) -- list connected peers
    M.list_peers()
end)

-- Setup maintenance timer - THIS WILL BE CALLED AFTER MODULE IS LOADED
function M.setup_maintenance()
    if not initialized then
        print('[PeerCommand] Setting up maintenance timer')
        -- Setup a timer event to periodically maintain connections
        mq.event('PeerCommandMaintenance', '#*#', function()
            maintain_connections()
        end)
        mq.cmdf('/timed 30 /doevents PeerCommandMaintenance')
        initialized = true
    end
end

-- Initialize the module
function M.init()
    if actor then
        -- Already initialized
        return
    end
    
    -- Register our actor with the mailbox
    actor = actors.register(MAILBOX_NAME, handle_message)
    print('[PeerCommand] Registered actor mailbox: ' .. MAILBOX_NAME)
    
    -- Initial announcement
    announce_presence()
    
    print('[PeerCommand] Initial setup complete')
    
    -- We don't call setup_maintenance here to avoid delays during import
end

-- Initialize the module when loaded, but without the maintenance timer
M.init()

-- Return the module
return M