local QBCore = exports['qb-core']:GetCoreObject()

local MySQL = exports['oxmysql']

-- Server-side safe object cache (MUST be before LoadSafesFromDatabase)
local safes = {}

-- Helper to count table entries
local function countTable(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

local function ScheduleAutoRelock(safeId, unlockTime)
    local seconds = tonumber(Config.AutoRelockSeconds) or 0
    if seconds <= 0 then return end
    CreateThread(function()
        Wait(seconds * 1000)
        local safe = safes[safeId]
        if not safe or safe.isLocked or safe.wasBreached then return end
        if safe.lastUnlockTime ~= unlockTime then return end
        safe.isLocked = true
        safe.unlockSource = nil
        safe.lastUnlockTime = nil
        MySQL:execute('UPDATE secure_safes SET is_locked = 1 WHERE id = ?', {safeId})
        TriggerClientEvent('yy-secure-safes:client:SafePlaced', -1, safeId, safe)
        TriggerClientEvent('yy-secure-safes:client:MarkLocked', -1, safeId)
    end)
end

local function UnlockSafe(safeId, sourceLabel)
    local safe = safes[safeId]
    if not safe then return false end
    safe.isLocked = false
    safe.wasBreached = false
    safe.unlockSource = sourceLabel or 'code'
    safe.lastUnlockTime = os.time()
    safe.breachAttempts = 0
    safe.lastBreachTime = nil
    MySQL:execute('UPDATE secure_safes SET is_locked = 0, breach_attempts = 0, last_breach_time = NULL WHERE id = ?', {safeId})
    TriggerClientEvent('yy-secure-safes:client:SafePlaced', -1, safeId, safe)
    TriggerClientEvent('yy-secure-safes:client:MarkUnlocked', -1, safeId)
    ScheduleAutoRelock(safeId, safe.lastUnlockTime)
    return true
end

local function TriggerAlarm(safeId)
    local safe = safes[safeId]
    if not safe then return end
    if not (Config.SafeAlarm and Config.SafeAlarm.Enabled) then return end
    if safe.alarmArmed ~= true then return end
    local duration = tonumber(Config.SafeAlarm.DurationSeconds) or 0
    if duration <= 0 then return end
    local now = os.time()
    if safe.alarmUntil and safe.alarmUntil > now then return end
    safe.alarmUntil = now + duration
    TriggerClientEvent('yy-secure-safes:client:PlayAlarm', -1, safeId, duration)
end

local function GetSafeCapacity(safe)
    local tierConfig = Config.SafeTiers[safe.tier] or {}
    local defaultSlots = (Config.StashDefaults and Config.StashDefaults.slots) or 10
    local defaultWeight = (Config.StashDefaults and Config.StashDefaults.weight) or 50000
    local slots = tierConfig.slots or defaultSlots
    local weight = tierConfig.weight or defaultWeight
    local bonusSlots = tonumber(safe.upgradeSlots) or 0
    local bonusWeight = tonumber(safe.upgradeWeight) or 0
    return slots + bonusSlots, weight + bonusWeight
end

local function GetStashUsage(stashId)
    if not exports.ox_inventory then return 0, 0 end
    local items = exports.ox_inventory:GetInventoryItems(stashId)
    if not items or next(items) == nil then
        return 0, 0, 0
    end
    local usedSlots = 0
    local maxSlot = 0
    local usedWeight = 0
    for _, item in pairs(items) do
        usedSlots = usedSlots + 1
        local slot = tonumber(item.slot) or 0
        if slot > maxSlot then
            maxSlot = slot
        end
        local count = item.count or item.amount or item.quantity or 1
        local weight = item.weight or 0
        usedWeight = usedWeight + (weight * count)
    end
    return usedSlots, usedWeight, maxSlot
end

local function CompactStashSlots(stashId, newSlots)
    if not (exports.ox_inventory and exports.ox_inventory.Inventory and exports.ox_inventory.SwapSlots) then
        return false
    end
    local inv = exports.ox_inventory:Inventory(stashId)
    if not inv or not inv.items then return false end

    local used = {}
    local highSlots = {}
    for slot, item in pairs(inv.items) do
        if item then
            if slot > newSlots then
                table.insert(highSlots, slot)
            else
                used[slot] = true
            end
        end
    end

    if #highSlots == 0 then
        return true
    end

    local freeSlots = {}
    for i = 1, newSlots do
        if not used[i] then
            table.insert(freeSlots, i)
        end
    end

    table.sort(highSlots)
    for _, slot in ipairs(highSlots) do
        local target = table.remove(freeSlots, 1)
        if not target then
            return false
        end
        exports.ox_inventory:SwapSlots(inv, inv, slot, target)
    end

    return true
end

local function EnsureUpgradeColumns(done)
    MySQL:execute(
        'ALTER TABLE secure_safes ' ..
        'ADD COLUMN IF NOT EXISTS upgrade_slots INT DEFAULT 0, ' ..
        'ADD COLUMN IF NOT EXISTS upgrade_weight INT DEFAULT 0, ' ..
        'ADD COLUMN IF NOT EXISTS upgrade_level INT DEFAULT 0, ' ..
        'ADD COLUMN IF NOT EXISTS seal_until INT DEFAULT 0, ' ..
        'ADD COLUMN IF NOT EXISTS anti_drill BOOLEAN DEFAULT 0, ' ..
        'ADD COLUMN IF NOT EXISTS alarm_armed BOOLEAN DEFAULT 0',
        {},
        function()
            if done then done() end
        end
    )
end

-- Helper functions
local function LoadSafesFromDatabase()
    MySQL:query('SELECT * FROM secure_safes', {}, function(result)
        if result then
            for _, safe in ipairs(result) do
                safes[safe.id] = {
                    owner = safe.owner,
                    tier = safe.tier,
                    passcode = safe.passcode,
                    position = json.decode(safe.position),
                    rotation = json.decode(safe.rotation),
                    breachAttempts = safe.breach_attempts,
                    lastBreachTime = safe.last_breach_time,
                    isLocked = safe.is_locked == 1,
                    upgradeSlots = tonumber(safe.upgrade_slots) or 0,
                    upgradeWeight = tonumber(safe.upgrade_weight) or 0,
                    upgradeLevel = tonumber(safe.upgrade_level) or 0,
                    sealUntil = tonumber(safe.seal_until) or 0,
                    antiDrill = (tonumber(safe.anti_drill) or 0) == 1,
                    alarmArmed = (tonumber(safe.alarm_armed) or 0) == 1,
                    wasBreached = false -- we do not persist this flag; default to false on load
                }
                -- Pre-register the stash for ox_inventory so it opens reliably
                if exports.ox_inventory then
                    local slots, weight = GetSafeCapacity(safes[safe.id])
                    local label = ('Safe %s'):format(safe.id)
                    pcall(function()
                        exports.ox_inventory:RegisterStash(
                            'safe_' .. safe.id,
                            label,
                            slots,
                            weight,
                            safe.owner,
                            nil,
                            vector3(safes[safe.id].position.x, safes[safe.id].position.y, safes[safe.id].position.z)
                        )
                    end)
                end
            end
        else
        end
    end)
end

-- Database initialization
local function InitializeDatabase()
    if Config.RunMigrationsOnStart then
        MySQL:execute('CREATE TABLE IF NOT EXISTS secure_safes (id VARCHAR(50) PRIMARY KEY, owner VARCHAR(50) NOT NULL, tier INT NOT NULL, passcode VARCHAR(6) NOT NULL, position JSON NOT NULL, rotation JSON NOT NULL, breach_attempts INT DEFAULT 0, last_breach_time TIMESTAMP NULL, is_locked BOOLEAN DEFAULT TRUE, upgrade_slots INT DEFAULT 0, upgrade_weight INT DEFAULT 0, upgrade_level INT DEFAULT 0, seal_until INT DEFAULT 0, anti_drill BOOLEAN DEFAULT 0, alarm_armed BOOLEAN DEFAULT 0, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP)', function()
            EnsureUpgradeColumns(LoadSafesFromDatabase)
        end)
    else
        EnsureUpgradeColumns(LoadSafesFromDatabase)
    end
end

-- Initialize when resource starts
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        InitializeDatabase()
    end
end)

