-- Print every I/O port field MAME built for the running set, then exit.
-- Used by scripts/check_inputs.py.
local done = false
emu.register_frame_done(function()
    if done then return end
    done = true
    local out = io.open(os.getenv("PORTS_FILE"), "w")
    local io_ = manager.machine.ioport
    for tag, port in pairs(io_.ports) do
        -- port.fields is keyed by name, so fields sharing one (atehate's
        -- two conditional panels) collapse; walk the bits instead
        local seen = {}
        local list = {}
        for _, f in pairs(port.fields) do list[#list + 1] = f; seen[f] = true end
        for b = 0, 31 do
            local ok, f = pcall(function() return port:field(1 << b) end)
            if ok and f and not seen[f] then list[#list + 1] = f; seen[f] = true end
        end
        for _, f in ipairs(list) do
            local tok = ""
            local ok, t = pcall(function() return io_:input_type_to_token(f.type, f.player) end)
            if ok and t then tok = t end
            out:write(string.format("%s\t%d\t%d\t%s\t%s\t%s\n", tag, f.mask, f.defvalue,
                tok, f.name or "", f.is_analog and "analog" or ""))
        end
    end
    out:close()
    manager.machine:exit()
end)
