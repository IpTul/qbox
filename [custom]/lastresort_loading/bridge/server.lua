-- lastresort_loading
-- LastResort Development · https://intelnpc.com

local function stripColors(s)
    return (tostring(s or ''):gsub('%^%d', ''))
end

local function serverName()
    local n = GetConvar('sv_projectName', '')
    if n == '' then n = GetConvar('sv_hostname', '') end
    return stripColors(n)
end

local function buildStats(src)
    return {
        players = #GetPlayers(),
        maxPlayers = GetConvarInt('sv_maxclients', 48),
        ping = src and GetPlayerPing(tostring(src)) or 0,
        name = src and stripColors(GetPlayerName(src) or '') or nil,
        serverName = serverName()
    }
end

local RESOURCE = GetCurrentResourceName()

local DEFERRAL_OWNERS = {
    ['monitor'] = true,
    ['vmenu'] = true,
    ['easyadmin'] = true
}

local DEFERRAL_OWNER_WORDS = { 'queue', 'whitelist', 'allowlist', 'anticheat' }

local function ownsConnections(res)
    local name = res:lower()
    if DEFERRAL_OWNERS[name] then return true end
    for _, word in ipairs(DEFERRAL_OWNER_WORDS) do
        if name:find(word, 1, true) then return true end
    end
    return false
end

local function findDeferralOwner()
    for i = 0, GetNumResources() - 1 do
        local res = GetResourceByFindIndex(i)
        if res and res ~= RESOURCE then
            local state = GetResourceState(res)
            if (state == 'started' or state == 'starting') and ownsConnections(res) then
                return res
            end
        end
    end
    return nil
end

local forced
do
    local v = GetConvar('lrl:useDeferrals', 'auto'):lower()
    if v == '1' or v == 'true' or v == 'yes' or v == 'on' then
        forced = true
    elseif v == '0' or v == 'false' or v == 'no' or v == 'off' then
        forced = false
    end
end

local scanned, owner, announced = false, nil, 'none'

local function announce()
    local state = owner or 'free'
    if state == announced then return end
    announced = state
    if owner then
        print(('[%s] connect-time handover in passive mode — %s owns the connection deferral, so the data is attached without taking one. Force the deferral with `setr lrl:useDeferrals 1`, or turn the handover off with `setr lrl:useDeferrals 0`.'):format(RESOURCE, owner))
    else
        print(('[%s] connect-time handover on — no queue or whitelist resource is holding connections.'):format(RESOURCE))
    end
end

-- Three answers, not two. Taking the deferral is what makes the data reach the
-- client on a server nobody else defers on; on a server with a queue, taking it
-- would fight the queue, so the payload is attached to the deferral that queue
-- already owns instead. Attaching costs nothing and never holds a connection.
local TAKE, ATTACH, OFF = 'take', 'attach', 'off'

local function handoverMode()
    if forced == true then return TAKE end
    if forced == false then return OFF end
    if not scanned then
        owner = findDeferralOwner()
        scanned = true
        announce()
    end
    return owner == nil and TAKE or ATTACH
end

AddEventHandler('onResourceStart', function() scanned = false end)
AddEventHandler('onResourceStop', function() scanned = false end)

local lastRequest = {}

RegisterNetEvent('lastresort_loading:requestStats', function()
    local src = source
    if not src or src == 0 then return end
    local now = GetGameTimer()
    local last = lastRequest[src]
    -- Under the client's 250 ms retry cadence, so an early request is never
    -- silently dropped for arriving a frame too soon.
    if last and (now - last) < 200 then return end
    lastRequest[src] = now
    TriggerClientEvent('lastresort_loading:stats', src, buildStats(src))
end)

-- A push this early can land before the client script has registered its
-- handler, and an event nobody is listening for is simply gone. So it is sent
-- repeatedly, densely at first: whichever copy is the first to arrive after the
-- handler exists is the one that fills the chip.
AddEventHandler('playerJoining', function()
    local src = source
    if not src or src == 0 then return end
    CreateThread(function()
        for i = 1, 10 do
            if not GetPlayerName(src) then return end
            TriggerClientEvent('lastresort_loading:stats', src, buildStats(src))
            Wait(i <= 4 and 250 or 900)
        end
    end)
end)

local MAX_NEWS = 12
local MAX_TIPS = 30
local MAX_BODY_LINES = 12
local MAX_SHORT = 64
local MAX_TEXT = 400
local FILE_THROTTLE_MS = 5000

