-- Per frame, the X1-001 foreground slots (Y, code, X) and which slots were
-- written since the last frame, for frames SD_FROM..SD_TO; then exit.
--
--   SD_OUT    output file: one line per frame,
--             "f <n> <512 x yyyycccccxxxx hex, '*' suffix when written>"
--   SD_YLOW   hex base of the Y bytes (low byte of each word)
--   SD_CODE   hex base of the code/X words
--   SD_BANK   code/X bank offset in bytes (0 or 0x2000)

local OUT  = os.getenv("SD_OUT")
local FROM = tonumber(os.getenv("SD_FROM") or "640")
local TO   = tonumber(os.getenv("SD_TO") or "760")
local YLOW = tonumber(os.getenv("SD_YLOW"), 16)
local CODE = tonumber(os.getenv("SD_CODE"), 16)
local BANK = tonumber(os.getenv("SD_BANK") or "0", 16)

local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]
local f = io.open(OUT, "w")

local written = {}
_G.__sd_taps = {
    prog:install_write_tap(YLOW, YLOW + 0x3ff, "sd_y", function(off, data, mask)
        written[(off - YLOW) // 2] = true
    end),
    prog:install_write_tap(CODE + BANK, CODE + BANK + 0x7ff, "sd_c", function(off, data, mask)
        written[((off - CODE - BANK) // 2) % 0x200] = true
    end),
}

local n = 0
emu.register_frame_done(function()
    n = n + 1
    if n >= FROM and n <= TO then
        local parts = {}
        for i = 0, 0x1ff do
            local y = prog:read_u16(YLOW + i * 2) & 0xff
            local c = prog:read_u16(CODE + BANK + i * 2)
            local x = prog:read_u16(CODE + BANK + 0x400 + i * 2)
            parts[#parts + 1] = string.format("%02x%04x%04x%s", y, c, x, written[i] and "*" or "")
        end
        f:write("f " .. n .. " " .. table.concat(parts, " ") .. "\n")
    end
    written = {}
    if n == TO then f:close(); mach:exit() end
end)
