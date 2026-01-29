local QBCore = exports['qb-core']:GetCoreObject()

-- Local state
local safes = {}
local pendingPlace = nil
local placingTier = nil
local pendingLockStates = {}
local sealRefreshTimers = {}
local activeAlarms = {}
local alarmLoops = {}

-- Helper to count table entries (client-side)
local function countTable(t)
    local count = 0
    if not t then return 0 end
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- Placement helpers
local function RotationToDirection(rot)
    local rotZ = math.rad(rot.z)
    local rotX = math.rad(rot.x)
    local cosX = math.cos(rotX)
    return vector3(-math.sin(rotZ) * cosX, math.cos(rotZ) * cosX, math.sin(rotX))
end

local function RaycastFromCamera(distance, ignoreEntity)
    local camCoord = GetGameplayCamCoord()
    local camRot = GetGameplayCamRot(2)
    local direction = RotationToDirection(camRot)
    local dest = camCoord + (direction * distance)
    local ray = StartShapeTestRay(camCoord.x, camCoord.y, camCoord.z, dest.x, dest.y, dest.z, 31, ignoreEntity or 0, 0)
    local _, hit, endCoords, surfaceNormal, entityHit = GetShapeTestResult(ray)
    return hit == 1, endCoords, surfaceNormal, entityHit, camRot
end

local function PlaySafeSound(safeId, soundName)
    local radius = tonumber(Config.SoundRadius) or 0
    if radius <= 0 then return end
    local safe = safes[safeId]
    if not safe then return end
    local coords = nil
    if safe.object and DoesEntityExist(safe.object) then
        coords = GetEntityCoords(safe.object)
    elseif safe.data and safe.data.position then
        coords = vector3(safe.data.position.x, safe.data.position.y, safe.data.position.z)
    end
    if not coords then return end
    local playerCoords = GetEntityCoords(PlayerPedId())
    if #(playerCoords - coords) <= radius then
        SendNUIMessage({ action = 'playSound', sound = soundName, volume = Config.SoundVolume })
    end
end

local function LoadAnimDict(dict)
    if not dict or dict == '' then return false end
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local timeout = GetGameTimer() + 5000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < timeout do
        Wait(10)
    end
    return HasAnimDictLoaded(dict)
end

local function StartHackAnim()
    local conf = Config.HackingAnim or {}
    if not conf.dict or conf.dict == '' or not conf.clip or conf.clip == '' then return end
    if not LoadAnimDict(conf.dict) then return end
    TaskPlayAnim(PlayerPedId(), conf.dict, conf.clip, 8.0, -8.0, -1, conf.flag or 1, 0, false, false, false)
end

local function StopHackAnim()
    local conf = Config.HackingAnim or {}
    if not conf.dict or conf.dict == '' or not conf.clip or conf.clip == '' then return end
    StopAnimTask(PlayerPedId(), conf.dict, conf.clip, 1.0)
end


-- Ensure ox_lib is referenced as `lib` if it's available via exports (some setups don't expose global `lib`)
if not lib and exports and exports['ox_lib'] then
    local ok, maybeLib = pcall(function() return exports['ox_lib'] end)
    if ok and type(maybeLib) == 'table' then
        lib = maybeLib
    end
end

-- Load helper module (keeps main file smaller)
local helpers = {}
local ok, mod = pcall(function()
    if require then
        return require('client/helpers')
    end
    return nil
end)
if ok and mod then
    helpers = mod
end

-- Ensure LoadSafeModel exists even if helpers failed to load
if not helpers or type(helpers.LoadSafeModel) ~= 'function' then
    function helpers.LoadSafeModel(model)
        if not model then return end
        local hash = (type(model) == 'string') and GetHashKey(model) or model
        if not IsModelInCdimage(hash) then
            return
        end
        if HasModelLoaded(hash) then return end
        RequestModel(hash)
        local start = GetGameTimer()
        while not HasModelLoaded(hash) and (GetGameTimer() - start) < 5000 do
            Wait(10)
        end
        if not HasModelLoaded(hash) then
        end
    end
end

function useSafe(itemData, slot)
    if placingSafe then return end
    local tier
    if slot and type(slot.name) == 'string' then
        tier = tonumber(string.match(slot.name, 'safe_tier_(%d+)'))
    elseif itemData and type(itemData.name) == 'string' then
        tier = tonumber(string.match(itemData.name, 'safe_tier_(%d+)'))
    end
    if tier then
        TriggerEvent('yy-secure-safes:client:StartPlacementFromExport', tier)
    else
        QBCore.Functions.Notify('Unable to determine safe tier from item', 'error')
    end
end

