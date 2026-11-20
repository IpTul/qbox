-- Daftar model dan batas kecepatannya (km/h)
local speedLimits = {
    [`18performante`] = 240.0,
    [`rrr32`]         = 200.0,
    [`icrpcivic`]     = 200.0,
    -- tambah model lain di bawah ini:
    -- [`namamodel`]  = 180.0,
}

CreateThread(function()
    while true do
        Wait(500)
        local ped = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(ped, false)

        if vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == ped then
            local limit = speedLimits[GetEntityModel(vehicle)]

            if limit then
                SetVehicleMaxSpeed(vehicle, limit / 3.6)
            end
        end
    end
end)

RegisterCommand('cekhandling', function()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if veh == 0 then return print('Masuk mobil dulu') end
    print('Massa:', GetVehicleHandlingFloat(veh, 'CHandlingData', 'fMass'))
    print('DriveForce:', GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveForce'))
    print('MaxFlatVel:', GetVehicleHandlingFloat(veh, 'CHandlingData', 'fInitialDriveMaxFlatVel'))
    print('ClutchChangeRateScaleUpShift:', GetVehicleHandlingFloat(veh, 'CHandlingData', 'fClutchChangeRateScaleUpShift'))
    print('ClutchChangeRateScaleDownShift:', GetVehicleHandlingFloat(veh, 'CHandlingData', 'fClutchChangeRateScaleDownShift'))
end)