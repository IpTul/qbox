-- lastresort_loading
-- LastResort Development · https://intelnpc.com

local function trim(s)
    return (s or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function sendPage(payload)
    SendLoadingScreenMessage(json.encode(payload))
end

local function manualShutdown()
    local v = GetResourceMetadata(GetCurrentResourceName(), 'loadscreen_manual_shutdown', 0)
    return v == 'yes' or v == 'true' or v == '1'
end

local playerName = nil

local function sendName(name)
    name = trim(name)
    if name == '' then return end
    playerName = name
    sendPage({ eventName = 'setPlayerName', name = name })
end

local function resourceRunning(res)
    local state = GetResourceState(res)
    return state == 'started' or state == 'starting'
end

local handlers = {
    {
        name = 'qbox',
        detect = function() return resourceRunning('qbx_core') end,
        read = function()
            local ok, pd = pcall(function() return exports.qbx_core:GetPlayerData() end)
            if not ok or not pd or not pd.charinfo then return nil end
            return (pd.charinfo.firstname or '') .. ' ' .. (pd.charinfo.lastname or '')
        end,
        events = { 'qbx_core:client:playerLoaded', 'QBCore:Client:OnPlayerLoaded' },
    },
    {
        name = 'qbcore',
        detect = function() return resourceRunning('qb-core') end,
        read = function()
            local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
            if not ok or not core or not core.Functions then return nil end
            local pd = core.Functions.GetPlayerData()
            if not pd or not pd.charinfo then return nil end
            return (pd.charinfo.firstname or '') .. ' ' .. (pd.charinfo.lastname or '')
        end,
        events = { 'QBCore:Client:OnPlayerLoaded' },
    },
    {
        name = 'esx',
        detect = function() return resourceRunning('es_extended') end,
        read = function()
            local ok, ESX = pcall(function() return exports['es_extended']:getSharedObject() end)
            if not ok or not ESX then return nil end
            local data = ESX.GetPlayerData()
            if not data or not data.firstName then return nil end
            return (data.firstName or '') .. ' ' .. (data.lastName or '')
        end,
        events = { 'esx:playerLoaded' },
    },
    {
        name = 'vrp',
        detect = function() return resourceRunning('vrp') end,
        read = function()
            local ok, Proxy = pcall(function() return module('vrp', 'lib/Proxy') end)
            if not ok or not Proxy then return nil end
            local vRP = Proxy.getInterface('vRP')
            local uid = vRP.getUserId({})
            if not uid then return nil end
            local identity = vRP.getUserIdentity({ uid })
            if not identity then return nil end
            return (identity.firstname or '') .. ' ' .. (identity.name or '')
        end,
        events = { 'vRP:playerSpawn' },
    },
}

local selected
for _, h in ipairs(handlers) do
    if h.detect() then
        selected = h
        break
    end
end

local function attemptFramework()
    if not selected then return end
    local n = selected.read()
    if n then sendName(n) end
end

if selected then
    for _, ev in ipairs(selected.events) do
        RegisterNetEvent(ev, attemptFramework)
    end
end

CreateThread(function()
    local pid = PlayerId()
    local waited = 0
    while waited < 5000 do
        local name = GetPlayerName(pid)
        if name and name ~= '' and name ~= '**Invalid**' then
            sendName(name)
            return
        end
        Wait(waited < 1000 and 0 or 100)
        waited = waited + (waited < 1000 and 16 or 100)
    end
end)

local lastStats = nil

local function sendStats()
    if not lastStats then return end
    sendPage({
        eventName = 'serverStats',
        players = lastStats.players,
        maxPlayers = lastStats.maxPlayers,
        ping = lastStats.ping,
        serverName = lastStats.serverName
    })
end

RegisterNetEvent('lastresort_loading:stats', function(stats)
    if type(stats) ~= 'table' then return end
    lastStats = {
        players = tonumber(stats.players),
        maxPlayers = tonumber(stats.maxPlayers),
        ping = tonumber(stats.ping),
        serverName = stats.serverName
    }
    if not playerName and type(stats.name) == 'string' then sendName(stats.name) end
    sendStats()
end)

-- This script only starts once the client has the resources, which is late in
-- the join — by then the page has been up on handover data for a while. The
-- first request goes out on the very first frame and the early retries are
-- dense, because the answer is what turns the connect-time snapshot into the
-- live numbers. It slows down once the screen is showing real data.
local function statsInterval(elapsed, gotStats)
    if gotStats then return 2000 end
    if elapsed < 5000 then return 250 end
    if elapsed < 20000 then return 1000 end
    return 2000
end

CreateThread(function()
    local elapsed = 0
    while not NetworkIsSessionStarted() and elapsed < 120000 do
        TriggerServerEvent('lastresort_loading:requestStats')
        local wait = statsInterval(elapsed, lastStats ~= nil)
        Wait(wait)
        elapsed = elapsed + wait
    end
end)

local VOLUME_KEY = 'lastresort_loading:volume'

local pageAlive = false
local content = nil
local contentReceived = false
local gate = { required = false, version = '', answered = false, warned = false }

local function storedVolume()
    local v = tonumber(GetResourceKvpString(VOLUME_KEY) or '')
    if not v then return nil end
    return math.floor(math.max(0, math.min(100, v)))
end

local function sendContent()
    if not content then return end
    sendPage({ eventName = 'serverContent', news = content.news, tips = content.tips })
end

local function sendGate()
    if not gate.required or gate.answered then return end
    sendPage({ eventName = 'rulesGate', version = gate.version })
end

local function replay()
    if playerName then sendPage({ eventName = 'setPlayerName', name = playerName }) end
    local v = storedVolume()
    if v then sendPage({ eventName = 'storedVolume', volume = v }) end
    sendStats()
    sendContent()
    sendGate()
end

RegisterNUICallback('lrlHello', function(_, cb)
    pageAlive = true
    replay()
    cb('ok')
end)

RegisterNUICallback('lrlVolume', function(data, cb)
    local v = tonumber(type(data) == 'table' and data.volume or nil)
    if v then
        SetResourceKvp(VOLUME_KEY, tostring(math.floor(math.max(0, math.min(100, v)) + 0.5)))
    end
    cb('ok')
end)

RegisterNUICallback('lrlRulesAccept', function(_, cb)
    if gate.required and not gate.answered then
        TriggerServerEvent('lastresort_loading:acceptRules')
    end
    cb('ok')
end)

RegisterNUICallback('lrlRulesDecline', function(data, cb)
    if gate.required and not gate.answered then
        TriggerServerEvent('lastresort_loading:declineRules', type(data) == 'table' and data.locale or nil)
    end
    cb('ok')
end)

RegisterNetEvent('lastresort_loading:content', function(payload)
    if type(payload) ~= 'table' then return end
    contentReceived = true
    content = { news = payload.news, tips = payload.tips }
    sendContent()
    local g = payload.gate
    if type(g) == 'table' and g.required == true and not gate.answered then
        if manualShutdown() then
            gate.required = true
            gate.version = tostring(g.version or '')
            if pageAlive then sendGate() end
        elseif not gate.warned then
            gate.warned = true
            print(('[%s] rules gate skipped — `loadscreen_manual_shutdown` is off, so the screen cannot be held open for it.')
                :format(GetCurrentResourceName()))
        end
    end
end)

RegisterNetEvent('lastresort_loading:rulesAck', function()
    gate.answered = true
    sendPage({ eventName = 'rulesAccepted' })
end)

CreateThread(function()
    local elapsed = 0
    while not contentReceived and elapsed < 30000 do
        TriggerServerEvent('lastresort_loading:requestContent')
        local wait = elapsed < 5000 and 500 or 2000
        Wait(wait)
        elapsed = elapsed + wait
    end
end)

local CONTENT_GRACE_MS = 4000
local CHANNEL_GRACE_MS = 5000

local function waitForRules()
    local waited = 0
    while not contentReceived and waited < CONTENT_GRACE_MS do
        Wait(100)
        waited = waited + 100
    end
    if not gate.required or gate.answered then return end
    waited = 0
    while not pageAlive and waited < CHANNEL_GRACE_MS do
        Wait(100)
        waited = waited + 100
    end
    if not pageAlive then
        print(('[%s] rules gate skipped — the loading screen never opened its return channel, so nothing could be accepted on it.')
            :format(GetCurrentResourceName()))
        sendPage({ eventName = 'rulesGateOff' })
        return
    end
    sendGate()
    while not gate.answered do
        Wait(100)
    end
end

local screenDone = false

local function markFinished()
    if screenDone then return end
    screenDone = true
    TriggerEvent('lastresort_loading:finished')
end

exports('IsLoadingScreenDone', function()
    return screenDone
end)

local FADE_MS = 700

CreateThread(function()
    if NetworkIsSessionStarted() then
        markFinished()
        return
    end
    while not NetworkIsSessionStarted() do
        Wait(100)
    end
    if manualShutdown() then
        waitForRules()
        sendPage({ eventName = 'fadeOut', durationMs = FADE_MS })
        Wait(FADE_MS + 150)
        ShutdownLoadingScreen()
        ShutdownLoadingScreenNui()
    end
    markFinished()
end)