-- Target System Integration
local function AddTargetToSafe(safeObj, safeId, safeData)
    local Player = QBCore.Functions.GetPlayerData()

    -- Remove existing targets before re-adding (to refresh labels/states)
    if Config.TargetSystem == 'ox_target' and exports and exports.ox_target then
        pcall(function()
            if exports.ox_target.removeLocalEntity then
                exports.ox_target:removeLocalEntity(safeObj)
            end
            if exports.ox_target.removeEntity then
                exports.ox_target:removeEntity(safeObj)
            end
        end)
    elseif Config.TargetSystem == 'qb-target' and exports and exports['qb-target'] then
        pcall(function()
            if exports['qb-target'].RemoveTargetEntity then
                exports['qb-target']:RemoveTargetEntity(safeObj)
            end
        end)
    end

    -- Build common actions list (used to generate per-target-system option tables)
    local actions = {}

    local isLocked = safeData.isLocked ~= false

    local function getNowSeconds()
        if type(GetCloudTimeAsInt) == 'function' then
            return GetCloudTimeAsInt()
        elseif type(GetGameTimer) == 'function' then
            return math.floor(GetGameTimer() / 1000)
        end
        return 0
    end

    local function isSealActive(data)
        local sealUntil = data and tonumber(data.sealUntil) or 0
        local now = getNowSeconds()
        return now > 0 and sealUntil > now
    end

    -- Open action
    table.insert(actions, { key = 'open', icon = 'fas fa-vault', label = isLocked and 'Enter Code' or 'Open Safe' })

    -- Helper to check if player has a required item (ox_inventory or QB)
    local function playerHas(itemName)
        if not itemName then return false end
        if exports and exports.ox_inventory and exports.ox_inventory.Search then
            local count = exports.ox_inventory:Search('count', itemName)
            return (count or 0) > 0
        end
        return false
    end

    local function playerHasKeyForSafe(id)
        if not (Config.SafeKeys and Config.SafeKeys.Enabled) then return false end
        if exports and exports.ox_inventory and exports.ox_inventory.Search then
            local keyItem = Config.SafeKeys.KeyItem or 'safe_key'
            local ok, count = pcall(function()
                return exports.ox_inventory:Search('count', keyItem, { safeId = id })
            end)
            if ok and (count or 0) > 0 then
                return true
            end
        end
        return false
    end

    local isOwner = Player and Player.citizenid and Player.citizenid == safeData.owner

    if isLocked and Config.SafeKeys and Config.SafeKeys.Enabled then
        table.insert(actions, { key = 'key', icon = 'fas fa-key', label = 'Unlock with Key' })
    end

    if isLocked then
        if isOwner then
            table.insert(actions, { key = 'settings', icon = 'fas fa-cog', label = 'Safe Settings' })
        else
            -- Breach options for non-owners (only add if player has item)
            for toolType, toolData in pairs(Config.BreachTools or {}) do
                local toolName = tostring(toolType or ''):lower()
                local sealed = isSealActive(safeData)
                local antiDrill = safeData and ((safeData.antiDrill == true) or (tonumber(safeData.antiDrill) == 1))
                if toolName:find('hack') and sealed then
                    -- hide hack option while a vault seal is active
                elseif toolName:find('drill') and antiDrill then
                    -- hide drill option while anti-drill is installed
                else
                    table.insert(actions, { key = 'breach', tool = toolType, icon = 'fas fa-hammer', label = toolData.label })
                end
            end
        end
    else
        table.insert(actions, { key = 'relock', icon = 'fas fa-lock', label = 'Lock Safe' })
    end

    -- If a vault seal is active, schedule a refresh when it expires
    if isLocked and isSealActive(safeData) then
        local now = getNowSeconds()
        local remaining = (tonumber(safeData.sealUntil) or 0) - now
        if remaining > 0 and not sealRefreshTimers[safeId] then
            sealRefreshTimers[safeId] = true
            CreateThread(function()
                Wait((remaining + 1) * 1000)
                sealRefreshTimers[safeId] = nil
                local entry = safes[safeId]
                if entry and entry.object and DoesEntityExist(entry.object) then
                    AddTargetToSafe(entry.object, safeId, entry.data)
                end
            end)
        end
    end

    -- Build and register options for configured target system
    if Config.TargetSystem == 'ox_target' then
        if not (exports and exports.ox_target) then
        return
    end
        local oxOptions = {}
        for i, a in ipairs(actions) do
            local action = a.key
            local toolType = a.tool
            local opt = {
                name = ('yy_safe_%s_%s'):format(tostring(safeId), tostring(i)),
                icon = a.icon,
                label = a.label,
                canInteract = function()
                    local current = safes[safeId] and safes[safeId].data or safeData
                    local locked = current.isLocked ~= false
                    local player = QBCore.Functions.GetPlayerData()
                    local isOwner = player and player.citizenid and current and current.owner == player.citizenid
                    if action == 'open' then
                        return true
                    elseif action == 'settings' then
                        return isOwner and locked
                    elseif action == 'key' then
                        return locked and playerHasKeyForSafe(safeId)
                    elseif action == 'relock' then
                        if locked then return false end
                        local breached = current and current.wasBreached == true
                        if breached then
                            return isOwner
                        end
                        return true
                    elseif action == 'breach' then
                        if locked and not isOwner and toolType then
                            local toolName = tostring(toolType or ''):lower()
                            local sealed = isSealActive(current)
                            local antiDrill = current and ((current.antiDrill == true) or (tonumber(current.antiDrill) == 1))
                            if toolName:find('hack') and sealed then
                                return false
                            end
                            if toolName:find('drill') and antiDrill then
                                return false
                            end
                            return playerHas(Config.BreachTools[toolType] and Config.BreachTools[toolType].item)
                        end
                    end
                    return false
                end,
                onSelect = function()
                    local current = safes[safeId] and safes[safeId].data or safeData
                    local locked = current.isLocked ~= false
                    local player = QBCore.Functions.GetPlayerData()
                    local isOwner = player and player.citizenid and current and current.owner == player.citizenid
                    if action == 'open' then
                        if locked then
                            OpenSafe(safeId)
                        else
                            TriggerServerEvent('yy-secure-safes:server:OpenInventory', safeId)
                        end
                    elseif action == 'settings' then
                        OpenSafeSettings(safeId)
                    elseif action == 'key' then
                        TriggerServerEvent('yy-secure-safes:server:UseSafeKey', safeId)
                    elseif action == 'breach' and toolType then
                        TriggerServerEvent('yy-secure-safes:server:AttemptBreach', safeId, toolType)
                    elseif action == 'relock' and not locked then
                        TriggerServerEvent('yy-secure-safes:server:RelockSafe', safeId)
                    end
                end
            }
            table.insert(oxOptions, opt)
        end
        exports.ox_target:addLocalEntity(safeObj, oxOptions)

    elseif Config.TargetSystem == 'qb-target' then
        if not (exports and exports['qb-target']) then
        return
    end
        local qbOptions = {}
        for i, a in ipairs(actions) do
            table.insert(qbOptions, {
                name = ('yy_safe_%s_%s'):format(tostring(safeId), tostring(i)),
                icon = a.icon,
                label = a.label,
                canInteract = function()
                    local current = safes[safeId] and safes[safeId].data or safeData
                    local locked = current.isLocked ~= false
                    local player = QBCore.Functions.GetPlayerData()
                    local isOwner = player and player.citizenid and current and current.owner == player.citizenid
                    if a.key == 'open' then
                        return true
                    elseif a.key == 'settings' then
                        return isOwner and locked
                    elseif a.key == 'key' then
                        return locked and playerHasKeyForSafe(safeId)
                    elseif a.key == 'relock' then
                        if locked then return false end
                        local breached = current and current.wasBreached == true
                        if breached then
                            return isOwner
                        end
                        return true
                    elseif a.key == 'breach' and a.tool then
                        if locked and not isOwner then
                            return playerHas(Config.BreachTools[a.tool] and Config.BreachTools[a.tool].item)
                        end
                    end
                    return false
                end,
                action = function()
                    TriggerEvent('yy-secure-safes:client:TargetAction', { action = a.key, safeId = safeId, toolType = a.tool })
                end
            })
        end
        exports['qb-target']:AddTargetEntity(safeObj, { options = qbOptions, distance = 2.0 })
    end
