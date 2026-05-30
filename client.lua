local activeFires = {}
local activeFireSounds = {}
local knownFirePhases = {}
local knownEngineDisabled = {}
local vehicleStates = {} -- Hier slaan we de fase, protectie en blus-status op PER netId
local lastExtinguishCheck = 0

-- Wapens die de brand kunnen blussen
local extinguishWeaponHashes = {
    `WEAPON_FIREEXTINGUISHER`,
    `WEAPON_HIT_BY_WATER_CANNON`
}

local function IsExtinguishingWeapon(weaponHash)
    for _, hash in ipairs(extinguishWeaponHashes) do
        if weaponHash == hash then
            return true
        end
    end
    return false
end

local function RotationToDirection(rotation)
    local adjustedRotation = {
        x = (math.pi / 180) * rotation.x,
        y = (math.pi / 180) * rotation.y,
        z = (math.pi / 180) * rotation.z
    }
    local directions = {
        x = -math.sin(adjustedRotation.z) * math.abs(math.cos(adjustedRotation.x)),
        y = math.cos(adjustedRotation.z) * math.abs(math.cos(adjustedRotation.x)),
        z = math.sin(adjustedRotation.x)
    }
    return directions
end

local function EnsureNetworkControl(entity)
    if not DoesEntityExist(entity) then return false end
    if NetworkHasControlOfEntity(entity) then return true end

    NetworkRequestControlOfEntity(entity)
    local timeout = 0
    while not NetworkHasControlOfEntity(entity) and timeout < 30 do
        Wait(10)
        timeout = timeout + 1
    end
    return NetworkHasControlOfEntity(entity)
end

local function GetEngineBone(veh)
    local engineBone = GetEntityBoneIndexByName(veh, "engine")
    local bonnetBone = GetEntityBoneIndexByName(veh, "bonnet")
    local bootBone = GetEntityBoneIndexByName(veh, "boot")

    if engineBone ~= -1 then return engineBone end
    if bonnetBone ~= -1 then return bonnetBone end
    if bootBone ~= -1 then return bootBone end

    return 0
end

local function RequestPtfxAssetSynced(asset)
    if not HasNamedPtfxAssetLoaded(asset) then
        RequestNamedPtfxAsset(asset)
        while not HasNamedPtfxAssetLoaded(asset) do
            Wait(10)
        end
    end
end

local function StartFirePtfx(fxList, effect, veh, bone, x, y, z, scale, asset)
    asset = asset or Config.PTFX.Asset

    RequestPtfxAssetSynced(asset)
    UseParticleFxAssetNextCall(asset)
    local fx = StartParticleFxLoopedOnEntityBone(effect, veh, x, y, z, 0.0, 0.0, 0.0, bone, scale, false, false, false)

    if fx and fx ~= 0 then
        table.insert(fxList, fx)
    elseif Config.Debug then
        print(("[CarFires Debug] Particle kon niet starten: asset=%s effect=%s"):format(asset, effect))
    end

    return fx
end

local function StartFirePtfxOnEntity(fxList, effect, veh, x, y, z, scale, asset)
    asset = asset or Config.PTFX.Asset

    RequestPtfxAssetSynced(asset)
    UseParticleFxAssetNextCall(asset)
    local fx = StartParticleFxLoopedOnEntity(effect, veh, x, y, z, 0.0, 0.0, 0.0, scale, false, false, false)

    if fx and fx ~= 0 then
        table.insert(fxList, fx)
    elseif Config.Debug then
        print(("[CarFires Debug] Entity particle kon niet starten: asset=%s effect=%s"):format(asset, effect))
    end

    return fx
end

local function StopFireSound(netId)
    local sound = activeFireSounds[netId]
    if not sound then return end

    if sound.soundIds then
        for _, soundId in ipairs(sound.soundIds) do
            StopSound(soundId)
            ReleaseSoundId(soundId)
        end
    elseif sound.soundId then
        StopSound(sound.soundId)
        ReleaseSoundId(sound.soundId)
    end

    activeFireSounds[netId] = nil
end

