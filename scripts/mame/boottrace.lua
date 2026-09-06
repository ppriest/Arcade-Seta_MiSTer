-- Log the first N main-CPU bus accesses of a boot, as ground truth for the
-- RTL's own boot trace to be diffed against.
--
-- Driven by scripts/mame_capture.py --boot-trace N. Parameters arrive as
-- environment variables:
--
--   SETA_OUT     directory to write into (must already exist)
--   SETA_TAG     prefix for the output filename (normally the set name)
--   SETA_TRACE_N how many accesses to log before stopping
--
-- WHY A READ TAP RATHER THAN THE DEBUGGER'S `trace`
-- -------------------------------------------------
-- MAME's `trace` emits one line per INSTRUCTION START. The RTL testbench sees
-- every bus ACCESS -- extension words, operand reads, stack pushes. Turning
-- one into the other means guessing each instruction's length from the gap to
-- the next PC, which scripts/parse_mame_trace.py does and which its own
-- docstring admits cannot work across a branch ("only the PC itself is
-- emitted, because its length is not knowable from the trace alone").
--
-- A read tap on the program space records the accesses directly, so there is
-- nothing to reconstruct and nothing to be wrong about. It also needs no
-- debugger, which this MAME install would otherwise open as a window.
--
-- What it does NOT capture: writes (a separate tap, added below), and the
-- distinction between an opcode fetch and a data read -- the Lua tap gives no
-- function code. The RTL bench should therefore match this as an ordered
-- ADDRESS sequence, not assert on access type.

local OUT = os.getenv("SETA_OUT") or "."
local TAG = os.getenv("SETA_TAG") or "trace"
local N   = tonumber(os.getenv("SETA_TRACE_N") or "512")

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]

local f = assert(io.open(string.format("%s/%s_boot.trace", OUT, TAG), "w"))
f:write("# main-CPU bus accesses from reset, in order.\n")
f:write("# seq\trw\taddr\tdata\n")

local n, done = 0, false
local hits, logged, first_err = 0, 0, nil

local function stop()
    if done then return end
    done = true
    f:write(string.format("# %d accesses seen, %d logged\n", hits, logged))
    if first_err then f:write("# FIRST ERROR: " .. first_err .. "\n") end
    f:close()
    print(string.format("TRACE  %d accesses logged to %s/%s_boot.trace",
                        logged, OUT, TAG))
    mach:exit()
end

-- Every callback is wrapped and counted. An error inside a tap is SWALLOWED by
-- MAME -- on this project that produced 459 tap hits and an empty log with no
-- diagnostic anywhere (docs/LESSONS_LEARNED.md, [Seta] entries). A hits count
-- beside a logged count is what makes that visible instead of silent.
local function record(rw)
    return function(offset, data, mask)
        hits = hits + 1
        if not done then
            local ok, err = pcall(function()
                n = n + 1
                f:write(string.format("%d\t%s\t%06X\t%04X\n", n, rw, offset,
                                      data & 0xFFFF))
                logged = logged + 1
            end)
            if not ok and not first_err then first_err = tostring(err) end
            if n >= N then stop() end
        end
        return data
    end
end

-- Keep the subscriptions alive: a collected tap silently stops firing.
_G.__seta_trace_taps = {
    prog:install_read_tap(0x000000, 0xffffff, "rd", record("r")),
    prog:install_write_tap(0x000000, 0xffffff, "wr", record("w")),
}

-- A backstop, so a game that somehow makes fewer than N accesses still writes
-- its file rather than leaving an empty one behind when MAME's own
-- -seconds_to_run kills the run.
_G.__seta_trace_notifier = emu.add_machine_frame_notifier(function()
    if mach.screens[":screen"]:frame_number() >= 600 then stop() end
end)
