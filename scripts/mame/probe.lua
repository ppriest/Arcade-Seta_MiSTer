-- Probe the Lua API actually present in this MAME build, so the capture
-- scripts can be written against what exists rather than what the current
-- online docs describe (this build is 0.286; docs.mamedev.org serves 0.289).
local function has(t, k)
    local ok, v = pcall(function() return t[k] end)
    return ok and v ~= nil
end

local out = {}
local function say(s) out[#out+1] = s; print("PROBE " .. s) end

say("emu.app_name=" .. tostring(emu.app_name) .. " ver=" .. tostring(emu.app_version))

for _, k in ipairs{"add_machine_frame_notifier", "add_machine_stop_notifier",
                   "add_machine_reset_notifier", "register_frame", "register_stop",
                   "wait", "print_info"} do
    say("emu." .. k .. " = " .. type(emu[k]))
end

local m = manager.machine
for _, k in ipairs{"exit", "hard_reset", "video", "screens", "devices", "system", "paused"} do
    say("machine." .. k .. " = " .. type(m[k]))
end

for tag, scr in pairs(m.screens) do
    say("screen " .. tag .. " w=" .. tostring(scr.width) .. " h=" .. tostring(scr.height))
    for _, k in ipairs{"frame_number", "vpos", "hpos", "vblank", "refresh", "container"} do
        local ok, v = pcall(function() return scr[k] end)
        say("  screen." .. k .. " -> " .. (ok and type(v) or "ERR"))
    end
end

local cpu = m.devices[":maincpu"]
say("maincpu = " .. tostring(cpu ~= nil))
if cpu then
    for name, sp in pairs(cpu.spaces) do say("  space: " .. name) end
    for _, k in ipairs{"state", "spaces"} do
        say("  cpu." .. k .. " = " .. type(cpu[k]))
    end
    local ok, pc = pcall(function() return cpu.state["PC"].value end)
    say("  PC via state = " .. (ok and string.format("%08X", pc) or "ERR"))
end

local f = io.open((os.getenv("SETA_OUT") or ".") .. "/probe.txt", "w")
f:write(table.concat(out, "\n"))
f:close()
print("PROBE done")
manager.machine:exit()
