-- Capture a reference frame from a running Seta game: every piece of video
-- state the RTL renders from, plus the screenshot MAME produced from it.
--
-- Driven by scripts/mame_capture.py -- see that file for usage, and for the
-- per-game region map. Parameters arrive as environment variables because
-- MAME gives an autoboot script no argument vector of its own:
--
--   SETA_OUT      directory to write into (must already exist)
--   SETA_FRAME    frame number to capture at
--   SETA_TAG      prefix for the output filenames (normally the set name)
--   SETA_REGIONS  "name:hexaddr:hexlen,name:hexaddr:hexlen,..."
--   SETA_TAPS     "hexlo:hexhi,..." ranges to log writes to, or empty
--
-- THIS FILE HOLDS NO GAME KNOWLEDGE. Fuuki's version had the region table
-- inline and a board flag threaded through it; seta.cpp has far more distinct
-- memory maps than fuukifg2/fg3 did, so the addresses live in the Python side
-- where they can be transcribed from one `*_map` function each and reviewed
-- together. A wrong address here dumps zeros in silence.
--
-- Everything is read through the CPU program space, so what lands in the file
-- is what the CPU would read -- device handlers and all -- rather than a guess
-- at where MAME keeps it internally. That matters more on this hardware than
-- most: the sprite RAM and the tilemap VRAM are inside x1_001_device and
-- x1_012_device, not plain memory shares.

local OUT     = os.getenv("SETA_OUT")   or "."
local FRAME   = tonumber(os.getenv("SETA_FRAME") or "600")
local TAG     = os.getenv("SETA_TAG")   or "capture"
local REGIONS = os.getenv("SETA_REGIONS") or ""
local TAPS    = os.getenv("SETA_TAPS")  or ""

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local scr  = mach.screens[":screen"]