end




-- Safe Management
local function SpawnSafe(safeId, safeData)
    -- apply any pending lock state overrides
    if pendingLockStates[safeId] ~= nil then
        safeData.isLocked = pendingLockStates[safeId]
        pendingLockStates[safeId] = nil
    end

    if safes[safeId] then
        safes[safeId].data = safeData
        if safes[safeId].object and DoesEntityExist(safes[safeId].object) then
            AddTargetToSafe(safes[safeId].object, safeId, safes[safeId].data)
        end
        return
    end
    local safeModel = Config.SafeModels[safeData.tier]
    helpers.LoadSafeModel(safeModel)
    local safeObj = CreateObject(GetHashKey(safeModel), safeData.position.x, safeData.position.y, safeData.position.z, false, false, false)
    SetEntityRotation(safeObj, safeData.rotation.x, safeData.rotation.y, safeData.rotation.z, 2, true)
    SetEntityCollision(safeObj, true, true)
    FreezeEntityPosition(safeObj, true)
    SetEntityCoordsNoOffset(safeObj, safeData.position.x, safeData.position.y, safeData.position.z, false, false, false)
    safes[safeId] = { object = safeObj, data = safeData }
    AddTargetToSafe(safeObj, safeId, safeData)
end

-- Safe Access Functions
function OpenSafe(safeId)
    local safe = safes[safeId]
    if not safe then return end
    if safe.data and safe.data.isLocked == false then
        TriggerServerEvent('yy-secure-safes:server:OpenInventory', safeId)
        return
    end
    SetNuiFocus(true, true)
    nuiOpen = true
    SendNUIMessage({ action = 'open', mode = 'enter', safeId = safeId })
end