-- Server endpoint to open inventory after passcode verification
RegisterNetEvent('yy-secure-safes:server:OpenInventory', function(safeId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    local stashId = 'safe_' .. safeId
    
    -- Initialize stash based on inventory system
    -- ox_inventory: register (idempotent) then open
    local slots, weight = GetSafeCapacity(safe)
    pcall(function()
        exports.ox_inventory:RegisterStash(stashId, 'Safe ' .. safeId, slots, weight, safe.owner, nil, vector3(safe.position.x, safe.position.y, safe.position.z))
    end)
    TriggerClientEvent('yy-secure-safes:client:OpenSafeInventory', src, safeId)
end)



-- Shop/purchase functionality removed. Safes should be acquired via your inventory (ox_inventory) or other methods.

-- Event handlers for safe operations

-- Event handler for placing a safe
RegisterNetEvent('yy-secure-safes:server:PlaceSafe', function(safeData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local safeId = 'safe_' .. os.time() .. '_' .. math.random(1000, 9999)
    local passcode = tostring(safeData.passcode or '')
    if not passcode:match('^%d%d%d%d$') then
        TriggerClientEvent('QBCore:Notify', src, 'Passcode must be exactly 4 digits.', 'error')
        return
    end
    
    -- Validate position and rotation
    local function validateVector3(vec)
        if not vec or not vec.x or not vec.y or not vec.z then return false end
        if type(vec.x) ~= "number" or type(vec.y) ~= "number" or type(vec.z) ~= "number" then return false end
        -- Check for reasonable coordinate ranges (-10000 to 10000 is a reasonable map range)
        if math.abs(vec.x) > 10000 or math.abs(vec.y) > 10000 or math.abs(vec.z) > 1000 then return false end
        return true
    end

    -- Validate safe placement data
    if not validateVector3(safeData.position) or not validateVector3(safeData.rotation) then
        TriggerClientEvent('QBCore:Notify', src, 'Invalid safe position or rotation!', 'error')
        return
    end

    -- Check distance from other safes (minimum 2.0 units)
    for _, existingSafe in pairs(safes) do
        local pos1 = vector3(safeData.position.x, safeData.position.y, safeData.position.z)
        local pos2 = vector3(existingSafe.position.x, existingSafe.position.y, existingSafe.position.z)
        local distance = #(pos1 - pos2)
        if distance < 2.0 then
            TriggerClientEvent('QBCore:Notify', src, 'Too close to another safe!', 'error')
            return
        end
    end

    -- Insert into database
    MySQL:insert('INSERT INTO secure_safes (id, owner, tier, passcode, position, rotation) VALUES (?, ?, ?, ?, ?, ?)',
        {
            safeId,
            Player.PlayerData.citizenid,
            safeData.tier,
            passcode,
            json.encode(safeData.position),
            json.encode(safeData.rotation)
        },
        function(id)
            if id then
                safes[safeId] = {
                    owner = Player.PlayerData.citizenid,
                    tier = safeData.tier,
                    passcode = passcode,
                    position = safeData.position,
                    rotation = safeData.rotation,
                    breachAttempts = 0,
                    isLocked = true,
                    upgradeSlots = 0,
                    upgradeWeight = 0,
                    upgradeLevel = 0,
                    sealUntil = 0,
                    antiDrill = false,
                    alarmArmed = false,
                    wasBreached = false
                }
                if exports.ox_inventory then
                    local slots, weight = GetSafeCapacity(safes[safeId])
                    local label = ('Safe %s'):format(safeId)
                    pcall(function()
                        exports.ox_inventory:RegisterStash(
                            'safe_' .. safeId,
                            label,
                            slots,
                            weight,
                            Player.PlayerData.citizenid,
                            nil,
                            vector3(safeData.position.x, safeData.position.y, safeData.position.z)
                        )
                    end)
                end
                
                -- Remove the safe item from player's inventory
                Player.Functions.RemoveItem('safe_tier_' .. safeData.tier, 1)
                
                -- Sync the new safe to all clients
                TriggerClientEvent('yy-secure-safes:client:SafePlaced', -1, safeId, safes[safeId])
                TriggerClientEvent('QBCore:Notify', src, 'Safe placed successfully!', 'success')
            else
                TriggerClientEvent('QBCore:Notify', src, 'Failed to place safe!', 'error')
            end
        end
    )
end)

-- Callback to verify safe access
QBCore.Functions.CreateCallback('yy-secure-safes:server:VerifyAccess', function(source, cb, safeId, inputCode)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local safe = safes[safeId]
    
    if not safe then
        cb(false)
        return
    end
    if safe.isLocked == nil then safe.isLocked = true end

    local input = tostring(inputCode or '')
    local stored = tostring(safe.passcode or '')

    -- Unlocked: allow anyone
    if safe.isLocked == false then cb(true) return end

    -- Enforce 4-digit passcode (owner must also enter correct code)
    if not input:match('^%d%d%d%d$') then
        cb(false)
        return
    end

    -- Correct code unlocks the safe for everyone
    if stored ~= '' and stored == input then
        UnlockSafe(safeId, 'code')
        cb(true)
    else
        cb(false)
    end
end)

-- Event handler for breach attempts
-- Anti-spam tracking
local playerBreachAttempts = {}

-- Cleanup old attempt records every 5 minutes
CreateThread(function()
    while true do
        Wait(300000) -- 5 minutes
        local now = os.time()
        for playerId, attempts in pairs(playerBreachAttempts) do
            -- Remove attempts older than 5 minutes
            for i = #attempts, 1, -1 do
                if now - attempts[i] > 300 then
                    table.remove(attempts, i)
                end
            end
            -- Remove player if no recent attempts
            if #attempts == 0 then
                playerBreachAttempts[playerId] = nil
            end
        end
    end
end)

RegisterNetEvent('yy-secure-safes:server:AttemptBreach', function(safeId, toolType)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local safe = safes[safeId]
    
    if not safe then return end
    if safe.isLocked == false then
        TriggerClientEvent('QBCore:Notify', src, 'Safe is already unlocked.', 'error')
        return
    end
    
    -- Anti-spam check
    if not playerBreachAttempts[src] then
        playerBreachAttempts[src] = {}
    end
    
    -- Check for too many recent attempts (max 3 attempts per minute)
    local recentAttempts = 0
    local now = os.time()
    for _, attemptTime in ipairs(playerBreachAttempts[src]) do
        if now - attemptTime < 60 then
            recentAttempts = recentAttempts + 1
        end
    end
    
    if recentAttempts >= 3 then
        TriggerClientEvent('QBCore:Notify', src, 'Too many breach attempts. Wait a minute.', 'error')
        return
    end
    
    -- Record this attempt
    table.insert(playerBreachAttempts[src], now)

    local toolName = tostring(toolType or ''):lower()
    if toolName:find('hack') or toolName:find('drill') then
        TriggerAlarm(safeId)
    end

    local tierConfig = Config.SafeTiers[safe.tier]
    
    -- Enhanced cooldown check with remaining time
    if safe.lastBreachTime then
        local timeRemaining = tierConfig.cooldownTime - (os.time() - safe.lastBreachTime)
        if timeRemaining > 0 then
            local minutes = math.floor(timeRemaining / 60)
            local seconds = timeRemaining % 60
            TriggerClientEvent('QBCore:Notify', src, string.format('Cooldown: %d minutes %d seconds', minutes, seconds), 'error')
            return
        end
    end

    -- Check max breach attempts with remaining attempts notice
    if safe.breachAttempts >= tierConfig.maxBreachAttempts then
        TriggerClientEvent('QBCore:Notify', src, 'Safe lockdown active! Contact owner to reset.', 'error')
        return
    end

    -- Enhanced tool validation
    local toolConf = Config.BreachTools[toolType]
    if not toolConf then
        TriggerClientEvent('QBCore:Notify', src, 'Invalid breach tool.', 'error')
        return
    end

    -- Check if player has required item and count
    local playerItem = Player.Functions.GetItemByName and Player.Functions.GetItemByName(toolConf.item) or nil
    if not playerItem or playerItem.amount < 1 then
        TriggerClientEvent('QBCore:Notify', src, 'Required: ' .. toolConf.item, 'error')
        return
    end

    -- Notify about breach attempt and remaining attempts
    local remainingAttempts = tierConfig.maxBreachAttempts - safe.breachAttempts - 1
    TriggerClientEvent('QBCore:Notify', src, string.format('Breach attempt started. %d attempts remaining.', remainingAttempts), 'inform')

    -- Update breach attempt count and time
    safe.breachAttempts = safe.breachAttempts + 1
    safe.lastBreachTime = os.time()
    
    -- Update database with new attempt data
    MySQL:execute('UPDATE secure_safes SET breach_attempts = ?, last_breach_time = CURRENT_TIMESTAMP WHERE id = ?',
        {safe.breachAttempts, safeId})

    -- Pass configured difficulty down to client
    local difficulty = tierConfig.breachDifficulty or {}

    -- Trigger client-side breach minigame with tier difficulty
    TriggerClientEvent('yy-secure-safes:client:StartBreach', src, safeId, safe.tier, toolType, difficulty)
end)


-- Client requests current safes (on player load)
RegisterNetEvent('yy-secure-safes:server:RequestSafes', function()
    local src = source
    -- Send a lightweight copy of safes to client
    local sendable = {}
    for id, s in pairs(safes) do
        sendable[id] = {
            owner = s.owner,
            tier = s.tier,
            position = s.position,
            rotation = s.rotation,
            breachAttempts = s.breachAttempts,
            lastBreachTime = s.lastBreachTime,
            isLocked = s.isLocked,
            wasBreached = s.wasBreached,
            upgradeSlots = s.upgradeSlots or 0,
            upgradeWeight = s.upgradeWeight or 0,
            upgradeLevel = s.upgradeLevel or 0,
            sealUntil = s.sealUntil or 0,
            antiDrill = (s.antiDrill == true) or (tonumber(s.antiDrill) or 0) == 1,
            alarmArmed = (s.alarmArmed == true) or (tonumber(s.alarmArmed) or 0) == 1
        }
    end
    TriggerClientEvent('yy-secure-safes:client:SyncSafes', src, sendable)
end)


-- Handle successful breach from client-side (minigame success)
RegisterNetEvent('yy-secure-safes:server:BreachSuccess', function(safeId, toolType)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local safe = safes[safeId]
    if not safe then return end

    -- Mark safe as unlocked and breached
    safe.isLocked = false
    safe.wasBreached = true
    safe.unlockSource = 'breach'
    safe.lastUnlockTime = os.time()
    safe.breachAttempts = 0
    safe.lastBreachTime = nil

    -- Remove used item if configured
    local toolConf = Config.BreachTools[toolType]
    if toolConf and toolConf.removeOnUse then
        if Player.Functions.RemoveItem then
            Player.Functions.RemoveItem(toolConf.item, 1)
        end
    end

    -- Update DB
    MySQL:execute('UPDATE secure_safes SET is_locked = 0, breach_attempts = 0, last_breach_time = NULL WHERE id = ?', {safeId})

    -- Notify the player (do not auto-open inventory)
    TriggerClientEvent('QBCore:Notify', src, 'Breach successful! Safe unlocked.', 'success')
    -- Sync to all clients so the object state can update if needed
    TriggerClientEvent('yy-secure-safes:client:SafePlaced', -1, safeId, safe)
    TriggerClientEvent('yy-secure-safes:client:MarkUnlocked', -1, safeId)
end)

-- Relock safe (anyone if unlocked by code; owner + lockkit only if breached)
RegisterNetEvent('yy-secure-safes:server:RelockSafe', function(safeId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    if safe.isLocked then
        TriggerClientEvent('QBCore:Notify', src, 'Safe is already locked.', 'error')
        return
    end

    local isOwner = safe.owner == Player.PlayerData.citizenid
    local needsItem = safe.wasBreached == true

    if needsItem then
        if not isOwner then
            TriggerClientEvent('QBCore:Notify', src, 'Only the owner can relock a breached safe.', 'error')
            return
        end

        local item = Config.RelockItem or 'safe_lockkit'
        local hasItem = false
        if exports.ox_inventory then
            local count = exports.ox_inventory:Search(src, 'count', item)
            hasItem = (count or 0) > 0
        end

        if not hasItem then
            TriggerClientEvent('QBCore:Notify', src, 'You need: ' .. item, 'error')
            return
        end

        if Config.RelockConsumesItem and exports.ox_inventory then
            exports.ox_inventory:RemoveItem(src, item, 1)
        end
    end

    safe.isLocked = true
    safe.wasBreached = false
    safe.unlockSource = nil
    safe.lastUnlockTime = nil
    MySQL:execute('UPDATE secure_safes SET is_locked = 1 WHERE id = ?', {safeId})
    TriggerClientEvent('QBCore:Notify', src, 'Safe locked.', 'success')
    TriggerClientEvent('yy-secure-safes:client:SafePlaced', -1, safeId, safe)
    TriggerClientEvent('yy-secure-safes:client:MarkLocked', -1, safeId)
end)

-- Unlock safe using a crafted key
RegisterNetEvent('yy-secure-safes:server:UseSafeKey', function(safeId)
    local src = source
    if not (Config.SafeKeys and Config.SafeKeys.Enabled) then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    if safe.isLocked == false then
        TriggerClientEvent('QBCore:Notify', src, 'Safe is already unlocked.', 'error')
        return
    end

    local toolName = tostring(toolType or ''):lower()
    if toolName:find('hack') and safe.sealUntil and safe.sealUntil > os.time() then
        local remaining = safe.sealUntil - os.time()
        local minutes = math.floor(remaining / 60)
        local seconds = remaining % 60
        TriggerClientEvent('QBCore:Notify', src, string.format('Vault seal active: %d:%02d remaining', minutes, seconds), 'error')
        return
    end

    if toolName:find('drill') and safe.antiDrill then
        TriggerClientEvent('QBCore:Notify', src, 'Reinforced armor blocks drilling on this safe.', 'error')
        return
    end

    local keyItem = Config.SafeKeys.KeyItem or 'safe_key'
    local count = 0
    if exports.ox_inventory then
        local ok, result = pcall(function()
            return exports.ox_inventory:Search(src, 'count', keyItem, { safeId = safeId })
        end)
        if ok then count = result or 0 end
    end

    if count < 1 then
        TriggerClientEvent('QBCore:Notify', src, 'You do not have the key for this safe.', 'error')
        return
    end

    UnlockSafe(safeId, 'key')
    TriggerClientEvent('QBCore:Notify', src, 'Safe unlocked with key.', 'success')
end)

-- Craft a safe-specific key (owner only)
RegisterNetEvent('yy-secure-safes:server:CraftSafeKey', function(safeId)
    local src = source
    if not (Config.SafeKeys and Config.SafeKeys.Enabled) then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    if safe.owner ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, 'You do not own this safe.', 'error')
        return
    end

    local craftItem = Config.SafeKeys.CraftItem or 'safe_key_blank'
    local keyItem = Config.SafeKeys.KeyItem or 'safe_key'
    local count = 0
    if exports.ox_inventory then
        local ok, result = pcall(function()
            return exports.ox_inventory:Search(src, 'count', craftItem)
        end)
        if ok then count = result or 0 end
    end

    if count < 1 then
        TriggerClientEvent('QBCore:Notify', src, 'You need: ' .. craftItem, 'error')
        return
    end

    if exports.ox_inventory then
        exports.ox_inventory:RemoveItem(src, craftItem, 1)
        exports.ox_inventory:AddItem(src, keyItem, 1, { safeId = safeId })
    end

    TriggerClientEvent('QBCore:Notify', src, 'Safe key crafted.', 'success')
end)

-- Upgrade safe storage (owner only)
RegisterNetEvent('yy-secure-safes:server:UpgradeSafeStorage', function(safeId)
    local src = source
    if not (Config.StorageUpgrades and Config.StorageUpgrades.Enabled) then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    if safe.owner ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, 'You do not own this safe.', 'error')
        return
    end

    local upgradeConf = Config.StorageUpgrades[safe.tier]
    if not upgradeConf then
        TriggerClientEvent('QBCore:Notify', src, 'No upgrades available for this tier.', 'error')
        return
    end

    local maxUpgrades = tonumber(upgradeConf.maxUpgrades) or 1
    safe.upgradeLevel = tonumber(safe.upgradeLevel) or 0
    if safe.upgradeLevel >= maxUpgrades then
        TriggerClientEvent('QBCore:Notify', src, 'Safe is already fully upgraded.', 'error')
        return
    end

    local item = upgradeConf.item or ('safe_upgrade_tier_' .. tostring(safe.tier))
    local count = 0
    if exports.ox_inventory then
        local ok, result = pcall(function()
            return exports.ox_inventory:Search(src, 'count', item)
        end)
        if ok then count = result or 0 end
    end

    if count < 1 then
        TriggerClientEvent('QBCore:Notify', src, 'You need: ' .. item, 'error')
        return
    end

    local addSlots = tonumber(upgradeConf.addSlots) or 0
    local addWeight = tonumber(upgradeConf.addWeight) or 0
    safe.upgradeSlots = (tonumber(safe.upgradeSlots) or 0) + addSlots
    safe.upgradeWeight = (tonumber(safe.upgradeWeight) or 0) + addWeight
    safe.upgradeLevel = safe.upgradeLevel + 1

    if exports.ox_inventory then
        exports.ox_inventory:RemoveItem(src, item, 1)
    end

    MySQL:execute('UPDATE secure_safes SET upgrade_slots = ?, upgrade_weight = ?, upgrade_level = ? WHERE id = ?', {
        safe.upgradeSlots,
        safe.upgradeWeight,
        safe.upgradeLevel,
        safeId
    })

    if exports.ox_inventory then
        local slots, weight = GetSafeCapacity(safe)
        pcall(function()
            exports.ox_inventory:RegisterStash(
                'safe_' .. safeId,
                'Safe ' .. safeId,
                slots,
                weight,
                safe.owner,
                nil,
                vector3(safe.position.x, safe.position.y, safe.position.z)
            )
        end)
    end

    TriggerClientEvent('yy-secure-safes:client:SafePlaced', -1, safeId, safe)
    TriggerClientEvent('QBCore:Notify', src, 'Safe storage upgraded.', 'success')
end)

-- Remove last storage upgrade (owner only, requires free space)
RegisterNetEvent('yy-secure-safes:server:RemoveSafeUpgrade', function(safeId)
    local src = source
    if not (Config.StorageUpgrades and Config.StorageUpgrades.Enabled) then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    if safe.owner ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, 'You do not own this safe.', 'error')
        return
    end

    local upgradeConf = Config.StorageUpgrades[safe.tier]
    if not upgradeConf then
        TriggerClientEvent('QBCore:Notify', src, 'No upgrades available for this tier.', 'error')
        return
    end

    safe.upgradeLevel = tonumber(safe.upgradeLevel) or 0
    if safe.upgradeLevel < 1 then
        TriggerClientEvent('QBCore:Notify', src, 'This safe has no upgrades to remove.', 'error')
        return
    end

    local addSlots = tonumber(upgradeConf.addSlots) or 0
    local addWeight = tonumber(upgradeConf.addWeight) or 0
    local currentSlots, currentWeight = GetSafeCapacity(safe)
    local newSlots = math.max(0, currentSlots - addSlots)
    local newWeight = math.max(0, currentWeight - addWeight)

    local stashId = 'safe_' .. safeId
    local usedSlots, usedWeight, maxSlotUsed = GetStashUsage(stashId)
    if usedSlots > newSlots or usedWeight > newWeight then
        TriggerClientEvent('QBCore:Notify', src, 'Not enough free space to remove upgrade.', 'error')
        return
    end
    if maxSlotUsed > newSlots then
        local ok = CompactStashSlots(stashId, newSlots)
        if not ok then
            TriggerClientEvent('QBCore:Notify', src, 'Repack items before removing upgrade.', 'error')
            return
        end
    end

    safe.upgradeSlots = math.max(0, (tonumber(safe.upgradeSlots) or 0) - addSlots)
    safe.upgradeWeight = math.max(0, (tonumber(safe.upgradeWeight) or 0) - addWeight)
    safe.upgradeLevel = safe.upgradeLevel - 1

    local item = upgradeConf.item or ('safe_upgrade_tier_' .. tostring(safe.tier))
    if exports.ox_inventory then
        exports.ox_inventory:AddItem(src, item, 1)
    end

    MySQL:execute('UPDATE secure_safes SET upgrade_slots = ?, upgrade_weight = ?, upgrade_level = ? WHERE id = ?', {
        safe.upgradeSlots,
        safe.upgradeWeight,
        safe.upgradeLevel,
        safeId
    })

    if exports.ox_inventory then
        pcall(function()
            exports.ox_inventory:RegisterStash(
                stashId,
                'Safe ' .. safeId,
                newSlots,
                newWeight,
                safe.owner,
                nil,
                vector3(safe.position.x, safe.position.y, safe.position.z)
            )
        end)
    end

    TriggerClientEvent('yy-secure-safes:client:SafePlaced', -1, safeId, safe)
    TriggerClientEvent('QBCore:Notify', src, 'Upgrade removed.', 'success')
end)

