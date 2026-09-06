-- Seed a MAME configuration file with DIP switch settings, then exit cleanly.
--
-- Driven by scripts/mame_capture.py as PASS 1 of a --dip capture. MAME writes
-- cfg/<set>.cfg on a clean exit, and applies it at POWER-ON on the next launch
-- -- before any autoboot script runs. That is the whole point: setting a DIP
-- from the capture script itself is too late for a game that reads the
-- switches once during its own initialisation, which is most of them.
--
-- Measured, not assumed. With the DIP set from the capture script and no cfg:
-- thunderl came back with spritectrl[0] = 0x50 (flip screen on), and wits,
-- blockcar, umanclub, neobattl, atehate and pairlove all came back 0x10 --
-- unflipped -- while the sweep printed PASS for every one of them. Trying to
-- fix that with mach:soft_reset() from the capture script HUNG all seven: the
-- frame notifier the script installs does not survive the reset it asks for.
--
-- MAME's own save is not enough on its own. It writes a DIPSWITCH entry only
-- when the wanted value is non-zero: thunderl's "On" is 0x200 and persisted,
-- while wits and blockcar have "On" = 0 -- the same switch, opposite sense --
-- and nothing was written at all. So this script also reports the port data it
-- used, and the Python side builds the <input> section from it, reusing the
-- mameconfig version out of the file MAME itself just wrote.
--
--   SETA_DIPS     "Field Name=Setting;..."
--   SETA_OUT      directory to write dipinfo.txt and any failure note into

local OUT  = os.getenv("SETA_OUT")  or "."
local DIPS = os.getenv("SETA_DIPS") or ""

local mach = manager.machine

local function split(s, sep)
    local out = {}
    for tok in string.gmatch(s, "([^" .. sep .. "]+)") do out[#out + 1] = tok end
    return out
end

local function fail(msg)
    local f = io.open(OUT .. "/lua_error.txt", "w")
    if f then f:write(msg .. "\n"); f:close() end
    print("LUAFAIL " .. msg)
    mach:exit()
end

for _, spec in ipairs(split(DIPS, ";")) do
    local eq = string.find(spec, "=", 1, true)
    if not eq then
        fail("SETA_DIPS entry is not NAME=SETTING: " .. spec)
        return
    end
    local want_field   = string.sub(spec, 1, eq - 1)
    local want_setting = string.sub(spec, eq + 1)
    local applied = false
    for _, port in pairs(mach.ioport.ports) do
        local fld = port.fields[want_field]
        if fld then
            if not fld.settings then
                fail(string.format("DIP '%s' has no settings table", want_field))
                return
            end
            for raw, name in pairs(fld.settings) do
                if name == want_setting then
                    fld:set_value(raw)
                    print(string.format("SEED     %-20s = %-12s (raw 0x%x)",
                                        want_field, want_setting, raw))
                    -- tag, mask and defvalue come from MAME, not from a table
                    -- here: the sense of this switch is per-game.
                    local inf = io.open(OUT .. "/dipinfo.txt", "a")
                    if inf then
                        inf:write(string.format("%s\t%d\t%d\t%d\n",
                                  port.tag, fld.mask, fld.defvalue, raw))
                        inf:close()
                    end
                    applied = true
                end
            end
            if not applied then
                local have = {}
                for _, name in pairs(fld.settings) do have[#have + 1] = name end
                fail(string.format("DIP '%s' has no setting '%s' (has: %s)",
                                   want_field, want_setting, table.concat(have, ", ")))
                return
            end
        end
    end
    if not applied then
        fail(string.format("no DIP field named '%s' in this machine", want_field))
        return
    end
end

-- Run a few frames, then exit through machine:exit() so MAME saves the cfg.
-- Killing the process here would leave nothing written at all.
local scr = mach.screens[":screen"]
emu.add_machine_frame_notifier(function()
    if scr:frame_number() > 5 then
        print("SEED     cfg written, exiting")
        mach:exit()
    end
end)
