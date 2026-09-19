-- Coin pulses of a given length, then a snapshot, for scripts/coin_test.py.
--
--   CN_AT     frame of the first pulse
--   CN_HOLD   frames Coin 1 is held per pulse
--   CN_GAP    frames released between pulses
--   CN_COUNT  pulses
--   CN_SNAP   frames after the last release to take the snapshot and exit
--
-- set_value drives the field directly, so PORT_IMPULSE does not shorten it.

local AT    = tonumber(os.getenv("CN_AT") or "600")
local HOLD  = tonumber(os.getenv("CN_HOLD") or "5")
local GAP   = tonumber(os.getenv("CN_GAP") or "60")
local COUNT = tonumber(os.getenv("CN_COUNT") or "3")
local SNAP  = tonumber(os.getenv("CN_SNAP") or "120")

local mach = manager.machine
local scr  = mach.screens[":screen"]

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end
local f_coin = field("Coin 1")

local last = AT + COUNT * (HOLD + GAP)
local n = 0
emu.register_frame_done(function()
    n = n + 1
    local k = n - AT
    local on = k >= 0 and n < last and (k % (HOLD + GAP)) < HOLD
    f_coin:set_value(on and 1 or 0)
    if n == last + SNAP then
        scr:snapshot()
        mach:exit()
    end
end)