-- Apply a vault seal to block breach attempts for a duration
RegisterNetEvent('yy-secure-safes:server:ApplyVaultSeal', function(safeId)
    local src = source
    if not (Config.VaultSeal and Config.VaultSeal.Enabled) then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    if safe.owner ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, 'You do not own this safe.', 'error')
        return
    end

    local now = os.time()
    if safe.sealUntil and safe.sealUntil > now then
        TriggerClientEvent('QBCore:Notify', src, 'Vault seal is already active.', 'error')
        return
    end

    local item = Config.VaultSeal.Item or 'safe_vault_seal'
    local count = 0
    if exports.ox_inventory then
        local ok, result = pcall(function()
            return exports.ox_inventory:Search(src, 'count', item)
        end)
        if ok then count = result or 0 end
    end

    if count < 1 then
        TriggerClientEvent('QBCore:Notify', src, 'You need: ' .. item, 'error')
        return
    end

    if Config.VaultSeal.ConsumeItem and exports.ox_inventory then
        exports.ox_inventory:RemoveItem(src, item, 1)
    end

    local duration = tonumber(Config.VaultSeal.DurationSeconds) or 0
    safe.sealUntil = now + duration
    MySQL:execute('UPDATE secure_safes SET seal_until = ? WHERE id = ?', { safe.sealUntil, safeId })
    TriggerClientEvent('yy-secure-safes:client:SafePlaced', -1, safeId, safe)
    TriggerClientEvent('QBCore:Notify', src, 'Vault seal applied.', 'success')