local function StopActiveFireEffects(netId)
    if activeFires[netId] then
        for _, fx in ipairs(activeFires[netId]) do
            if DoesParticleFxLoopedExist(fx) then
                StopParticleFxLooped(fx, false)
            end
        end

        activeFires[netId] = nil
    end

    StopFireSound(netId)
end

local function DisableBurningVehicleEngine(veh, netId, forceHealth)
    if not DoesEntityExist(veh) then return end

    SetVehicleEngineOn(veh, false, true, true)
    SetVehicleUndriveable(veh, true)
    SetVehicleEngineCanDegrade(veh, false)

    if netId and vehicleStates[netId] then
        vehicleStates[netId].engineDisabled = true
    end

    if forceHealth then
        if EnsureNetworkControl(veh) then
            SetVehicleEngineHealth(veh, Config.FreezeEngineHealth)
            SetVehicleEngineOn(veh, false, true, true)
            SetVehicleUndriveable(veh, true)
        end
    end
end

local function RestoreVehicleDriveState(veh)
    if not DoesEntityExist(veh) then return end

    SetVehicleUndriveable(veh, false)
    SetVehicleEngineCanDegrade(veh, true)
end

local function GetFirstVehicleBone(veh, boneNames, fallbackBone)
    for _, boneName in ipairs(boneNames) do
        local bone = GetEntityBoneIndexByName(veh, boneName)
        if bone ~= -1 then
            return bone
        end
    end

    return fallbackBone
end

local function IsFrontEngineVehicle(veh)
    local engineBone = GetEntityBoneIndexByName(veh, "engine")
    local wheelLF = GetEntityBoneIndexByName(veh, "wheel_lf")
    local wheelLR = GetEntityBoneIndexByName(veh, "wheel_lr")

    if engineBone ~= -1 and wheelLF ~= -1 and wheelLR ~= -1 then
        local engineCoords = GetWorldPositionOfEntityBone(veh, engineBone)
        local frontWheelCoords = GetWorldPositionOfEntityBone(veh, wheelLF)
        local rearWheelCoords = GetWorldPositionOfEntityBone(veh, wheelLR)

        return #(engineCoords - frontWheelCoords) <= #(engineCoords - rearWheelCoords)
    end

    return true
end

local function GetVehicleModelDimensionsSafe(veh)
    local minDim, maxDim = GetModelDimensions(GetEntityModel(veh))

    if minDim and maxDim then
        return minDim, maxDim
    end

    return vector3(-1.0, -2.0, -0.5), vector3(1.0, 2.0, 1.0)
end

local function GetEngineCompartmentOffset(veh)
    local minDim, maxDim = GetVehicleModelDimensionsSafe(veh)
    local isFrontEngine = IsFrontEngineVehicle(veh)
    local inset = Config.PTFX.SmokeHoodLocalInset or 0.65
    local y = isFrontEngine and (maxDim.y - inset) or (minDim.y + inset)
    local z = nil

    local referenceBone = GetEntityBoneIndexByName(veh, "engine")
    if referenceBone == -1 then
        referenceBone = GetEntityBoneIndexByName(veh, isFrontEngine and "bonnet" or "boot")
    end

    if referenceBone ~= -1 then
        local referenceCoords = GetWorldPositionOfEntityBone(veh, referenceBone)
        local referenceOffset = GetOffsetFromEntityGivenWorldCoords(veh, referenceCoords.x, referenceCoords.y, referenceCoords.z)
        z = referenceOffset.z + (Config.PTFX.SmokeHoodLocalZOffset or 0.18)
    else
        z = minDim.z + ((maxDim.z - minDim.z) * 0.45)
    end

    return 0.0, y, z
end

local function GetEngineCompartmentCoords(veh)
    local x, y, z = GetEngineCompartmentOffset(veh)
    return GetOffsetFromEntityInWorldCoords(veh, x, y, z)
end

