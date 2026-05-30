local trackedFires = {}

if not Config then Config = {} end

local function DebugLog(message)
    if Config.Debug then
        print("[CarFires Debug] " .. message)
    end
end

local function IsPlayerNearVehicle(source, vehicleEntity, maxDistance)
    if not DoesEntityExist(vehicleEntity) then return false end
    local playerPed = GetPlayerPed(source)
    if not DoesEntityExist(playerPed) then return false end
    local distance = #(GetEntityCoords(playerPed) - GetEntityCoords(vehicleEntity))
    return distance <= (maxDistance or 50.0)
end

local function GetPhaseFromHealth(hp)
    if hp <= 0 then return 0 end
    if hp <= Config.FireHealth.Phase1 then return 1 end
    if hp <= Config.FireHealth.Phase2 then return 2 end
    if hp <= Config.FireHealth.Phase3 then return 3 end
    return 4
end

RegisterNetEvent('realistic_carfires:server:startFire')
AddEventHandler('realistic_carfires:server:startFire', function(netId)
    local src = source
    if trackedFires[netId] then return end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not DoesEntityExist(entity) then return end
    if not IsPlayerNearVehicle(src, entity, 15.0) then return end

    print("[CarFires Server] Brand GEREGISTREERD voor NetID: " .. netId .. ". Starten met Fase 1.")

    trackedFires[netId] = {
        phase = 1,
        health = 10,
        burnoutTimer = 0,
        engineBroken = false,
        suppressedTimer = 0 -- NIEUW: Timer om te onthouden hoelang de brand nog bevroren is
    }

    TriggerClientEvent('realistic_carfires:client:updateVehicleFire', -1, netId, 1, true, false)
end)

RegisterNetEvent('realistic_carfires:server:requestActiveFires')
AddEventHandler('realistic_carfires:server:requestActiveFires', function()
    local src = source
    for netId, data in pairs(trackedFires) do
        TriggerClientEvent('realistic_carfires:client:updateVehicleFire', src, netId, data.phase, false, data.engineBroken == true)
    end
end)

RegisterNetEvent('realistic_carfires:server:extinguishProgress')
AddEventHandler('realistic_carfires:server:extinguishProgress', function(netId, weaponType)
    local src = source
    if not trackedFires[netId] then return end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not DoesEntityExist(entity) then return end
    if not IsPlayerNearVehicle(src, entity, 45.0) then return end

    local data = trackedFires[netId]
    if data.phase == 4 then return end 

    local coolingPower = Config.CoolingPower.Extinguisher

    -- Bepaal wat het wapen doet
    if weaponType == "water_cannon" then
        coolingPower = Config.CoolingPower.WaterCannon
    else
        -- ALS HET DE HANDBLUSSER IS: Bevries de brand voor X seconden!
        data.suppressedTimer = Config.FireHealth.SuppressionTime or 3
    end

    local oldHealth = data.health
    data.health = data.health - coolingPower
    if data.health < 0 then data.health = 0 end

    local oldPhase = data.phase
    local newPhase = GetPhaseFromHealth(data.health)

    if newPhase ~= oldPhase then
        if oldPhase >= 2 or newPhase >= 2 then
            data.engineBroken = true
        end

        data.phase = newPhase
        print(string.format("[CarFires Server] Brand NetID %s zakt naar FASE %s door blussen!", netId, newPhase))
        TriggerClientEvent('realistic_carfires:client:updateVehicleFire', -1, netId, newPhase, true, data.engineBroken == true)

        if newPhase == 0 then
            print("[CarFires Server] Voertuig NetID " .. netId .. " is SUCCESVOL GEBLUST door spelers!")
            trackedFires[netId] = nil
        end
    end
end)

-- De Hoofd-Thread
CreateThread(function()
    while true do
        Wait(1000)

        for netId, data in pairs(trackedFires) do
            local entity = NetworkGetEntityFromNetworkId(netId)
            
            if not DoesEntityExist(entity) then
                trackedFires[netId] = nil
            else
                local currentPhase = data.phase

                if currentPhase > 0 and currentPhase < 4 then
                    local currentGrowth = Config.FireHealth.GrowthRate

                    -- NIEUW: Onderdrukkings-systeem check
                    if data.suppressedTimer > 0 then
                        data.suppressedTimer = data.suppressedTimer - 1
                        currentGrowth = 0 -- Het vuur groeit 0 HP zolang het onderdrukt is door de blusser!
                        
                        if data.suppressedTimer == 0 and Config.Debug then
                            print("[CarFires] Onderdrukking uitgewerkt voor NetID " .. netId .. ", vuur groeit weer.")
                        end
                    end

                    data.health = data.health + currentGrowth
                    
                    local newPhase = GetPhaseFromHealth(data.health)

                    if newPhase ~= currentPhase then
                        if newPhase >= 2 then
                            data.engineBroken = true
                        end

                        data.phase = newPhase
                        print(string.format("[CarFires Server] Brand NetID %s groeit naar FASE %s (HP: %s)", netId, newPhase, data.health))
                        TriggerClientEvent('realistic_carfires:client:updateVehicleFire', -1, netId, newPhase, true, data.engineBroken == true)
                    end

                elseif currentPhase == 4 then
                    data.burnoutTimer = data.burnoutTimer + 1
                    if data.burnoutTimer >= Config.FireHealth.BurnoutTime then
                        print("[CarFires Server] Wrak NetID " .. netId .. " is volledig uitgebrand.")
                        TriggerClientEvent('realistic_carfires:client:updateVehicleFire', -1, netId, 0, true, data.engineBroken == true)
                        trackedFires[netId] = nil
                    end
                end
            end
        end
    end
end)

RegisterNetEvent('realistic_carfires:server:forceExplosion')
AddEventHandler('realistic_carfires:server:forceExplosion', function(netId)
    local src = source
    if not trackedFires[netId] then return end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not DoesEntityExist(entity) then return end
    if not IsPlayerNearVehicle(src, entity, 50.0) then return end

    trackedFires[netId].phase = 4
    trackedFires[netId].health = Config.FireHealth.Phase4 + 1
    trackedFires[netId].burnoutTimer = 0
    trackedFires[netId].engineBroken = true

    TriggerClientEvent('realistic_carfires:client:updateVehicleFire', -1, netId, 4, true, true)
    print("[CarFires Server] Brand GEFORCEERD naar FASE 4 wegens explosief op NetID: " .. netId)
end)

RegisterNetEvent('realistic_carfires:server:stopFire')
AddEventHandler('realistic_carfires:server:stopFire', function(netId)
    if not trackedFires[netId] then return end
    
    trackedFires[netId] = nil
    TriggerClientEvent('realistic_carfires:client:updateVehicleFire', -1, netId, 0, true, false)
    
    if Config.Debug then
        print("[CarFires Server] Brand GESTOPT door voertuig reparatie op NetID: " .. netId)
    end
end)

RegisterCommand('stopbrand', function(source, args, rawCommand)
    local netId = tonumber(args[1])
    if netId and trackedFires[netId] then
        trackedFires[netId] = nil
        TriggerClientEvent('realistic_carfires:client:updateVehicleFire', -1, netId, 0, true, false)
        print("[CarFires Server] Brand handmatig gestopt voor NetID: " .. netId)
    end
end, true)