end)

-- Install anti-drill plate to block drilling attempts
RegisterNetEvent('yy-secure-safes:server:InstallAntiDrill', function(safeId)
    local src = source
    if not (Config.AntiDrill and Config.AntiDrill.Enabled) then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    if safe.owner ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, 'You do not own this safe.', 'error')
        return
    end

    if safe.antiDrill == true then
        TriggerClientEvent('QBCore:Notify', src, 'Anti-drill is already installed.', 'error')
        return
    end

    local item = Config.AntiDrill.Item or 'safe_anti_drill'
    local count = 0
    if exports.ox_inventory then
        local ok, result = pcall(function()
            return exports.ox_inventory:Search(src, 'count', item)
        end)
        if ok then count = result or 0 end
    end

    if count < 1 then
        TriggerClientEvent('QBCore:Notify', src, 'You need: ' .. item, 'error')
        return
    end

    if Config.AntiDrill.ConsumeItem and exports.ox_inventory then
        exports.ox_inventory:RemoveItem(src, item, 1)
    end

    safe.antiDrill = true
    MySQL:execute('UPDATE secure_safes SET anti_drill = 1 WHERE id = ?', { safeId })
    TriggerClientEvent('yy-secure-safes:client:SafePlaced', -1, safeId, safe)
    TriggerClientEvent('QBCore:Notify', src, 'Anti-drill plate installed.', 'success')