local function GetFireSoundProfile(phase)
    local soundConfig = Config.FireSound or {}
    local profiles = soundConfig.ByPhase or {}

    return profiles[phase] or profiles[2] or {
        Name = soundConfig.Name or "FBI_HEIST_H5_FIRE",
        Ref = soundConfig.Ref or 0,
        AudioBank = soundConfig.AudioBank,
        Range = soundConfig.Range or 20,
        Stacks = soundConfig.Stacks or 1
    }
end

local function GetFireSoundCoords(veh, index, total)
    local x, y, z = GetEngineCompartmentOffset(veh)
    local spacing = (Config.FireSound and Config.FireSound.StackSpacing) or 0.35

    if total > 1 then
        x = x + ((index - ((total + 1) / 2)) * spacing)
    end

    return GetOffsetFromEntityInWorldCoords(veh, x, y, z)
end

local function StartFireSound(netId, veh, phase)
    local soundConfig = Config.FireSound or {}
    if soundConfig.Enabled == false then return end

    local profile = GetFireSoundProfile(phase)
    local range = profile.Range or 20
    if not range or range <= 0 then return end

    local stacks = math.max(1, math.min(profile.Stacks or 1, 5))
    local profileKey = ("%s|%s|%s|%s"):format(profile.Name or "", profile.Ref or 0, range, stacks)
    local existingSound = activeFireSounds[netId]
    if existingSound and existingSound.profileKey == profileKey and existingSound.entity == veh then
        return
    end

    StopFireSound(netId)

    if profile.AudioBank and profile.AudioBank ~= "" then
        local timeout = 0
        while not RequestScriptAudioBank(profile.AudioBank, false, -1) and timeout < 25 do
            Wait(10)
            timeout = timeout + 1
        end
    end

    local soundIds = {}

    for i = 1, stacks do
        local coords = GetFireSoundCoords(veh, i, stacks)
        local soundId = GetSoundId()

        PlaySoundFromCoord(
            soundId,
            profile.Name or "FBI_HEIST_H5_FIRE",
            coords.x,
            coords.y,
            coords.z,
            profile.Ref or 0,
            false,
            range,
            false
        )

        table.insert(soundIds, soundId)
    end

    activeFireSounds[netId] = {
        soundIds = soundIds,
        entity = veh,
        phase = phase,
        profileKey = profileKey,
        stacks = stacks
    }
end