local pushed = { news = nil, tips = nil }
local fromHttp = { news = nil, tips = nil }
local fromFile = { news = nil, tips = nil }

local function cleanText(v, max)
    if type(v) ~= 'string' then return nil end
    local s = v:gsub('%s+', ' '):gsub('^ +', ''):gsub(' +$', '')
    if s == '' then return nil end
    if #s > max then s = s:sub(1, max) end
    return s
end

local function cleanLines(v)
    local src
    if type(v) == 'string' then
        src = {}
        for line in (v .. '\n'):gmatch('([^\n]*)\n') do src[#src + 1] = line end
    elseif type(v) == 'table' then
        src = v
    else
        return nil
    end
    local out = {}
    for _, line in ipairs(src) do
        local s = cleanText(line, MAX_TEXT)
        if s then
            out[#out + 1] = s
            if #out >= MAX_BODY_LINES then break end
        end
    end
    if #out == 0 then return nil end
    return out
end

local function cleanNews(list)
    if type(list) ~= 'table' then return nil end
    local out = {}
    for _, raw in ipairs(list) do
        local entry
        if type(raw) == 'string' then
            entry = { body = cleanLines(raw) }
        elseif type(raw) == 'table' then
            entry = {
                title = cleanText(raw.title, MAX_SHORT * 2),
                date = cleanText(raw.date, MAX_SHORT),
                tag = cleanText(raw.tag, MAX_SHORT),
                body = cleanLines(raw.body or raw.text or raw.lines)
            }
        end
        if entry and (entry.title or entry.body) then
            out[#out + 1] = entry
            if #out >= MAX_NEWS then break end
        end
    end
    if #out == 0 then return nil end
    return out
end

local function cleanTips(list)
    if type(list) ~= 'table' then return nil end
    local out = {}
    for _, raw in ipairs(list) do
        local s = cleanText(raw, MAX_TEXT)
        if s then
            out[#out + 1] = s
            if #out >= MAX_TIPS then break end
        end
    end
    if #out == 0 then return nil end
    return out
end

local function listFrom(decoded, ...)
    if type(decoded) ~= 'table' then return nil end
    if decoded[1] ~= nil then return decoded end
    for _, key in ipairs({ ... }) do
        if type(decoded[key]) == 'table' then return decoded[key] end
    end
    return nil
end

local rawCache = {}

local function readJsonFile(name)
    local raw = LoadResourceFile(RESOURCE, name)
    if not raw or raw == '' then
        rawCache[name] = nil
        return nil
    end
    local changed = rawCache[name] ~= raw
    rawCache[name] = raw
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        if changed then
            print(('[%s] %s is not valid JSON — ignoring it.'):format(RESOURCE, name))
        end
        return nil
    end
    return decoded
end

local lastFileRead = 0

local function refreshFiles(force)
    local now = GetGameTimer()
    if not force and (now - lastFileRead) < FILE_THROTTLE_MS then return end
    lastFileRead = now
    local newsDoc = readJsonFile('data/news.json')
    local tipsDoc = readJsonFile('data/tips.json')
    fromFile.news = newsDoc and cleanNews(listFrom(newsDoc, 'news', 'items', 'entries')) or nil
    fromFile.tips = tipsDoc and cleanTips(listFrom(tipsDoc, 'tips', 'items')) or nil
    if newsDoc and not fromFile.tips then
        fromFile.tips = cleanTips(listFrom(newsDoc, 'tips'))
    end
end

local function fetchUrl(url, apply)
    PerformHttpRequest(url, function(status, body)
        if status ~= 200 or type(body) ~= 'string' or body == '' then
            print(('[%s] %s answered %s — keeping the content that is already loaded.'):format(RESOURCE, url, tostring(status)))
            return
        end
        local ok, decoded = pcall(json.decode, body)
        if not ok or type(decoded) ~= 'table' then
            print(('[%s] %s did not answer with JSON — keeping the content that is already loaded.'):format(RESOURCE, url))
            return
        end
        apply(decoded)
    end, 'GET', '', { ['Accept'] = 'application/json' })
end

local function refreshHttp()
    local newsUrl = GetConvar('lrl:newsUrl', '')
    local tipsUrl = GetConvar('lrl:tipsUrl', '')
    if newsUrl ~= '' then
        fetchUrl(newsUrl, function(doc)
            fromHttp.news = cleanNews(listFrom(doc, 'news', 'items', 'entries'))
            if tipsUrl == '' then fromHttp.tips = cleanTips(listFrom(doc, 'tips')) end
        end)
    else
        fromHttp.news = nil
    end
    if tipsUrl ~= '' then
        fetchUrl(tipsUrl, function(doc)
            fromHttp.tips = cleanTips(listFrom(doc, 'tips', 'items'))
        end)
    elseif newsUrl == '' then
        fromHttp.tips = nil
    end
end

local function currentNews() return pushed.news or fromHttp.news or fromFile.news end
local function currentTips() return pushed.tips or fromHttp.tips or fromFile.tips end

exports('SetNews', function(list)
    pushed.news = cleanNews(list)
    return pushed.news ~= nil
end)

exports('SetTips', function(list)
    pushed.tips = cleanTips(list)
    return pushed.tips ~= nil
end)

AddEventHandler('lastresort_loading:setNews', function(list) pushed.news = cleanNews(list) end)
AddEventHandler('lastresort_loading:setTips', function(list) pushed.tips = cleanTips(list) end)

-- Everything the loading screen can be told at connect time is told at connect
-- time. The client script that pushes the live numbers only starts once the
-- resources are downloaded, which is most of the way through the join — until
-- then the handover is the only data the page has, so it carries the news and
-- the tips as well as the counts, and the first frame is already the real one.
--
-- It is a payload in the connect handshake, so it is kept small: the newest
-- entries, trimmed, not the whole feed. The client script replaces all of it
-- with the full lists as soon as it is up.
local HANDOVER_NEWS = 4
local HANDOVER_TIPS = 10
local HANDOVER_NEWS_LINES = 6

local function handoverList(list, max)
    if type(list) ~= 'table' or #list == 0 then return nil end
    local out = {}
    for i = 1, math.min(#list, max) do out[i] = list[i] end
    return out
end

local function handoverNews()
    local list = handoverList(currentNews(), HANDOVER_NEWS)
    if not list then return nil end
    local out = {}
    for i, entry in ipairs(list) do
        out[i] = {
            title = entry.title,
            date = entry.date,
            tag = entry.tag,
            body = handoverList(entry.body, HANDOVER_NEWS_LINES)
        }
    end
    return out
end

AddEventHandler('playerConnecting', function(playerName, _, deferrals)
    if type(deferrals) ~= 'table' or type(deferrals.handover) ~= 'function' then return end
    local mode = handoverMode()
    if mode == OFF then return end

    refreshFiles(false)
    local s = buildStats(nil)
    local payload = {
        name = playerName,
        players = s.players,
        maxPlayers = s.maxPlayers,
        serverName = s.serverName,
        news = handoverNews(),
        tips = handoverList(currentTips(), HANDOVER_TIPS)
    }

    if mode == ATTACH then
        -- No defer(), no done(): the queue's deferral is the one this rides on,
        -- and a resource that never defers can never hold the connection open.
        pcall(function() deferrals.handover(payload) end)
        return
    end

    local deferred = false
    pcall(function()
        deferrals.defer()
        deferred = true
        Wait(0)
        deferrals.handover(payload)
    end)
    if deferred then
        pcall(function() deferrals.done() end)
    end
end)

CreateThread(function()
    while true do
        refreshFiles(true)
        refreshHttp()
        local minutes = GetConvarInt('lrl:contentRefreshMinutes', 5)
        if minutes <= 0 then return end
        Wait(minutes * 60000)
    end
end)

local STORE_FILE = 'data/rules_accepted.json'
local ID_PREFERENCE = { 'license', 'fivem', 'discord', 'steam', 'xbl', 'live' }

local acceptances = {}
local storeDirty = false

local function saveStore()
    SaveResourceFile(RESOURCE, STORE_FILE, json.encode({ players = acceptances }), -1)
end

do
    local raw = LoadResourceFile(RESOURCE, STORE_FILE)
    if raw and raw ~= '' then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == 'table' and type(decoded.players) == 'table' then
            acceptances = decoded.players
        else
            print(('[%s] %s could not be read — the rules gate starts from an empty list.'):format(RESOURCE, STORE_FILE))
        end
    end
end

CreateThread(function()
    while true do
        Wait(5000)
        if storeDirty then
            storeDirty = false
            saveStore()
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == RESOURCE and storeDirty then
        storeDirty = false
        saveStore()
    end
end)

local function primaryIdentifier(src)
    local found = {}
    local total = GetNumPlayerIdentifiers(tostring(src)) or 0
    for i = 0, total - 1 do
        local id = GetPlayerIdentifier(tostring(src), i)
        if id then
            local prefix = id:match('^([^:]+):')
            if prefix and not found[prefix] then found[prefix] = id end
        end
    end
    for _, prefix in ipairs(ID_PREFERENCE) do
        if found[prefix] then return found[prefix] end
    end
    return nil
end

local function gateEnabled()
    local v = GetConvar('lrl:rulesGate', '0'):lower()
    return v == '1' or v == 'true' or v == 'yes' or v == 'on'
end

local function rulesVersion()
    local v = GetConvar('lrl:rulesVersion', '1')
    if v == '' then return '1' end
    return v
end

local function gateFor(src)
    if not gateEnabled() then return nil end
    local id = primaryIdentifier(src)
    if not id then return nil end
    local version = rulesVersion()
    local record = acceptances[id]
    local askAlways = GetConvar('lrl:rulesMode', 'version'):lower() == 'always'
    return {
        required = askAlways or type(record) ~= 'table' or record.version ~= version,
        version = version
    }
end

local declineCache = {}

local function declineReason(localeName)
    local code = nil
    if type(localeName) == 'string' and #localeName <= 12 and localeName:match('^%a[%a%-]*$') then
        code = localeName
    end
    for _, c in ipairs({ code, 'en' }) do
        if c then
            if declineCache[c] == nil then
                local raw = LoadResourceFile(RESOURCE, ('locales/%s.json'):format(c))
                local ok, decoded = pcall(json.decode, raw or '')
                declineCache[c] = (ok and type(decoded) == 'table' and type(decoded.gateDeclined) == 'string')
                    and decoded.gateDeclined or false
            end
            if declineCache[c] then return declineCache[c] end
        end
    end
    return 'You have to accept the server rules to play here.'
end

local lastContent, lastAccept = {}, {}

RegisterNetEvent('lastresort_loading:requestContent', function()
    local src = source
    if not src or src == 0 then return end
    local now = GetGameTimer()
    if lastContent[src] and (now - lastContent[src]) < 400 then return end
    lastContent[src] = now
    refreshFiles(false)
    TriggerClientEvent('lastresort_loading:content', src, {
        news = currentNews(),
        tips = currentTips(),
        gate = gateFor(src)
    })
end)

RegisterNetEvent('lastresort_loading:acceptRules', function()
    local src = source
    if not src or src == 0 then return end
    local now = GetGameTimer()
    if lastAccept[src] and (now - lastAccept[src]) < 1000 then return end
    lastAccept[src] = now
    if gateEnabled() then
        local id = primaryIdentifier(src)
        if id then
            acceptances[id] = { version = rulesVersion(), at = os.time(), name = GetPlayerName(src) }
            storeDirty = true
        end
    end
    TriggerClientEvent('lastresort_loading:rulesAck', src)
end)

RegisterNetEvent('lastresort_loading:declineRules', function(localeName)
    local src = source
    if not src or src == 0 then return end
    DropPlayer(src, declineReason(localeName))
end)

RegisterCommand('lrl_reload', function()
    refreshFiles(true)
    refreshHttp()
    local n, tp = currentNews(), currentTips()
    print(('[%s] content reloaded — %d news %s, %d tips. A URL feed answers a moment later.')
        :format(RESOURCE, n and #n or 0, (n and #n == 1) and 'entry' or 'entries', tp and #tp or 0))
end, true)

RegisterCommand('lrl_rules_reset', function(src, args)
    local target = args[1]
    if not target or target == '' then
        print(('[%s] usage: lrl_rules_reset <all | me | server id | identifier>'):format(RESOURCE))
        return
    end
    if target:lower() == 'all' then
        acceptances = {}
        storeDirty = true
        print(('[%s] every rules acceptance was cleared — the gate asks everyone again.'):format(RESOURCE))
        return
    end
    local id = target
    if target:lower() == 'me' then
        id = (src and src > 0) and primaryIdentifier(src) or nil
    elseif target:match('^%d+$') then
        id = primaryIdentifier(tonumber(target))
    end
    if not id or acceptances[id] == nil then
        print(('[%s] no stored acceptance for %s.'):format(RESOURCE, tostring(id or target)))
        return
    end
    acceptances[id] = nil
    storeDirty = true
    print(('[%s] cleared the rules acceptance of %s.'):format(RESOURCE, id))
end, true)

AddEventHandler('playerDropped', function()
    lastRequest[source] = nil
    lastContent[source] = nil
    lastAccept[source] = nil
end)