end)

-- Install safe alarm module (owner only)
RegisterNetEvent('yy-secure-safes:server:InstallSafeAlarm', function(safeId)
    local src = source
    if not (Config.SafeAlarm and Config.SafeAlarm.Enabled) then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    if safe.owner ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, 'You do not own this safe.', 'error')
        return
    end

    if safe.alarmArmed == true then
        TriggerClientEvent('QBCore:Notify', src, 'Alarm module already installed.', 'error')
        return
    end

    local item = Config.SafeAlarm.Item or 'safe_alarm_module'
    local count = 0
    if exports.ox_inventory then
        local ok, result = pcall(function()
            return exports.ox_inventory:Search(src, 'count', item)
        end)
        if ok then count = result or 0 end
    end

    if count < 1 then
        TriggerClientEvent('QBCore:Notify', src, 'You need: ' .. item, 'error')
        return
    end

    if Config.SafeAlarm.ConsumeItem and exports.ox_inventory then
        exports.ox_inventory:RemoveItem(src, item, 1)
    end

    safe.alarmArmed = true
    MySQL:execute('UPDATE secure_safes SET alarm_armed = 1 WHERE id = ?', { safeId })
    TriggerClientEvent('yy-secure-safes:client:SafePlaced', -1, safeId, safe)
    TriggerClientEvent('QBCore:Notify', src, 'Alarm module installed.', 'success')