local function UpdateFireSoundPosition(netId, veh)
    local sound = activeFireSounds[netId]
    if not sound or sound.entity ~= veh then return end
    if not UpdateSoundCoord then return end

    if sound.soundIds then
        for i, soundId in ipairs(sound.soundIds) do
            local coords = GetFireSoundCoords(veh, i, sound.stacks or #sound.soundIds)
            UpdateSoundCoord(soundId, coords.x, coords.y, coords.z)
        end
    elseif sound.soundId then
        local coords = GetEngineCompartmentCoords(veh)
        UpdateSoundCoord(sound.soundId, coords.x, coords.y, coords.z)
    end
end

local function AddEngineSmoke(fxList, veh, mainBone)
    StartFirePtfx(fxList, Config.PTFX.Smoke, veh, mainBone, 0.0, 0.0, 0.12, 1.6)
    StartFirePtfx(fxList, Config.PTFX.Smoke, veh, mainBone, 0.05, 0.05, 0.12, 1.2)
end

local function AddCloseSmoke(fxList, veh, mainBone)
    if not Config.PTFX.SmokeClose or Config.PTFX.SmokeClose == "" then return end

    local closeScale = Config.PTFX.SmokeCloseScale or 1.0
    local closeAsset = Config.PTFX.SmokeCloseAsset or Config.PTFX.Asset

    StartFirePtfx(fxList, Config.PTFX.SmokeClose, veh, mainBone, 0.0, 0.08, 0.1, closeScale, closeAsset)
end

local function AddHoodLocalSmoke(fxList, veh, mainBone)
    if not Config.PTFX.SmokeHoodLocal or Config.PTFX.SmokeHoodLocal == "" then return end

    local localAsset = Config.PTFX.SmokeHoodLocalAsset or Config.PTFX.Asset
    local localScale = Config.PTFX.SmokeHoodLocalScale or 0.45
    local stackZ = Config.PTFX.SmokeHoodLocalStackZ or 0.12
    local x, y, z = GetEngineCompartmentOffset(veh)

    StartFirePtfxOnEntity(fxList, Config.PTFX.SmokeHoodLocal, veh, x, y, z, localScale, localAsset)
    StartFirePtfxOnEntity(fxList, Config.PTFX.SmokeHoodLocal, veh, x, y, z + stackZ, localScale, localAsset)
end

-- ==========================================
-- HOOFD THREAD (Detectie & Blussen)
-- ==========================================
CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local currentVeh = GetVehiclePedIsIn(ped, false)
        local pedCoords = GetEntityCoords(ped)

        -- 1. TRACKING VAN SPELER-VOERTUIGEN
        if currentVeh ~= 0 and DoesEntityExist(currentVeh) and NetworkGetEntityIsNetworked(currentVeh) then
            if not Entity(currentVeh).state.playerDriven then
                Entity(currentVeh).state:set('playerDriven', true, true)
            end

            if GetPedInVehicleSeat(currentVeh, -1) == ped then
                local netId = VehToNet(currentVeh)
                
                if netId ~= 0 then
                    -- Voeg de "extinguished" vlag toe bij initialisatie
                    if not vehicleStates[netId] or vehicleStates[netId].entity ~= currentVeh then
                        vehicleStates[netId] = { phase = 0, isProtected = false, extinguished = false, entity = currentVeh }
                    end

                    local engineHealth = GetVehicleEngineHealth(currentVeh)
                    
                    -- Check of de auto NIET al geblust is
                    if engineHealth <= Config.EngineHealthThreshold and engineHealth > -4000.0 and not vehicleStates[netId].isProtected and not vehicleStates[netId].extinguished then
                        if EnsureNetworkControl(currentVeh) then
                            SetVehicleEngineHealth(currentVeh, Config.Phase1EngineHealth or 650.0)
                            SetVehicleEngineCanDegrade(currentVeh, false)
                            SetVehiclePetrolTankHealth(currentVeh, 1000.0) 
                            SetVehicleExplodesOnHighExplosionDamage(currentVeh, false) 
                            
                            SetEntityProofs(currentVeh, true, true, false, true, true, true, false, true)
                            vehicleStates[netId].isProtected = true
                            
                            TriggerServerEvent('realistic_carfires:server:startFire', netId)
                        end
                    end
                end
            end
        end

        -- 2. HET GEOPTIMALISEERDE BLUS-DETECTIE SYSTEEM
        local gameTime = GetGameTimer()
        if gameTime - lastExtinguishCheck > 500 then
            lastExtinguishCheck = gameTime

            for netId, state in pairs(vehicleStates) do
                if state.phase > 0 and state.phase < 4 then
                    if NetworkDoesNetworkIdExist(netId) then
                        local veh = NetToVeh(netId)
                        if DoesEntityExist(veh) and state.entity == veh then
                            local coords = GetEntityCoords(veh)
                            local distance = #(pedCoords - coords)

                            if distance < 35.0 then
                                local beingExtinguished = false

                                -- METHODE A
                                if HasEntityBeenDamagedByWeapon(veh, `WEAPON_FIREEXTINGUISHER`, 0) then
                                    beingExtinguished = "extinguisher"
                                    ClearEntityLastWeaponDamage(veh)
                                end

                                -- METHODE B
                                if not beingExtinguished then
                                    local currentWeapon = GetSelectedPedWeapon(ped)
                                    if currentWeapon == `WEAPON_FIREEXTINGUISHER` and IsPedShooting(ped) then
                                        local aiming, aimedEntity = GetEntityPlayerIsFreeAimingAt(PlayerId())
                                        if aiming and aimedEntity == veh then
                                            beingExtinguished = "extinguisher"
                                        elseif distance < 6.0 then
                                            local forwardVec = GetEntityForwardVector(ped)
                                            local toVehVec = (coords - pedCoords)
                                            local normalizedToVehVec = toVehVec / distance
                                            local dotProduct = forwardVec.x * normalizedToVehVec.x + forwardVec.y * normalizedToVehVec.y

                                            if dotProduct > 0.70 then
                                                beingExtinguished = "extinguisher"
                                            end
                                        end
                                    end
                                end

                                -- METHODE C
                                if not beingExtinguished then
                                    if currentVeh ~= 0 and GetVehicleClass(currentVeh) == 18 then
                                        if GetPedInVehicleSeat(currentVeh, -1) == ped then
                                            if IsControlPressed(0, 24) or IsDisabledControlPressed(0, 24) or 
                                               IsControlPressed(0, 69) or IsDisabledControlPressed(0, 69) or
                                               IsControlPressed(0, 70) or IsDisabledControlPressed(0, 70) or
                                               IsControlPressed(0, 92) or IsDisabledControlPressed(0, 92) then
                                                
                                                local truckCoords = GetEntityCoords(currentVeh)
                                                local distanceToTruck = #(truckCoords - coords)
                                                
                                                if distanceToTruck < 35.0 then
                                                    local camCoords = GetGameplayCamCoord()
                                                    local camRot = GetGameplayCamRot(2)
                                                    local camForward = RotationToDirection(camRot)
                                                    
                                                    local targetCoords = camCoords + (vector3(camForward.x, camForward.y, camForward.z) * 35.0)
                                                    
                                                    local rayHandle = StartShapeTestCapsule(camCoords.x, camCoords.y, camCoords.z, targetCoords.x, targetCoords.y, targetCoords.z, 2.0, 2, currentVeh, 0)
                                                    local _, hit, hitCoords, _, entityHit = GetShapeTestResult(rayHandle)
                                                    
                                                    if hit and entityHit == veh then
                                                        beingExtinguished = "water_cannon"
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end

                                if beingExtinguished then
                                    TriggerServerEvent('realistic_carfires:server:extinguishProgress', netId, beingExtinguished)
                                end
                            end
                        end
                    end
                end
            end
        end

        -- ==========================================
        -- 3. CONTROLE OP REPARATIES & EXPLOSIEVEN
        -- ==========================================
        for netId, state in pairs(vehicleStates) do
            if NetworkDoesNetworkIdExist(netId) then
                local veh = NetToVeh(netId)
                if DoesEntityExist(veh) and state.entity == veh then
                    if state.engineDisabled and (state.phase > 0 or state.extinguished) and state.phase < 4 then
                        DisableBurningVehicleEngine(veh, netId, false)
                    end
                    
                    -- CHECK A: Is de auto zojuist gerepareerd? Check ook als hij geblust is!
                    if state.phase > 0 or state.extinguished then
                        if GetVehicleEngineHealth(veh) >= 800.0 then
                            if EnsureNetworkControl(veh) then
                                SetEntityProofs(veh, false, false, false, false, false, false, false, false)
                                RestoreVehicleDriveState(veh)
                                StopActiveFireEffects(netId)
                                knownFirePhases[netId] = nil
                                knownEngineDisabled[netId] = nil
                                -- Auto is gefixt, wis compleet uit states zodat hij in de toekomst weer brand kan vatten
                                vehicleStates[netId] = nil 
                                TriggerServerEvent('realistic_carfires:server:stopFire', netId)
                            end
                        end
                    end

                    -- CHECK B: Explosieven afhandelen
                    if state.isProtected then
                        if HasEntityBeenDamagedByWeapon(veh, `WEAPON_EXPLOSION`, 0) or 
                           HasEntityBeenDamagedByWeapon(veh, `WEAPON_STICKYBOMB`, 0) or 
                           HasEntityBeenDamagedByWeapon(veh, `WEAPON_GRENADE`, 0) or 
                           HasEntityBeenDamagedByWeapon(veh, `WEAPON_RPG`, 0) then
                            
                            if EnsureNetworkControl(veh) then
                                SetEntityProofs(veh, false, false, false, false, false, false, false, false)
                                SetVehicleExplodesOnHighExplosionDamage(veh, true)
                                
                                vehicleStates[netId].isProtected = false
                                vehicleStates[netId].phase = 0
                                
                                TriggerServerEvent('realistic_carfires:server:forceExplosion', netId)
                            end
                        end
                    end
                else
                    vehicleStates[netId] = nil
                end
            else
                vehicleStates[netId] = nil
            end
        end

        Wait(250)
    end
end)

