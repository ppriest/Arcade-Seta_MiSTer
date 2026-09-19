-- Per write to [WP_LO, WP_HI]: frame, scanline, PC, offset. Frames WP_FROM..WP_TO.
-- Also logs each main CPU interrupt acknowledge (frame, line, level).

local OUT  = os.getenv("WP_OUT")
local LO   = tonumber(os.getenv("WP_LO"), 16)
local HI   = tonumber(os.getenv("WP_HI"), 16)
local FROM = tonumber(os.getenv("WP_FROM") or "640")
local TO   = tonumber(os.getenv("WP_TO") or "644")

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local scr  = mach.screens[":screen"]
local f = io.open(OUT, "w")

local frame_period = 1.0 / scr.refresh
local line_period
for _ = 1, 64 do
    local d = scr:time_until_pos(1) - scr:time_until_pos(0)
    if d > 0 and (line_period == nil or d < line_period) then line_period = d end
end
local vtotal = math.floor(frame_period / line_period + 0.5)
local function cur_line()
    return math.floor((frame_period - scr:time_until_pos(0)) / line_period + 0.5) % vtotal
end

local n = 0
local last_pc, run_start, run_n = nil, nil, 0
local function flush()
    if last_pc then
        f:write(string.format("f%d l%d pc%06x first%06x n%d\n", n, run_start.l, last_pc, run_start.o, run_n))
    end
    last_pc = nil; run_n = 0
end
_G.__wp_tap = prog:install_write_tap(LO, HI, "wp", function(off, data, mask)
    if n < FROM or n > TO then return end
    local pc = cpu.state["CURPC"].value
    if pc ~= last_pc then
        flush()
        last_pc = pc; run_start = { l = cur_line(), o = off }
    end
    run_n = run_n + 1
end)

emu.register_frame_done(function()
    n = n + 1
    if n >= FROM and n <= TO + 1 then flush(); f:write(string.format("--- frame_done %d at line %d\n", n, cur_line())) end
    if n == TO + 1 then f:close(); mach:exit() end
end)
