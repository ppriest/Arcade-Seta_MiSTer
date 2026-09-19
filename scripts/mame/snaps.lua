-- A snapshot every frame from SN_FROM to SN_TO, then exit.
-- Frame 1 is the first frame_done after the first CPU instruction.

local FROM = tonumber(os.getenv("SN_FROM") or "600")
local TO   = tonumber(os.getenv("SN_TO") or "660")

local mach = manager.machine
local scr  = mach.screens[":screen"]
local n = 0
emu.register_frame_done(function()
    n = n + 1
    if n >= FROM and n <= TO then mach.video:snapshot() end
    if n == TO then mach:exit() end
end)