end)

-- Remove safe alarm module (owner only)
RegisterNetEvent('yy-secure-safes:server:RemoveSafeAlarm', function(safeId)
    local src = source
    if not (Config.SafeAlarm and Config.SafeAlarm.Enabled) then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    if safe.owner ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, 'You do not own this safe.', 'error')
        return
    end

    if safe.alarmArmed ~= true then
        TriggerClientEvent('QBCore:Notify', src, 'No alarm module installed.', 'error')
        return
    end

    safe.alarmArmed = false
    safe.alarmUntil = nil
    MySQL:execute('UPDATE secure_safes SET alarm_armed = 0 WHERE id = ?', { safeId })

    if Config.SafeAlarm.ReturnItemOnRemove and exports.ox_inventory then
        local item = Config.SafeAlarm.Item or 'safe_alarm_module'
        exports.ox_inventory:AddItem(src, item, 1)
    end

    TriggerClientEvent('yy-secure-safes:client:SafePlaced', -1, safeId, safe)
    TriggerClientEvent('QBCore:Notify', src, 'Alarm module removed.', 'success')
end)


-- Change passcode (owner only)
RegisterNetEvent('yy-secure-safes:server:ChangePasscode', function(safeId, newCode)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    if safe.owner ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, 'You do not own this safe.', 'error')
        return
    end

    -- Validate new code (exactly 4 digits)
    if not tostring(newCode):match('^%d%d%d%d$') then
        TriggerClientEvent('QBCore:Notify', src, 'Passcode must be exactly 4 digits.', 'error')
        return
    end

    safe.passcode = tostring(newCode)
    MySQL:execute('UPDATE secure_safes SET passcode = ? WHERE id = ?', {safe.passcode, safeId})
    TriggerClientEvent('QBCore:Notify', src, 'Passcode changed successfully.', 'success')