-- ==========================================
-- VISUALS THREAD (Server Updates Ontvangen)
-- ==========================================
RegisterNetEvent('realistic_carfires:client:updateVehicleFire')
AddEventHandler('realistic_carfires:client:updateVehicleFire', function(netId, phase, allowExplosion, engineBroken)
    if netId == 0 then return end 
    local shouldExplode = allowExplosion ~= false
    local shouldDisableEngine = engineBroken == true or phase >= 2

    if phase > 0 then
        knownFirePhases[netId] = phase
        knownEngineDisabled[netId] = shouldDisableEngine
    else
        local wasEngineDisabled = engineBroken == true or knownEngineDisabled[netId] == true or (vehicleStates[netId] and vehicleStates[netId].engineDisabled)
        knownFirePhases[netId] = nil
        knownEngineDisabled[netId] = nil
        StopActiveFireEffects(netId)
        
        -- FIX HIER: Wis het voertuig NIET, maar markeer als succesvol geblust.
        if vehicleStates[netId] then
            vehicleStates[netId].phase = 0
            vehicleStates[netId].isProtected = false
            vehicleStates[netId].extinguished = true
        end

        if NetworkDoesNetworkIdExist(netId) then
            local veh = NetToVeh(netId)
            if DoesEntityExist(veh) then
                if EnsureNetworkControl(veh) then
                    SetEntityProofs(veh, false, false, false, false, false, false, false, false)
                    if not wasEngineDisabled or GetVehicleEngineHealth(veh) >= 800.0 then
                        RestoreVehicleDriveState(veh)
                    end
                end
            end
        end
        return
    end

    if not NetworkDoesNetworkIdExist(netId) then return end
    local veh = NetToVeh(netId)
    if not DoesEntityExist(veh) then return end

    if not vehicleStates[netId] then
        vehicleStates[netId] = { phase = 0, isProtected = false, extinguished = false, entity = veh }
    end
    vehicleStates[netId].phase = phase
    vehicleStates[netId].entity = veh
    vehicleStates[netId].extinguished = false

    if shouldDisableEngine then
        vehicleStates[netId].engineDisabled = true
    end

    StopActiveFireEffects(netId)

    if shouldDisableEngine and phase < 4 then
        DisableBurningVehicleEngine(veh, netId, true)
    end
    
    activeFires[netId] = {}
    local mainBone = GetEngineBone(veh)
    RequestPtfxAssetSynced(Config.PTFX.Asset)

    -- FASE 1: Witte dichtbij-rook zonder donkere brandrook
    if phase == 1 then
        AddCloseSmoke(activeFires[netId], veh, mainBone)
        AddHoodLocalSmoke(activeFires[netId], veh, mainBone)

    -- FASE 2: Motorvuur + De Rook
    elseif phase == 2 then
        AddEngineSmoke(activeFires[netId], veh, mainBone)

        UseParticleFxAssetNextCall(Config.PTFX.Asset)
        local fire = StartParticleFxLoopedOnEntityBone(Config.PTFX.FireSmall, veh, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, mainBone, 2.2, false, false, false)
        table.insert(activeFires[netId], fire)

    -- FASE 3: Motorvuur + Wielvuur + De Rook
    elseif phase == 3 then
        local isFrontEngine = true
        local wheelLF = GetEntityBoneIndexByName(veh, "wheel_lf")
        local wheelLR = GetEntityBoneIndexByName(veh, "wheel_lr")
        local engineBone = GetEntityBoneIndexByName(veh, "engine")

        if engineBone ~= -1 and wheelLF ~= -1 and wheelLR ~= -1 then
            local engineCoords = GetWorldPositionOfEntityBone(veh, engineBone)
            local frontWheelCoords = GetWorldPositionOfEntityBone(veh, wheelLF)
            local rearWheelCoords = GetWorldPositionOfEntityBone(veh, wheelLR)

            if #(engineCoords - rearWheelCoords) < #(engineCoords - frontWheelCoords) then
                isFrontEngine = false
            end
        end

        local boneNameLeft = isFrontEngine and "wheel_lf" or "wheel_lr"
        local boneNameRight = isFrontEngine and "wheel_rf" or "wheel_rr"

        local leftWheelBone = GetEntityBoneIndexByName(veh, boneNameLeft)
        local rightWheelBone = GetEntityBoneIndexByName(veh, boneNameRight)

        local leftBone = (leftWheelBone ~= -1) and leftWheelBone or mainBone
        local rightBone = (rightWheelBone ~= -1) and rightWheelBone or mainBone

        AddEngineSmoke(activeFires[netId], veh, mainBone)

        UseParticleFxAssetNextCall(Config.PTFX.Asset)
        local fireEngine = StartParticleFxLoopedOnEntityBone(Config.PTFX.FireSmall, veh, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, mainBone, 2.2, false, false, false)
        table.insert(activeFires[netId], fireEngine)

        UseParticleFxAssetNextCall(Config.PTFX.Asset)
        local fireLeft = StartParticleFxLoopedOnEntityBone(Config.PTFX.FireSmall, veh, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, leftBone, 2.6, false, false, false)
        table.insert(activeFires[netId], fireLeft)

        UseParticleFxAssetNextCall(Config.PTFX.Asset)
        local fireRight = StartParticleFxLoopedOnEntityBone(Config.PTFX.FireSmall, veh, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, rightBone, 2.6, false, false, false)
        table.insert(activeFires[netId], fireRight)

    -- FASE 4: MASSIVE STACKING
    elseif phase == 4 then
        if EnsureNetworkControl(veh) then
            SetEntityProofs(veh, false, false, false, false, false, false, false, false)
            SetVehicleExplodesOnHighExplosionDamage(veh, true)
            SetVehicleEngineOn(veh, false, true, true)
            SetVehicleUndriveable(veh, true)
            SetVehicleTyresCanBurst(veh, true)
            RemoveVehicleMod(veh, 16) 
            
            SetVehiclePetrolTankHealth(veh, -1000.0)
            SetVehicleEngineHealth(veh, -4000.0)
            
            for i = 0, 5 do
                SetVehicleTyreBurst(veh, i, true, 1000.0)
            end
        end

        if shouldExplode and NetworkHasControlOfEntity(veh) then
            NetworkExplodeVehicle(veh, true, false, 0)
            local coords = GetEntityCoords(veh)
            AddExplosion(coords.x, coords.y, coords.z, 2, 5.0, true, false, 1.0)
        end
        
        local isFrontEngine = true
        local wheelLF = GetEntityBoneIndexByName(veh, "wheel_lf")
        local wheelLR = GetEntityBoneIndexByName(veh, "wheel_lr")
        local engineBone = GetEntityBoneIndexByName(veh, "engine")
        if engineBone ~= -1 and wheelLF ~= -1 and wheelLR ~= -1 then
            local engineCoords = GetWorldPositionOfEntityBone(veh, engineBone)
            if #(engineCoords - GetWorldPositionOfEntityBone(veh, wheelLR)) < #(engineCoords - GetWorldPositionOfEntityBone(veh, wheelLF)) then
                isFrontEngine = false
            end
        end
        local boneNameLeft = isFrontEngine and "wheel_lf" or "wheel_lr"
        local boneNameRight = isFrontEngine and "wheel_rf" or "wheel_rr"
        local leftBone = (GetEntityBoneIndexByName(veh, boneNameLeft) ~= -1) and GetEntityBoneIndexByName(veh, boneNameLeft) or mainBone
        local rightBone = (GetEntityBoneIndexByName(veh, boneNameRight) ~= -1) and GetEntityBoneIndexByName(veh, boneNameRight) or mainBone

        AddEngineSmoke(activeFires[netId], veh, mainBone)

        UseParticleFxAssetNextCall(Config.PTFX.Asset)
        local fireEngine = StartParticleFxLoopedOnEntityBone(Config.PTFX.FireSmall, veh, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, mainBone, 2.2, false, false, false)
        table.insert(activeFires[netId], fireEngine)

        UseParticleFxAssetNextCall(Config.PTFX.Asset)
        local fireLeft = StartParticleFxLoopedOnEntityBone(Config.PTFX.FireSmall, veh, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, leftBone, 2.6, false, false, false)
        table.insert(activeFires[netId], fireLeft)

        UseParticleFxAssetNextCall(Config.PTFX.Asset)
        local fireRight = StartParticleFxLoopedOnEntityBone(Config.PTFX.FireSmall, veh, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, rightBone, 2.6, false, false, false)
        table.insert(activeFires[netId], fireRight)

        UseParticleFxAssetNextCall(Config.PTFX.Asset)
        local masterFire = StartParticleFxLoopedOnEntityBone(Config.PTFX.FireSmall, veh, 0.0, 0.0, 0.2, 0.0, 0.0, 0.0, mainBone, 4.5, false, false, false)
        table.insert(activeFires[netId], masterFire)
    end

    StartFireSound(netId, veh, phase)
end)

