-- Find where zombraid keeps the aim position it draws its own crosshair at.
--
-- Coins up, starts a game, then holds the P1 gun at a sequence of positions
-- and at the end of each hold dumps work RAM, sprite code RAM and sprite
-- Y-low RAM and takes a snapshot. scripts/gun_find.py runs this and diffs
-- the dumps: a word that tracks GUNX1 alone, GUNY1 alone, or the two in a
-- fixed transform is the game's own computed position, calibration and all.
--
-- Env: SETA_OUT (directory), SETA_TAG (file prefix), SETA_GUNSEQ
-- ("x,y,frame;x,y,frame;..." -- hold GUN{X,Y}1 at x,y and dump at frame),
-- SETA_COIN_FRAME, SETA_START_FRAME.

local OUT   = os.getenv("SETA_OUT") or "."
local TAG   = os.getenv("SETA_TAG") or "gun"
local SEQ   = os.getenv("SETA_GUNSEQ") or ""
local COINF = tonumber(os.getenv("SETA_COIN_FRAME") or "200")
local STRTF = tonumber(os.getenv("SETA_START_FRAME") or "300")

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local scr  = mach.screens[":screen"]

local function split(s, sep)
    local out = {}
    for tok in string.gmatch(s, "([^" .. sep .. "]+)") do out[#out + 1] = tok end
    return out
end

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end

local P2 = (os.getenv("SETA_GUN_P2") or "0") == "1"
local gunx = field(P2 and "Lightgun X 2" or "Lightgun X")
local guny = field(P2 and "Lightgun Y 2" or "Lightgun Y")
local coin, start = field("Coin 1"), field(P2 and "2 Players Start" or "1 Player Start")
if not (gunx and guny and coin and start) then
    local names = {}
    for _, port in pairs(mach.ioport.ports) do
        for n, _ in pairs(port.fields) do names[#names + 1] = n end
    end
    table.sort(names)
    print("LUAFAIL fields: " .. table.concat(names, " | "))
    mach:exit()
    return
end

local steps = {}
for _, s in ipairs(split(SEQ, ";")) do
    local f = split(s, ",")
    steps[#steps + 1] = { x = tonumber(f[1]), y = tonumber(f[2]), frame = tonumber(f[3]) }
end

local function dump(addr, len, name)
    local path = string.format("%s/%s_%s.bin", OUT, TAG, name)
    local f = assert(io.open(path, "wb"))
    local buf = {}
    for i = 0, len - 2, 2 do
        local w = prog:read_u16(addr + i)
        buf[#buf + 1] = string.char((w >> 8) & 0xFF, w & 0xFF)
    end
    f:write(table.concat(buf))
    f:close()
end

local step = 1
local done = false
local function frame_body()
    if done then return end
    local n = scr:frame_number()
    -- a coin, then start, each held a few frames
    coin:set_value((n >= COINF and n < COINF + 4) and 1 or 0)
    start:set_value((n >= STRTF and n < STRTF + 4) and 1 or 0)
    -- the gun: the current step's position from the previous step's frame on
    local s = steps[step]
    if s then
        gunx:set_value(s.x)
        guny:set_value(s.y)
        if n >= s.frame then
            local tag = string.format("s%d_x%02x_y%02x", step, s.x, s.y)
            dump(0x200000, 0x10000, tag .. "_workram")
            dump(0xb00000, 0x4000,  tag .. "_sprcode")
            dump(0xa00000, 0x600,   tag .. "_sprylow")
            mach.video:snapshot()
            print(string.format("GUN      step %d gun=(%02x,%02x) frame %d dumped", step, s.x, s.y, n))
            step = step + 1
        end
    else
        done = true
        print("GUN      done")
        mach:exit()
    end
end

_G.__seta_frame_notifier = emu.add_machine_frame_notifier(function()
    local ok, err = pcall(frame_body)
    if not ok then
        local f = io.open(OUT .. "/lua_error.txt", "w")
        if f then f:write("notifier: " .. tostring(err) .. "\n"); f:close() end
        print("LUAFAIL notifier: " .. tostring(err))
        mach:exit()
    end
end)