-- NUI callbacks
RegisterNUICallback('submitPasscode', function(data, cb)
    local code = tostring(data.code or '')
    local mode = data.mode
    if not mode then cb('ok') return end

    if mode == 'enter' then
        local safeId = data.safeId
        QBCore.Functions.TriggerCallback('yy-secure-safes:server:VerifyAccess', function(hasAccess)
            if hasAccess then
                QBCore.Functions.Notify('Safe unlocked. Use Open Safe to access.', 'success')
            else
                QBCore.Functions.Notify('Invalid code!', 'error')
            end
        end, safeId, code)

    elseif mode == 'set_placement' then
        if pendingPlace then
            TriggerServerEvent('yy-secure-safes:server:PlaceSafe', {
                tier = pendingPlace.tier,
                position = pendingPlace.position,
                rotation = pendingPlace.rotation,
                passcode = code
            })
            if pendingPlace.preview and DoesEntityExist(pendingPlace.preview) then DeleteEntity(pendingPlace.preview) end
            pendingPlace = nil
            placingSafe = false
        end
        SendNUIMessage({ action = 'hidePlacementHelp' })

    elseif mode == 'change' then
        local safeId = data.safeId
        TriggerServerEvent('yy-secure-safes:server:ChangePasscode', safeId, code)
    end

    SetNuiFocus(false, false)
    nuiOpen = false
    cb('ok')
end)

RegisterNUICallback('close', function(_, cb)
    SetNuiFocus(false, false)
    nuiOpen = false
    if pendingPlace and pendingPlace.preview and DoesEntityExist(pendingPlace.preview) then
        DeleteEntity(pendingPlace.preview)
        pendingPlace = nil
        placingSafe = false
    end
    SendNUIMessage({ action = 'hidePlacementHelp' })
    cb('ok')
end)

RegisterNUICallback('settingsMenuAction', function(data, cb)
    if not data or not data.action or not data.safeId then
        cb('nok')
        return
    end
    local safeId = tonumber(data.safeId) or data.safeId
    local safe = safes[safeId]
    SetNuiFocus(false, false)

    if data.action == 'change-passcode' then
        SetNuiFocus(true, true)
        nuiOpen = true
        SendNUIMessage({ action = 'open', mode = 'change', safeId = data.safeId })
    elseif data.action == 'move-safe' then
        if safe then
            TriggerServerEvent('yy-secure-safes:server:ReturnSafe', safeId)
        end
    elseif data.action == 'craft-key' then
        if safe then
            TriggerServerEvent('yy-secure-safes:server:CraftSafeKey', safeId)
        end
    elseif data.action == 'upgrade-storage' then
        if safe then
            TriggerServerEvent('yy-secure-safes:server:UpgradeSafeStorage', safeId)
        end
    elseif data.action == 'remove-upgrade' then
        if safe then
            TriggerServerEvent('yy-secure-safes:server:RemoveSafeUpgrade', safeId)
        end
    elseif data.action == 'vault-seal' then
        if safe then
            TriggerServerEvent('yy-secure-safes:server:ApplyVaultSeal', safeId)
        end
    elseif data.action == 'anti-drill' then
        if safe then
            TriggerServerEvent('yy-secure-safes:server:InstallAntiDrill', safeId)
        end
    elseif data.action == 'install-alarm' then
        if safe then
            TriggerServerEvent('yy-secure-safes:server:InstallSafeAlarm', safeId)
        end
    elseif data.action == 'remove-alarm' then
        if safe then
            TriggerServerEvent('yy-secure-safes:server:RemoveSafeAlarm', safeId)
        end
    end
    
    cb('ok')
end)

