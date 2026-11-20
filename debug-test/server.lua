RegisterCommand('checkinvgroups', function(source, args)
    local id = tonumber(args[1])
    local inv = exports.ox_inventory:Inventory(id)

    if not inv then
        print('no inventory found for', id)
        return
    end

    print('cached inv.player.groups:')
    print(json.encode(inv.player.groups))
end, true)