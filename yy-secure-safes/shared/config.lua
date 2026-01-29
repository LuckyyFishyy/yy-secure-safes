Config = {}

-- Core integrations
Config.TargetSystem = "ox_target"        -- "ox_target" or "qb-target"
Config.InventorySystem = "ox_inventory"  -- fixed to ox_inventory
Config.MenuSystem = "ox_lib"             -- kept for UI/NUI reference
Config.DatabaseTable = 'secure_safes'
Config.DebugLogs = false -- set true to see verbose console logs
Config.RunMigrationsOnStart = false -- set true to run CREATE TABLE IF NOT EXISTS every start
Config.PlacementDistance = 15.0 -- max distance for placement preview raycast (meters)
Config.PlacementZOffsets = { -- tweak if any tier floats or sinks after placement
    [1] = 0.0,
    [2] = -0.05,
    [3] = -0.05,
    [4] = -0.05
}

-- Notifications
Config.NotifyType = 'ox' -- 'ox' for ox_lib notify, 'qb' for QB notify

-- Default stash capacity (fallback if a tier is missing slots/weight)
Config.StashDefaults = { slots = 10, weight = 50000 } -- weight in grams

-- Item required for the owner to relock an unlocked safe (after a breach)
Config.RelockItem = 'safe_lockkit'
Config.RelockConsumesItem = true
Config.AutoRelockSeconds = 120 -- auto-lock after code unlock; set 0 to disable
Config.SoundRadius = 12.0 -- meters; set 0 to disable lock/unlock sounds
Config.SoundVolume = 0.35 -- 0.0 - 1.0
Config.Minigames = {
    UseMhacking = true -- when true, uses mhacking for hackingtool breaches if the resource is started
}
Config.HackingAnim = {
    dict = 'anim@heists@ornate_bank@hack',
    clip = 'hack_loop',
    flag = 1 -- 1 = loop; change if you prefer a different animation behavior
}
Config.DrillAnim = {
    dict = 'anim@heists@fleeca_bank@drilling',
    clip = 'drill_straight_idle',
    flag = 49,
    prop = {
        model = 'hei_prop_heist_drill',
        bone = 57005,
        pos = { x = 0.13, y = 0.02, z = -0.02 },
        rot = { x = 0.0, y = 90.0, z = 90.0 } -- adjust if the drill points wrong
    }
}
Config.SafeKeys = {
    Enabled = true,
    CraftItem = 'safe_key_blank',
    KeyItem = 'safe_key'
}
Config.StorageUpgrades = {
    Enabled = true,
    [1] = { item = 'safe_upgrade_tier_1', addSlots = 5, addWeight = 25000, maxUpgrades = 2 },
    [2] = { item = 'safe_upgrade_tier_2', addSlots = 5, addWeight = 25000, maxUpgrades = 2 },
    [3] = { item = 'safe_upgrade_tier_3', addSlots = 10, addWeight = 50000, maxUpgrades = 2 },
    [4] = { item = 'safe_upgrade_tier_4', addSlots = 10, addWeight = 50000, maxUpgrades = 2 }
}
Config.VaultSeal = {
    Enabled = true,
    Item = 'safe_vault_seal',
    DurationSeconds = 10,
    ConsumeItem = true
}
Config.AntiDrill = {
    Enabled = true,
    Item = 'safe_anti_drill',
    ConsumeItem = true
}
Config.SafeAlarm = {
    Enabled = true,
    Item = 'safe_alarm_module',
    ConsumeItem = true,
    ReturnItemOnRemove = true,
    DurationSeconds = 60,
    RepeatSeconds = 3,
    Sound = 'safe_alarm',
    Volume = 0.35,
    MinVolume = 0.05,
    Radius = 25.0,
    SoundLengthSeconds = 6,
    NoOverlap = true,
    FalloffExponent = 2.5,
    VolumeUpdateMs = 200,
    Light = {
        Enabled = true,
        Range = 2.0,
        Intensity = 50.0,
        OffsetUp = 0.31,
        OffsetForward = -0.31,
        OffsetRight = 0.02,
        PerTierOffsets = {
            [1] = { up = 0.31, forward = -0.31, right = 0.02 },
            [2] = { up = 0.446, forward = -0.387, right = 0.0087 },
            [3] = { up = 1.42, forward = -0.468, right = 0.009 },
            [4] = { up = 0.446, forward = -0.39, right = 0.0082 }
        },
        Sphere = {
            Enabled = true,
            Size = 0.02,
            Alpha = 180
        },
        BlinkIntervalMs = 1200,
        ViewDistance = 40.0
    }
}

-- Models used for preview/spawn per tier (override in SafeTiers if you want different visuals)
Config.SafeModels = {
    [1] = 'prop_ld_int_safe_01',
    [2] = 'p_v_43_safe_s',
    [3] = 'h4_prop_h4_safe_01a',
    [4] = 'sf_prop_v_43_safe_s_gd_01a'
}

-- Safe tiers: tweak price, capacity, attempts, cooldown, and minigame difficulty here
-- Difficulty keys:
--   mhacking.blocks        = how many sequences to solve (higher = harder)
--   mhacking.time          = seconds allowed (lower = harder)
--   mhacking.gridSize      = board size if supported by your mhacking version (larger = harder)
--   mhacking.errorLimit    = allowed mistakes (lower = harder)
--   fallback.baseTime      = fallback wait time in seconds when a minigame isn't available
--   fallback.successChance = % chance to succeed for fallback (lower = harder)
Config.SafeTiers = {
    [1] = {
        name = "Basic Safe",
        price = 5000,
        model = 'prop_security_case_01',
        slots = 30,
        weight = 50000,
        maxBreachAttempts = 3,
        cooldownTime = 300,
        breachDifficulty = {
            mhacking = { blocks = 4, time = 30, gridSize = 5, errorLimit = 3 },
            fallback = { baseTime = 30, successChance = 65 }
        }
    },
    [2] = {
        name = "Advanced Safe",
        price = 15000,
        model = 'prop_ld_int_safe_01',
        slots = 25,
        weight = 100000,
        maxBreachAttempts = 3,
        cooldownTime = 600,
        breachDifficulty = {
            mhacking = { blocks = 5, time = 25, gridSize = 6, errorLimit = 2 },
            fallback = { baseTime = 25, successChance = 55 }
        }
    },
    [3] = {
        name = "Professional Safe",
        price = 30000,
        model = 'p_v_43_safe_s',
        slots = 40,
        weight = 200000,
        maxBreachAttempts = 2,
        cooldownTime = 1200,
        breachDifficulty = {
            mhacking = { blocks = 6, time = 20, gridSize = 7, errorLimit = 2 },
            fallback = { baseTime = 20, successChance = 45 }
        }
    },
    [4] = {
        name = "Elite Safe",
        price = 50000,
        model = 'sf_prop_v_43_safe_s_bk_01a',
        slots = 60,
        weight = 500000,
        maxBreachAttempts = 2,
        cooldownTime = 1800,
        breachDifficulty = {
            mhacking = { blocks = 7, time = 15, gridSize = 8, errorLimit = 1 },
            fallback = { baseTime = 15, successChance = 35 }
        }
    }
}

-- Breach tools: item name must exist in your inventory system
Config.BreachTools = {
    hackingtool = { item = 'hackingtool', label = 'Hack Safe', successRate = 100, removeOnUse = true },
    drill = { item = 'drill', label = 'Drill Safe', successRate = 100, removeOnUse = true, drillTime = 120 }
}
