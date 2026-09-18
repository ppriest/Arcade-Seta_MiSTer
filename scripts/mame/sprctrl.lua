-- What each set writes to the X1-001's four control bytes, for
-- scripts/sprctrl_scan.py.
--
--   SC_OUT     output file
--   SC_BASE    hex address of the control bytes (8 bytes, one per word's low byte)
--   SC_SKIP    frames to run before counting (boot)
--   SC_FRAMES  frames to count
--   SC_COIN    frame to insert a coin and then press Start (0 = attract only)
--
-- Reports: how often each value is written to each control byte, how many
-- frames the copy is disabled (byte 1 bit 5 set), and every write that flips
-- byte 1 bit 6 -- the drawn half -- with the copy off, by scanline.

local OUT    = os.getenv("SC_OUT")
local BASE   = tonumber(os.getenv("SC_BASE"), 16)
local SKIP   = tonumber(os.getenv("SC_SKIP") or "600")
local FRAMES = tonumber(os.getenv("SC_FRAMES") or "1200")
local COIN   = tonumber(os.getenv("SC_COIN") or "0")

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local scr  = mach.screens[":screen"]

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

local counting = false
local frames = 0
local vals = {}          -- vals[idx][data] = count
local flips = {}         -- flips[line] = count
local nflip, nwrite = 0, 0
local bit5_frames = 0
local ctrl = {}          -- last value written to each byte
for i = 0, 3 do vals[i] = {} end

_G.__sc_tap = prog:install_write_tap(BASE, BASE + 7, "sprctrl", function(offset, data, mask)
    local idx = math.floor((offset - BASE) / 2)
    local d = data & 0xff
    if mask & 0xff == 0 then d = (data >> 8) & 0xff end
    if counting then
        nwrite = nwrite + 1
        vals[idx][d] = (vals[idx][d] or 0) + 1
        if idx == 1 and (d & 0x20) ~= 0 and ctrl[1] ~= nil
           and ((d ~ ctrl[1]) & 0x40) ~= 0 then
            local l = cur_line()
            flips[l] = (flips[l] or 0) + 1
            nflip = nflip + 1
        end
    end
    ctrl[idx] = d
    return data
end)

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
local function done()
    local f = io.open(OUT, "w")
    f:write(string.format("vtotal %d\nframes %d\nwrites %d\nflips %d\nbit5frames %d\n",
                          vtotal, frames, nwrite, nflip, bit5_frames))
    for i = 0, 3 do
        local keys = {}
        for k in pairs(vals[i]) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            f:write(string.format("val %d %02x %d\n", i, k, vals[i][k]))
        end
    end
    local keys = {}
    for k in pairs(flips) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do f:write(string.format("flip %d %d\n", k, flips[k])) end
    f:close()
    mach:exit()
end

emu.register_frame_done(function()
    n = n + 1
    if n == SKIP then counting = true end
    if counting then
        frames = frames + 1
        if ctrl[1] ~= nil and (ctrl[1] & 0x20) ~= 0 then bit5_frames = bit5_frames + 1 end
    end
    if COIN > 0 then
        if f_coin then f_coin:set_value(n >= COIN and n < COIN + 6 and 1 or 0) end
        if f_start then f_start:set_value(n >= COIN + 12 and n < COIN + 18 and 1 or 0) end
        if n > COIN + 24 then
            if f_right then f_right:set_value(1) end
            if f_b1 then f_b1:set_value((n % 8 < 4) and 1 or 0) end
        end
    end
    if n >= SKIP + FRAMES then done() end
end)
