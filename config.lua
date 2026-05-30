Config = {}

Config.Debug = true

Config.EngineHealthThreshold = 300.0 
Config.Phase1EngineHealth = 650.0
Config.FreezeEngineHealth = 101.0    

Config.FireHealth = {
    Phase1 = 150,   
    Phase2 = 400,   
    Phase3 = 800,   
    Phase4 = 1000,  
    
    GrowthRate = 5, 
    BurnoutTime = 120,
    
    -- NIEUW: Hoeveel seconden het vuur stopt met groeien na 1 spray van de handblusser
    SuppressionTime = 3 
}

Config.CoolingPower = {
    -- Handblusser haalt nog maar heel weinig HP weg, zijn hoofddoel is nu tijd rekken (suppression)!
    Extinguisher = 1,  
    -- Brandweer hakt er keihard in en dooft het vuur definitief
    WaterCannon = 25   
}

Config.PTFX = {
    Asset = "core",
    Smoke = "ent_amb_smoke_general",       -- Voor afstand (bestaand)
    SmokeCloseAsset = "core",
    SmokeClose = "ent_amb_smoke_gaswork",  -- Witte fase 1 rook voor dichtbij/interieur
    SmokeCloseScale = 1.0,                 -- Grote witte fase 1 rook
    SmokeHoodLocalAsset = "core",
    SmokeHoodLocal = "ent_amb_steam_vent_open_lgt", -- Kleine witte lokale rook direct bij de motorkap
    SmokeHoodLocalScale = 2.3,
    SmokeHoodLocalInset = 0.65,            -- Afstand vanaf voor-/achterkant naar de engine bay
    SmokeHoodLocalZOffset = 0.18,
    SmokeHoodLocalStackZ = 0.12,
    FireSmall = "fire_wrecked_car",
    FireLarge = "fire_large_base"
}

Config.FireSound = {
    Enabled = true,
    StackSpacing = 0.35,
    ByPhase = {
        [1] = {
            AudioBank = "SCRIPT\\FBI_Heist_5_Finale_02",
            Name = "FBI_HEIST_H5_FIRE",
            Ref = 0,
            Range = 18,
            Stacks = 4
        },
        [2] = {
            Name = "PLANE_ON_FIRE",
            Ref = 0,
            Range = 28,
            Stacks = 3
        },
        [3] = {
            Name = "Trevor_4_747_Loud_Fire",
            Ref = 0,
            Range = 38,
            Stacks = 3
        },
        [4] = {
            Name = "Trevor_4_747_Loud_Fire",
            Ref = 0,
            Range = 52,
            Stacks = 3
        }
    }
}