local function split(s, sep)
    local out = {}
    for tok in string.gmatch(s, "([^" .. sep .. "]+)") do out[#out + 1] = tok end
    return out
end

local regions = {}
for _, spec in ipairs(split(REGIONS, ",")) do
    local f = split(spec, ":")
    if #f == 3 then
        regions[#regions + 1] = { tonumber(f[2], 16), tonumber(f[3], 16), f[1] }
    end
end
if #regions == 0 then
    local f = io.open(OUT .. "/lua_error.txt", "w")
    if f then f:write("SETA_REGIONS was empty -- nothing to capture\n"); f:close() end
    print("LUAFAIL no regions")
    mach:exit()
    return
end

local function dump(addr, len, name)
    local path = string.format("%s/%s_%s.bin", OUT, TAG, name)
    local f = assert(io.open(path, "wb"))
    -- Read a word at a time: these are 16-bit devices, and byte reads through
    -- a word handler are not always the same thing.
    local buf = {}
    for i = 0, len - 2, 2 do
        local w = prog:read_u16(addr + i)
        buf[#buf + 1] = string.char((w >> 8) & 0xFF, w & 0xFF)   -- big-endian
    end
    f:write(table.concat(buf))
    f:close()
    print(string.format("CAPTURE  %-10s %06X +%05X -> %s", name, addr, len, path))
end

-- THE CURRENT SCANLINE, derived rather than asked for.
--
-- MAME 0.286's Lua screen binding has NO vpos() or hpos() -- both are nil, and
-- a call to them inside a write tap raises an error that MAME SWALLOWS, so the
-- tap keeps firing and the log stays empty. That is what happened on the first
-- run of this script: 459 tap hits, zero lines logged, no diagnostic anywhere.
-- Probed with a variant-by-variant test rather than guessed
-- (LESSONS_LEARNED, "Driving MAME as a reference generator").
--
-- What does exist is time_until_pos(y) = seconds until the beam next reaches
-- (y, 0). From it:
--     line_period  = time_until_pos(1) - time_until_pos(0), taking the
--                    smallest POSITIVE difference over several samples so a
--                    frame wrap between the two calls cannot poison it
--     current line = (frame_period - time_until_pos(0)) / line_period
-- On thunderl, gundhara and daioh this yields frame_period/line_period = 256.0
-- exactly -- MAME's declared screen height for these games, which is also the
-- height any driver arithmetic is written against. Note the RTL's own frame is
-- expected to be ~262 lines: do not conflate the two.
local frame_period = 1.0 / scr.refresh
local line_period
for _ = 1, 64 do
    local d = scr:time_until_pos(1) - scr:time_until_pos(0)
    if d > 0 and (line_period == nil or d < line_period) then line_period = d end
end

local function cur_line()
    if not line_period or line_period <= 0 then return -1 end
    return math.floor((frame_period - scr:time_until_pos(0)) / line_period + 0.5)
end

-- Optional write log, tagged with the frame and THE SCANLINE IN FORCE.
--
-- That last column is the point. x1_012.cpp says the real chip reads its
-- scroll registers every scanline, and that MAME deliberately does not do
-- partial updates because several games write registers at the wrong time --
-- Zombie Raid writes horizontal scroll mid-screen, and Blandia's Athena stage
-- and Strike Gunner are named as the other cases. An FPGA core is naturally
-- per-scanline and will therefore be MORE accurate than MAME there, so for
-- those games this log, not MAME's screenshot, is the reference.
local wlog
local tap_hits, tap_logged, tap_err = 0, 0, nil
if TAPS ~= "" then
    wlog = assert(io.open(string.format("%s/%s_writes.log", OUT, TAG), "w"))
    wlog:write(string.format("# vtotal %d, derived from time_until_pos\n",
                             line_period and math.floor(frame_period / line_period + 0.5) or -1))
    wlog:write("# frame\tscanline\taddr\tdata\tpc\n")
    _G.__seta_taps = {}   -- keep them alive; a collected tap stops firing
    for _, spec in ipairs(split(TAPS, ",")) do
        local f = split(spec, ":")
        local lo, hi = tonumber(f[1], 16), tonumber(f[2], 16)
        -- EVERY callback is wrapped, and both a hit count and a logged count
        -- are kept. An error in here is invisible otherwise, and "no writes
        -- happened" then looks identical to "every write threw". Pairing a
        -- bad-event counter with a total-events counter is the same rule the
        -- hardware probe follows (LESSONS_LEARNED, "Debug instrumentation").
        local tap = prog:install_write_tap(lo, hi, "setawr", function(offset, data, mask)
            tap_hits = tap_hits + 1
            local ok, err = pcall(function()
                wlog:write(string.format("%d\t%d\t%06X\t%04X\t%08X\n",
                    scr:frame_number(), cur_line(), offset, data & 0xFFFF,
                    cpu.state["PC"].value))
            end)
            if ok then tap_logged = tap_logged + 1
            elseif not tap_err then tap_err = tostring(err) end
            return data
        end)
        _G.__seta_taps[#_G.__seta_taps + 1] = tap
        print(string.format("CAPTURE  write tap %06X-%06X", lo, hi))
    end
end

-- An error INSIDE a frame notifier is reported by MAME with a dialog and does
-- not propagate to the loader, so run.lua's pcall cannot see it. Catch it here
-- and record it the same way, then stop -- continuing would produce a
-- half-written capture that looks valid.
local function fail(msg)
    local f = io.open(OUT .. "/lua_error.txt", "w")
    if f then f:write("notifier: " .. tostring(msg) .. "\n"); f:close() end
    print("LUAFAIL notifier: " .. tostring(msg))
    mach:exit()
end

local done = false
local function frame_body()
    if done then return end
    local n = scr:frame_number()
    if n < FRAME then return end
    done = true

    print(string.format("CAPTURE  frame %d, %s -> %s", n, TAG, OUT))
    for _, r in ipairs(regions) do dump(r[1], r[2], r[3]) end

    -- The screenshot is as important as the dumps: it is the reference the
    -- RTL's own rendering of this exact state gets compared against.
    mach.video:snapshot()

    local f = assert(io.open(string.format("%s/%s_info.txt", OUT, TAG), "w"))
    f:write(string.format("system      %s\n", mach.system.name))
    f:write(string.format("description %s\n", mach.system.description))
    f:write(string.format("frame       %d\n", n))
    f:write(string.format("screen      %dx%d refresh %f\n", scr.width, scr.height, scr.refresh))
    f:write(string.format("mame        %s\n", emu.app_version()))
    f:close()

    if wlog then
        wlog:write(string.format("# %d tap hits, %d logged\n", tap_hits, tap_logged))
        if tap_err then wlog:write("# FIRST ERROR: " .. tap_err .. "\n") end
        wlog:close()
        print(string.format("CAPTURE  writes: %d tap hits, %d logged", tap_hits, tap_logged))
        if tap_hits > 0 and tap_logged == 0 then
            print("CAPTURE  *** every tap callback FAILED: " .. tostring(tap_err))
        end
    end
    print("CAPTURE  done")
    mach:exit()
end

-- KEEP THE SUBSCRIPTION ALIVE. emu.add_machine_frame_notifier returns a
-- subscription object, and if it is dropped the garbage collector eventually
-- reclaims it and the callback silently STOPS FIRING. This is the same trap as
-- the write taps above, and it fails in a thoroughly misleading way: a capture
-- at frame 120 worked (the callback fired long before a collection happened)
-- while the identical capture at frame 1100 produced nothing at all, no error,
-- and MAME exited cleanly with status 0.
_G.__seta_frame_notifier = emu.add_machine_frame_notifier(function()
    local ok, err = pcall(frame_body)
    if not ok then fail(err) end
end)