RegisterNUICallback('closeSettingsMenu', function(_, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

-- Safe Settings (custom NUI menu)
function OpenSafeSettings(safeId)
    local safe = safes[safeId]
    if not safe then return end

    SetNuiFocus(true, true)
    local enableKeyCraft = Config.SafeKeys and Config.SafeKeys.Enabled or false
    local tier = safe.data and safe.data.tier
    local enableUpgrades = Config.StorageUpgrades and Config.StorageUpgrades.Enabled and Config.StorageUpgrades[tier] ~= nil or false
    local canRemoveUpgrade = safe.data and (tonumber(safe.data.upgradeLevel) or 0) > 0 or false
    local enableVaultSeal = Config.VaultSeal and Config.VaultSeal.Enabled or false
    local enableAntiDrill = Config.AntiDrill and Config.AntiDrill.Enabled or false
    local sealUntil = safe.data and tonumber(safe.data.sealUntil) or 0
    local now = 0
    if type(GetCloudTimeAsInt) == 'function' then
        now = GetCloudTimeAsInt()
    elseif type(GetGameTimer) == 'function' then
        now = math.floor(GetGameTimer() / 1000)
    end
    local canApplyVaultSeal = enableVaultSeal and (sealUntil <= now or now == 0)
    local canApplyAntiDrill = enableAntiDrill and not (safe.data and safe.data.antiDrill == true)
    local enableAlarm = Config.SafeAlarm and Config.SafeAlarm.Enabled or false
    local alarmArmed = safe.data and safe.data.alarmArmed == true
    local canInstallAlarm = enableAlarm and not alarmArmed
    local canRemoveAlarm = enableAlarm and alarmArmed
    SendNUIMessage({
        action = 'openSettingsMenu',
        safeId = safeId,
        enableKeyCraft = enableKeyCraft,
        enableUpgrades = enableUpgrades,
        canRemoveUpgrade = canRemoveUpgrade,
        enableVaultSeal = enableVaultSeal,
        canApplyVaultSeal = canApplyVaultSeal,
        enableAntiDrill = enableAntiDrill,
        canApplyAntiDrill = canApplyAntiDrill,
        enableAlarm = enableAlarm,
        canInstallAlarm = canInstallAlarm,
        canRemoveAlarm = canRemoveAlarm
    })
end
local function notify(msg, nType)
    nType = nType or 'inform'
    if Config.NotifyType == 'ox' and exports and exports.ox_lib and exports.ox_lib.notify then
        -- ox_lib expects a table; guard to avoid nil data errors
        exports.ox_lib:notify({
            title = 'Secure Safe',
            description = msg or '',
            type = nType,
        })
    else
        QBCore.Functions.Notify(msg or '', nType)
    end
end

RegisterNetEvent('yy-secure-safes:client:StartBreach', function(safeId, tier, toolType, difficulty)
    local safe = safes[safeId]
    if not safe then return end
    local toolConf = (Config.BreachTools and Config.BreachTools[toolType]) or {}
    local tierConf = Config.SafeTiers[tier] or {}
    difficulty = difficulty or tierConf.breachDifficulty or {}
    notify('Starting breach (' .. (toolConf and toolConf.label or 'tool') .. ')', 'inform')

    local isHackTool = toolType and (toolType:lower():find('hack') or toolType == 'hackingtool')
    local success = false
    local fallbackBase = ((difficulty.fallback and difficulty.fallback.baseTime) or 30) * 1000
    local fallbackChance = (difficulty.fallback and difficulty.fallback.successChance) or (toolConf and toolConf.successRate) or 50
    local hackTime = (difficulty.mhacking and difficulty.mhacking.time) or 30 -- seconds
    local useMhacking = Config.Minigames and Config.Minigames.UseMhacking

    if isHackTool then
        StartHackAnim()
    end

    -- mhacking attempt (uses events, not exports)
    if useMhacking and isHackTool and GetResourceState('mhacking') == 'started' then
        local mhack = difficulty.mhacking or {}
        local done = false
        local result = false
        TriggerEvent('mhacking:show')
        TriggerEvent('mhacking:start', mhack.blocks or 4, hackTime, function(s)
            result = s
            done = true
            TriggerEvent('mhacking:hide')
        end)
        local timeout = GetGameTimer() + (hackTime + 5) * 1000
        while not done and GetGameTimer() < timeout do Wait(0) end
        success = result

    elseif toolType and toolType:lower():find('drill') then
        local drillTime = ((toolConf and toolConf.drillTime) or 120) * 1000
        local finished = false
        local drillConf = Config.DrillAnim or {}
        local drillProp = drillConf.prop or {}
        if exports and exports.ox_lib and exports.ox_lib.progressCircle then
            finished = exports.ox_lib:progressCircle({
                duration = drillTime,
                label = 'Drilling the safe...',
                position = 'bottom',
                useWhileDead = false,
                canCancel = true,
                disable = { move = true, car = true, combat = true },
                anim = { dict = drillConf.dict or 'anim@heists@fleeca_bank@drilling', clip = drillConf.clip or 'drill_straight_idle', flag = drillConf.flag or 49 },
                prop = {
                    model = drillProp.model or 'hei_prop_heist_drill',
                    bone = drillProp.bone or 57005,
                    pos = vec3((drillProp.pos and drillProp.pos.x) or 0.13, (drillProp.pos and drillProp.pos.y) or 0.02, (drillProp.pos and drillProp.pos.z) or -0.02),
                    rot = vec3((drillProp.rot and drillProp.rot.x) or 0.0, (drillProp.rot and drillProp.rot.y) or 90.0, (drillProp.rot and drillProp.rot.z) or 90.0)
                }
            })
        elseif QBCore.Functions and QBCore.Functions.Progressbar then
            QBCore.Functions.Progressbar('yy_safe_drill', 'Drilling the safe...', drillTime, false, true, {
                disableMovement = true,
                disableCarMovement = true,
                disableMouse = false,
                disableCombat = true,
            }, {
                animDict = drillConf.dict or 'anim@heists@fleeca_bank@drilling',
                anim = drillConf.clip or 'drill_straight_idle',
                flags = drillConf.flag or 49
            }, {}, {}, function() finished = true end, function() finished = false end)
            Wait(drillTime + 500)
        else
            Wait(drillTime)
            finished = math.random(1,100) <= fallbackChance
        end
        success = finished

    else
        Wait(fallbackBase)
        success = math.random(1,100) <= fallbackChance
    end

    if isHackTool then
        StopHackAnim()
    end

    if success then
        TriggerServerEvent('yy-secure-safes:server:BreachSuccess', safeId, toolType)
    else
        notify('Breach failed!', 'error')
    end
end)

-- Sync and events
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    TriggerServerEvent('yy-secure-safes:server:RequestSafes')
end)

RegisterNetEvent('yy-secure-safes:client:SyncSafes', function(serverSafes)
    for safeId, safeData in pairs(serverSafes) do
        SpawnSafe(safeId, safeData)
    end
end)

RegisterNetEvent('yy-secure-safes:client:SafePlaced', function(safeId, safeData)
    SpawnSafe(safeId, safeData)
end)

RegisterNetEvent('yy-secure-safes:client:MarkUnlocked', function(safeId)
    if safes[safeId] and safes[safeId].data then
        safes[safeId].data.isLocked = false
        if safes[safeId].object and DoesEntityExist(safes[safeId].object) then
            AddTargetToSafe(safes[safeId].object, safeId, safes[safeId].data)
        end
    else
        pendingLockStates[safeId] = false
    end
    PlaySafeSound(safeId, 'unlock')
end)

RegisterNetEvent('yy-secure-safes:client:MarkLocked', function(safeId)
    if safes[safeId] and safes[safeId].data then
        safes[safeId].data.isLocked = true
        if safes[safeId].object and DoesEntityExist(safes[safeId].object) then
            AddTargetToSafe(safes[safeId].object, safeId, safes[safeId].data)
        end
    else
        pendingLockStates[safeId] = true
    end
    PlaySafeSound(safeId, 'lock')
end)

RegisterNetEvent('yy-secure-safes:client:PlayAlarm', function(safeId, alarmUntil)
    local safe = safes[safeId]
    if not safe then return end
    local conf = Config.SafeAlarm or {}
    if not conf.Enabled then return end
    local now = math.floor(GetGameTimer() / 1000)
    local duration = tonumber(alarmUntil)
    local untilTime = nil
    if duration and duration > 0 and duration < 86400 then
        untilTime = now + duration
    else
        untilTime = tonumber(alarmUntil) or (now + (tonumber(conf.DurationSeconds) or 0))
    end
    local currentUntil = activeAlarms[safeId] or 0
    if untilTime > currentUntil then
        activeAlarms[safeId] = untilTime
    end
    if alarmLoops[safeId] then return end

    alarmLoops[safeId] = true
    CreateThread(function()
        local updateMs = tonumber(conf.VolumeUpdateMs) or 200
        local radius = tonumber(conf.Radius) or 25.0
        local baseVolume = tonumber(conf.Volume) or 0.35
        local minVolume = tonumber(conf.MinVolume) or 0.0
        local falloff = tonumber(conf.FalloffExponent) or 1.0
        local soundName = conf.Sound or 'safe_alarm'
        local started = false

        while activeAlarms[safeId] and activeAlarms[safeId] > math.floor(GetGameTimer() / 1000) do
            local entry = safes[safeId]
            if not entry then break end
            local coords = nil
            if entry.object and DoesEntityExist(entry.object) then
                coords = GetEntityCoords(entry.object)
            elseif entry.data and entry.data.position then
                coords = vector3(entry.data.position.x, entry.data.position.y, entry.data.position.z)
            end
            local scaled = 0
            if coords and radius > 0 then
                local playerCoords = GetEntityCoords(PlayerPedId())
                local dist = #(playerCoords - coords)
                if dist <= radius then
                    local ratio = 1.0 - (dist / radius)
                    if ratio < 0 then ratio = 0 end
                    if ratio > 1 then ratio = 1 end
                    local curve = ratio ^ falloff
                    if minVolume > 0 and baseVolume > minVolume then
                        scaled = minVolume + ((baseVolume - minVolume) * curve)
                    else
                        scaled = baseVolume * curve
                    end
                end
            end

            if scaled > 0 then
                if not started then
                    SendNUIMessage({ action = 'startAlarm', safeId = safeId, sound = soundName, volume = scaled })
                    started = true
                else
                    SendNUIMessage({ action = 'setAlarmVolume', safeId = safeId, volume = scaled })
                end
            elseif started then
                SendNUIMessage({ action = 'setAlarmVolume', safeId = safeId, volume = 0 })
            end

            Wait(math.max(50, updateMs))
        end
        activeAlarms[safeId] = nil
        alarmLoops[safeId] = nil
        if started then
            SendNUIMessage({ action = 'stopAlarm', safeId = safeId })
        end
    end)
end)

CreateThread(function()
    while true do
        local conf = Config.SafeAlarm and Config.SafeAlarm.Light or nil
        if not (Config.SafeAlarm and Config.SafeAlarm.Enabled and conf and conf.Enabled) then
            Wait(1000)
        else
            local blinkMs = tonumber(conf.BlinkIntervalMs) or 600
            local range = tonumber(conf.Range) or 2.0
            local intensity = tonumber(conf.Intensity) or 2.0
            local baseOffsetUp = tonumber(conf.OffsetUp) or 0.6
            local baseOffsetForward = tonumber(conf.OffsetForward) or 0.0
            local baseOffsetRight = tonumber(conf.OffsetRight) or 0.0
            local perTierOffsets = conf.PerTierOffsets or {}
            local viewDistance = tonumber(conf.ViewDistance) or 40.0
            local sphereConf = conf.Sphere or {}
            local sphereEnabled = sphereConf.Enabled == true
            local sphereSize = tonumber(sphereConf.Size) or 0.06
            local sphereAlpha = tonumber(sphereConf.Alpha) or 180
            local playerCoords = GetEntityCoords(PlayerPedId())
            local hasAlarm = false
            local blinkOn = (GetGameTimer() % blinkMs) < (blinkMs / 2)
            for _, entry in pairs(safes) do
                if entry and entry.data and entry.data.alarmArmed then
                    hasAlarm = true
                    local tier = entry.data.tier
                    local tierOffsets = perTierOffsets and perTierOffsets[tier] or nil
                    local offsetUp = tonumber(tierOffsets and tierOffsets.up) or baseOffsetUp
                    local offsetForward = tonumber(tierOffsets and tierOffsets.forward) or baseOffsetForward
                    local offsetRight = tonumber(tierOffsets and tierOffsets.right) or baseOffsetRight
                    local coords = nil
                    local forward = nil
                    local right = nil
                    if entry.object and DoesEntityExist(entry.object) then
                        coords = GetEntityCoords(entry.object)
                        forward = GetEntityForwardVector(entry.object)
                        if forward then
                            right = vector3(forward.y, -forward.x, 0.0)
                        end
                    elseif entry.data.position then
                        coords = vector3(entry.data.position.x, entry.data.position.y, entry.data.position.z)
                        local heading = entry.data.rotation and entry.data.rotation.z or 0.0
                        local rad = math.rad(heading)
                        forward = vector3(-math.sin(rad), math.cos(rad), 0.0)
                        right = vector3(math.cos(rad), math.sin(rad), 0.0)
                    end
                    if coords and blinkOn and #(playerCoords - coords) <= viewDistance then
                        local lightPos = coords
                        if forward and offsetForward ~= 0.0 then
                            lightPos = vector3(lightPos.x + forward.x * offsetForward, lightPos.y + forward.y * offsetForward, lightPos.z)
                        end
                        if right and offsetRight ~= 0.0 then
                            lightPos = vector3(lightPos.x + right.x * offsetRight, lightPos.y + right.y * offsetRight, lightPos.z)
                        end
                        DrawLightWithRange(lightPos.x, lightPos.y, lightPos.z + offsetUp, 255, 0, 0, range, intensity)
                        if sphereEnabled then
                            DrawMarker(
                                28,
                                lightPos.x,
                                lightPos.y,
                                lightPos.z + offsetUp,
                                0.0, 0.0, 0.0,
                                0.0, 0.0, 0.0,
                                sphereSize, sphereSize, sphereSize,
                                255, 0, 0, sphereAlpha,
                                false, true, 2, false, nil, nil, false
                            )
                        end
                    end
                end
            end
            if not hasAlarm then
                Wait(500)
            else
                Wait(0)
            end
        end
    end
end)

-- Force-refresh targets for a single safe (debug)
RegisterNetEvent('yy-secure-safes:client:RefreshTargets', function(safeId)
    local safe = safes[safeId]
    if not safe or not safe.object or not DoesEntityExist(safe.object) then return end
    AddTargetToSafe(safe.object, safeId, safe.data)
end)

RegisterNetEvent('yy-secure-safes:client:OpenSafeInventory', function(safeId)
    local safe = safes[safeId]
    if not safe then return end
    local stashName = 'safe_' .. safeId
    if exports['ox_inventory'] then
        local ok = pcall(function()
            if exports['ox_inventory'].openInventory then
                exports['ox_inventory']:openInventory('stash', stashName)
            end
        end)
        if not ok then
            QBCore.Functions.Notify('Open stash: ' .. stashName, 'success')
        end
    else
        QBCore.Functions.Notify('Opened safe: ' .. stashName, 'success')
    end
end)

-- Safe Placement Function
function StartSafePlacement(tier)
    placingSafe = false
    previewSafe = nil
    if previewSafe and DoesEntityExist(previewSafe) then DeleteEntity(previewSafe) end
    previewSafe = nil
    
    if not tier or not Config.SafeModels[tier] then
        QBCore.Functions.Notify('Invalid safe tier: ' .. tostring(tier), 'error')
        return
    end
    
    placingSafe = true
    placingTier = tier
    local safeModel = Config.SafeModels[tier]
    
    -- Load and create preview object (spawn in front of player)
    helpers.LoadSafeModel(safeModel)
    local modelHash = GetHashKey(safeModel)
    local minDim, _ = GetModelDimensions(modelHash)
    local extraOffset = 0.0
    if Config.PlacementZOffsets and Config.PlacementZOffsets[tier] then
        extraOffset = Config.PlacementZOffsets[tier]
    end
    local zOffset = -minDim.z + extraOffset
    local playerPed = PlayerPedId()
    local playerCoord = GetEntityCoords(playerPed)
    local playerHeading = GetEntityHeading(playerPed)
    local headingRad = math.rad(playerHeading)
    local playerDir = vector3(-math.sin(headingRad), math.cos(headingRad), 0)
    local spawnPos = vector3(playerCoord.x + playerDir.x * 2.0, playerCoord.y + playerDir.y * 2.0, playerCoord.z + 0.5)
    previewSafe = CreateObject(modelHash, spawnPos.x, spawnPos.y, spawnPos.z, false, false, false)
    
    if not previewSafe or previewSafe == 0 then
        placingSafe = false
        return
    end

    SetEntityHeading(previewSafe, playerHeading)
    SetEntityAlpha(previewSafe, 255)
    FreezeEntityPosition(previewSafe, true)
    SetEntityCollision(previewSafe, false, false)
    SendNUIMessage({ action = 'showPlacementHelp' })
    
    local rotation = { x = 0, y = 0, z = GetEntityHeading(previewSafe) }
    
    -- Placement loop: follow camera hit position, confirm with Enter, cancel with Backspace
    CreateThread(function()
        while placingSafe do
            if previewSafe and DoesEntityExist(previewSafe) then
                local maxDistance = Config.PlacementDistance or 8.0
                local ignoreEntity = (previewSafe and previewSafe ~= 0) and previewSafe or PlayerPedId()
                local hit, hitCoords = RaycastFromCamera(maxDistance, ignoreEntity)
                if hit and hitCoords then
                    SetEntityCoordsNoOffset(previewSafe, hitCoords.x, hitCoords.y, hitCoords.z + zOffset, false, false, false)
                    SetEntityRotation(previewSafe, rotation.x, rotation.y, rotation.z, 2, true)
                end

                if IsControlPressed(0, 174) then -- LEFT
                    rotation.z = rotation.z - 1.5
                    SetEntityRotation(previewSafe, rotation.x, rotation.y, rotation.z, 2, true)
                elseif IsControlPressed(0, 175) then -- RIGHT
                    rotation.z = rotation.z + 1.5
                    SetEntityRotation(previewSafe, rotation.x, rotation.y, rotation.z, 2, true)
                end
                
                -- Confirm with Enter, Cancel with Backspace
                if IsControlJustPressed(0, 191) then -- Enter
                    ConfirmPlacement()
                elseif IsControlJustPressed(0, 194) then -- Backspace
                    CancelPlacement()
                end
                
                Wait(0)
            else
                -- If preview doesn't exist, cancel
                placingSafe = false
            end
        end
    end)

end

-- Confirm the current preview placement: open NUI to set passcode (or send directly)
function ConfirmPlacement()
    if not placingSafe or not previewSafe or not DoesEntityExist(previewSafe) then return end
    local pos = GetEntityCoords(previewSafe)
    local rot = GetEntityRotation(previewSafe)
    pendingPlace = {
        tier = placingTier,
        position = { x = pos.x, y = pos.y, z = pos.z },
        rotation = { x = rot.x, y = rot.y, z = rot.z },
        preview = previewSafe
    }
    SendNUIMessage({ action = 'hidePlacementHelp' })
    -- Open the passcode NUI so the user can enter a passcode for the new safe
    SetNuiFocus(true, true)
    nuiOpen = true
    SendNUIMessage({ action = 'open', mode = 'set_placement' })
end

function CancelPlacement()
    if previewSafe and DoesEntityExist(previewSafe) then
        DeleteEntity(previewSafe)
    end
    previewSafe = nil
    pendingPlace = nil
    placingSafe = false
    placingTier = nil
    SendNUIMessage({ action = 'hidePlacementHelp' })
    if nuiOpen then SetNuiFocus(false, false); nuiOpen = false end
end

-- Register export/event handlers after StartSafePlacement is defined
RegisterNetEvent('yy-secure-safes:client:UseItem', function(tier)
    if placingSafe then return end
    local n = tonumber(tostring(tier))
    if n then
        StartSafePlacement(n)
    else
    end
end)

-- Generic target action handler (qb-target route)
RegisterNetEvent('yy-secure-safes:client:TargetAction', function(data)
    if not data or not data.action then return end
    if data.action == 'open' then
        OpenSafe(data.safeId)
    elseif data.action == 'settings' then
        OpenSafeSettings(data.safeId)
    elseif data.action == 'key' then
        TriggerServerEvent('yy-secure-safes:server:UseSafeKey', data.safeId)
    elseif data.action == 'breach' and data.toolType then
        TriggerServerEvent('yy-secure-safes:server:AttemptBreach', data.safeId, data.toolType)
    elseif data.action == 'relock' then
        TriggerServerEvent('yy-secure-safes:server:RelockSafe', data.safeId)
    end
end)

-- Client export for ox_inventory: called when item is used from ox_inventory UI
exports('useSafe', function(item, slot)
    local tier
    if slot and type(slot.name) == 'string' then
        tier = tonumber(string.match(slot.name, 'safe_tier_(%d+)'))
    elseif item and type(item.name) == 'string' then
        tier = tonumber(string.match(item.name, 'safe_tier_(%d+)'))
    end
    if not tier then
        return false
    end
    TriggerEvent('yy-secure-safes:client:UseItem', tier)
    return true
end)

RegisterNetEvent('yy-secure-safes:client:DeleteSafeObject', function(safeId)
    local safe = safes[safeId]
    if safe and safe.object and DoesEntityExist(safe.object) then
        DeleteEntity(safe.object)
        safes[safeId] = nil
    end
end)

-- Client export for ox_inventory (so the item can call this directly)
-- (client export removed — using server export flow)

-- Cleanup
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        for _, safe in pairs(safes) do
            if safe.object and DoesEntityExist(safe.object) then
                DeleteEntity(safe.object)
            end
        end
        if previewSafe and DoesEntityExist(previewSafe) then DeleteEntity(previewSafe) end
    end
end)