CreateThread(function()
    while true do
        Wait(1000)

        for netId, phase in pairs(knownFirePhases) do
            if phase > 0 and NetworkDoesNetworkIdExist(netId) then
                local veh = NetToVeh(netId)

                if DoesEntityExist(veh) then
                    local state = vehicleStates[netId]
                    local engineDisabled = knownEngineDisabled[netId] == true
                    local needsVisualRefresh = not activeFires[netId] or
                        not state or
                        state.entity ~= veh or
                        state.phase ~= phase or
                        (state.engineDisabled == true) ~= engineDisabled

                    if needsVisualRefresh then
                        TriggerEvent('realistic_carfires:client:updateVehicleFire', netId, phase, false, engineDisabled)
                    elseif engineDisabled and phase > 0 and phase < 4 then
                        DisableBurningVehicleEngine(veh, netId, false)
                    end

                    UpdateFireSoundPosition(netId, veh)
                end
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(5000)
        for netId, state in pairs(vehicleStates) do
            local cleanUp = false
            if not NetworkDoesNetworkIdExist(netId) then
                cleanUp = true
            else
                local veh = NetToVeh(netId)
                if not DoesEntityExist(veh) or state.entity ~= veh then
                    cleanUp = true
                end
            end

            if cleanUp then
                StopActiveFireEffects(netId)
                vehicleStates[netId] = nil
            end
        end
    end
end)

