-- Thundercade: per frame, whether sprite RAM holds one list version, and
-- whether the control bytes were written since the last frame -- the frames
-- x1_001.sv's snap_ctrl_gate takes. Checked at frame_done (vblank start,
-- line 240), where MAME draws and the core snapshots.
--
-- The vblank handler copies half of the work-RAM list (codes 0xe02000, X
-- 0xe02400, Y 0xe02c00; 0x200 slots) to sprite RAM each frame. A frame is
-- mixed when list slots of the half copied first changed before the other
-- half's copy.
--
--   TC_OUT   output: "n ctrl half0copy half1copy mixed_writes"
--   TC_TO    last frame

local OUT = os.getenv("TC_OUT")
local TO  = tonumber(os.getenv("TC_TO") or "6000")

local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]
local f = io.open(OUT, "w")

local cnt = { [0] = 0, [1] = 0 }          -- list writes per half, running
local at_copy = { [0] = nil, [1] = nil }  -- cnt[] of the copied half's own count... see below
local copy_t = { [0] = -1, [1] = -1 }     -- frame of each half's last copy
local seq = 0
local copy_seq = { [0] = -1, [1] = -1 }
local copied_this = { [0] = false, [1] = false }
local ctrl = false

local function slot_half(off, base)
    return (((off - base) // 2) >= 0x100) and 1 or 0
end

_G.__tc = {
    -- only writes that change the stored value
    prog:install_write_tap(0xe02000, 0xe027ff, "tcl", function(off, data, mask)
        if (prog:read_u16(off) & mask) == (data & mask) then return end
        local base = off < 0xe02400 and 0xe02000 or 0xe02400
        local h = slot_half(off, base); cnt[h] = cnt[h] + 1
    end),
    prog:install_write_tap(0xe02c00, 0xe02fff, "tcy", function(off, data, mask)
        if (prog:read_u16(off) & mask) == (data & mask) then return end
        local h = slot_half(off, 0xe02c00); cnt[h] = cnt[h] + 1
    end),
    -- a copy starts with the half's first Y write
    prog:install_write_tap(0x600000, 0x6003ff, "tcc", function(off)
        local h = slot_half(off, 0x600000)
        if not copied_this[h] then
            copied_this[h] = true
            seq = seq + 1
            copy_seq[h] = seq
            at_copy[h] = { [0] = cnt[0], [1] = cnt[1] }
        end
    end),
    prog:install_write_tap(0x600600, 0x600607, "tck", function() ctrl = true end),
}

local n = 0
emu.register_frame_done(function()
    n = n + 1
    local mixed = 0
    if at_copy[0] and at_copy[1] then
        -- the half copied first: its slots must not change before the other copy
        local first = copy_seq[0] < copy_seq[1] and 0 or 1
        local other = 1 - first
        mixed = at_copy[other][first] - at_copy[first][first]
    end
    f:write(string.format("%d %d %d %d %d\n", n, ctrl and 1 or 0,
        copied_this[0] and 1 or 0, copied_this[1] and 1 or 0, mixed))
    ctrl = false
    copied_this[0] = false; copied_this[1] = false
    if n == TO then f:close(); mach:exit() end
end)