end)


-- Callback to check if safe is empty
QBCore.Functions.CreateCallback('yy-secure-safes:server:CheckSafeEmpty', function(source, cb, safeId)
    local stashId = 'safe_' .. safeId
    local stashItems = nil
    
    if exports['ox_inventory'] then
        stashItems = exports['ox_inventory']:GetInventoryItems(stashId)
    end
    
    -- Consider empty if no items or nil (not yet created)
    cb(not stashItems or #stashItems == 0)
end)

-- Return safe as item and delete from DB
RegisterNetEvent('yy-secure-safes:server:ReturnSafe', function(safeId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then
        TriggerClientEvent('QBCore:Notify', src, 'Safe not found.', 'error')
        return
    end

    -- Verify owner
    if safe.owner ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, 'You do not own this safe.', 'error')
        return
    end

    -- Check safe is empty
    local stashId = 'safe_' .. safeId
    local stashItems = nil
    if exports['ox_inventory'] then
        stashItems = exports['ox_inventory']:GetInventoryItems(stashId)
    end

    if stashItems and #stashItems > 0 then
        TriggerClientEvent('QBCore:Notify', src, 'Empty the safe before moving it!', 'error')
        return
    end
    if (tonumber(safe.upgradeLevel) or 0) > 0 then
        TriggerClientEvent('QBCore:Notify', src, 'Remove all upgrades before moving the safe!', 'error')
        return
    end
    if safe.alarmArmed == true then
        TriggerClientEvent('QBCore:Notify', src, 'Remove the alarm module before moving the safe!', 'error')
        return
    end

    -- Give safe item back to player
    local tierStr = 'safe_tier_' .. tostring(safe.tier)
    if exports['ox_inventory'] then
        exports['ox_inventory']:AddItem(src, tierStr, 1)
    end

    -- Remove stash from inventory system
    if exports['ox_inventory'] then
        exports['ox_inventory']:RemoveInventory(stashId)
    end

    -- Delete from DB
    MySQL:execute('DELETE FROM secure_safes WHERE id = ?', { safeId }, function()
        safes[safeId] = nil

        -- Delete client-side object
        TriggerClientEvent('yy-secure-safes:client:DeleteSafeObject', -1, safeId)

        TriggerClientEvent('QBCore:Notify', src, 'Safe returned to inventory.', 'success')
    end)
end)

-- Move safe (owner only) - updates position/rotation in DB and syncs to clients
RegisterNetEvent('yy-secure-safes:server:MoveSafe', function(safeId, newPosition, newRotation)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    if safe.owner ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, 'You do not own this safe.', 'error')
        return
    end
    if (tonumber(safe.upgradeLevel) or 0) > 0 then
        TriggerClientEvent('QBCore:Notify', src, 'Remove all upgrades before moving the safe!', 'error')
        return
    end
    if safe.alarmArmed == true then
        TriggerClientEvent('QBCore:Notify', src, 'Remove the alarm module before moving the safe!', 'error')
        return
    end

    -- Double check safe is empty before moving
    local stashId = 'safe_' .. safeId
    local stashItems = nil
    if exports['ox_inventory'] then
        stashItems = exports['ox_inventory']:GetInventoryItems(stashId)
    end

    if stashItems and #stashItems > 0 then
        TriggerClientEvent('QBCore:Notify', src, 'Empty the safe before moving it!', 'error')
        return
    end

    safe.position = newPosition
    safe.rotation = newRotation
    MySQL:execute('UPDATE secure_safes SET position = ?, rotation = ? WHERE id = ?', {json.encode(newPosition), json.encode(newRotation), safeId})

    -- Sync change to all clients
    TriggerClientEvent('yy-secure-safes:client:SafePlaced', -1, safeId, safe)
    TriggerClientEvent('QBCore:Notify', src, 'Safe moved successfully.', 'success')
end)


-- Owner can reset breach attempts (admin/owner utility)
RegisterNetEvent('yy-secure-safes:server:ResetBreach', function(safeId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local safe = safes[safeId]
    if not safe then return end

    if safe.owner ~= Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, 'You do not own this safe.', 'error')
        return
    end

    safe.breachAttempts = 0
    safe.lastBreachTime = nil
    MySQL:execute('UPDATE secure_safes SET breach_attempts = 0, last_breach_time = NULL WHERE id = ?', {safeId})
    TriggerClientEvent('QBCore:Notify', src, 'Safe breach attempts reset.', 'success')
end)

-- Server export for ox_inventory (robust: handles multiple call signatures)
-- Server-side export intentionally removed. ox_inventory will call the client export
-- for `yy-secure-safes.useSafe` so placement happens on the client.

-- Restore server export handler for ox_inventory
function useSafe(src, item)
    local tier = 1
    if item and item.name then
        tier = tonumber(item.name:match('safe_tier_(%d+)')) or 1
    end
    TriggerClientEvent('yy-secure-safes:client:UseItem', src, tier)
    return true
end