CreateThread(function()
    Wait(5000)
    TriggerServerEvent('realistic_carfires:server:requestActiveFires')
end)

AddEventHandler('gameEventTriggered', function(name, args)
    if name == "CEventNetworkEntityDamage" then
        local victim = args[1]

        if IsEntityAVehicle(victim) then
            if Entity(victim).state.playerDriven then
                if NetworkHasControlOfEntity(victim) then
                    local engineHealth = GetVehicleEngineHealth(victim)
                    
                    if engineHealth <= Config.EngineHealthThreshold and engineHealth > -4000.0 then
                        local netId = VehToNet(victim)
                        
                        if netId ~= 0 then
                            -- Check op extinguished vlag
                            if not vehicleStates[netId] or vehicleStates[netId].entity ~= victim then
                                vehicleStates[netId] = { phase = 0, isProtected = false, extinguished = false, entity = victim }
                            end
                            
                            if not vehicleStates[netId].isProtected and not vehicleStates[netId].extinguished then
                                vehicleStates[netId].isProtected = true
                                
                                SetVehicleEngineHealth(victim, Config.Phase1EngineHealth or 650.0)
                                SetVehicleEngineCanDegrade(victim, false)
                                SetVehiclePetrolTankHealth(victim, 1000.0) 
                                SetVehicleExplodesOnHighExplosionDamage(victim, false) 
                                
                                SetEntityProofs(victim, true, true, false, true, true, true, false, true)
                                
                                TriggerServerEvent('realistic_carfires:server:startFire', netId)
                            end
                        end
                    end
                end
            end
        end
    end
end)
