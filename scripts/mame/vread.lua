-- Count main-CPU reads and writes of address ranges, for checking whether a
-- game reads its tile VRAM back.
--   VR_OUT     output file
--   VR_RANGES  "name:hexlo:hexhi,..."
--   VR_FRAMES  frames to run
local OUT    = os.getenv("VR_OUT")
local RANGES = os.getenv("VR_RANGES") or ""
local FRAMES = tonumber(os.getenv("VR_FRAMES") or "2400")
local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]
local rd, wr, pcs = {}, {}, {}
_G.__vr = {}
for spec in string.gmatch(RANGES, "([^,]+)") do
    local name, lo, hi = spec:match("([^:]+):([^:]+):([^:]+)")
    lo, hi = tonumber(lo, 16), tonumber(hi, 16)
    rd[name], wr[name], pcs[name] = 0, 0, {}
    local cpu = mach.devices[":maincpu"]
    _G.__vr[#_G.__vr + 1] = prog:install_read_tap(lo, hi, "vr_r_" .. name, function(offset, data, mask)
        rd[name] = rd[name] + 1
        local pc = cpu.state["PC"].value
        pcs[name][pc] = (pcs[name][pc] or 0) + 1
        return data
    end)
    _G.__vr[#_G.__vr + 1] = prog:install_write_tap(lo, hi, "vr_w_" .. name, function(offset, data, mask)
        wr[name] = wr[name] + 1
        return data
    end)
end
local n = 0
emu.register_frame_done(function()
    n = n + 1
    if n == FRAMES then
        local f = assert(io.open(OUT, "w"))
        for name, c in pairs(rd) do
            f:write(string.format("%s reads %d writes %d\n", name, c, wr[name]))
            for pc, k in pairs(pcs[name]) do f:write(string.format("  pc %06X %d\n", pc, k)) end
        end
        f:close()
        mach:exit()
    end
end)
