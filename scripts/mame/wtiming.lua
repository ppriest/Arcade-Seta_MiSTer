-- Count a set's video RAM writes by scanline, for scripts/write_timing.py.
--
--   WT_OUT     output file
--   WT_TAPS    "name:hexlo:hexhi,..." regions to count
--   WT_SKIP    frames to run before counting (boot)
--   WT_FRAMES  frames to count
--   WT_COIN    frame to insert a coin and then press Start (0 = attract only);
--              from Start, P1 Right is held and Button 1 pulsed, so play goes on
--
-- The scanline comes from time_until_pos, as in capture.lua (0.28x's screen
-- binding has no vpos). Writes are binned by line; per frame the last write
-- line of each region is binned too.

local OUT    = os.getenv("WT_OUT")
local TAPS   = os.getenv("WT_TAPS") or ""
local SKIP   = tonumber(os.getenv("WT_SKIP") or "600")
local FRAMES = tonumber(os.getenv("WT_FRAMES") or "1200")
local COIN   = tonumber(os.getenv("WT_COIN") or "0")

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local scr  = mach.screens[":screen"]

local function split(s, sep)
    local out = {}
    for tok in string.gmatch(s, "([^" .. sep .. "]+)") do out[#out + 1] = tok end
    return out
end

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

-- vblank start line: frame_done runs when MAME finishes a frame, at vblank
-- start, so the line in force there (most common over the skipped frames) is
-- taken as vblank start. (time_until_vblank_start from an autoboot script
-- crashed MAME 0.285.)
local vbstart = -1
local vb_votes = {}

local names, hist, lastl = {}, {}, {}
local counting = false
local frame_last = {}
_G.__wt_taps = {}
for _, spec in ipairs(split(TAPS, ",")) do
    local f = split(spec, ":")
    local name, lo, hi = f[1], tonumber(f[2], 16), tonumber(f[3], 16)
    names[#names + 1] = name
    hist[name] = {}
    lastl[name] = {}
    local tap = prog:install_write_tap(lo, hi, "wt_" .. name, function(offset, data, mask)
        if counting then
            local l = cur_line()
            hist[name][l] = (hist[name][l] or 0) + 1
            frame_last[name] = l
        end
        return data
    end)
    _G.__wt_taps[#_G.__wt_taps + 1] = tap
end

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end
local f_coin, f_start = field("Coin 1"), field("1 Player Start")
local f_right, f_b1 = field("P1 Right"), field("P1 Button 1")

local n = 0
emu.register_frame_done(function()
    n = n + 1
    if COIN > 0 and f_coin and f_start then
        f_coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
        f_start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
        if n >= COIN + 96 then
            if f_right then f_right:set_value(1) end
            if f_b1 then f_b1:set_value((n % 20) < 4 and 1 or 0) end
        end
    end
    if n > 10 and n <= SKIP then
        local l = cur_line()
        vb_votes[l] = (vb_votes[l] or 0) + 1
    end
    if n == SKIP then
        counting = true
        local best = 0
        for l, c in pairs(vb_votes) do
            if c > best then best = c; vbstart = l end
        end
    end
    if counting then
        -- a frame's last write, binned at the end of the frame MAME rendered
        for name, l in pairs(frame_last) do
            lastl[name][l] = (lastl[name][l] or 0) + 1
        end
        frame_last = {}
    end
    if n == SKIP + FRAMES then
        if os.getenv("WT_SNAP") == "1" then mach.video:snapshot() end
        local f = assert(io.open(OUT, "w"))
        f:write(string.format("vtotal %d\nvbstart %d\nframes %d\n", vtotal, vbstart, FRAMES))
        for _, name in ipairs(names) do
            local parts = {}
            for l = 0, vtotal - 1 do parts[#parts + 1] = tostring(hist[name][l] or 0) end
            f:write("hist " .. name .. " " .. table.concat(parts, ",") .. "\n")
            parts = {}
            for l = 0, vtotal - 1 do parts[#parts + 1] = tostring(lastl[name][l] or 0) end
            f:write("last " .. name .. " " .. table.concat(parts, ",") .. "\n")
        end
        f:close()
        mach:exit()
    end
end)
