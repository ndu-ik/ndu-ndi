-- conky_helpers.lua
--
-- Drives dynamic contrast-color content for conky WITHOUT ever touching
-- .conkyrc or forcing a reload. Conky calls these functions on every update
-- cycle (per update_interval in .conkyrc); they just read small
-- plain-text state files that other scripts write to whenever the
-- wallpaper or window corner changes.
--
-- Usage in .conkyrc:
--   lua_load ~/.local/run/conky_helpers.lua
--   ...
--   ${lua_parse conky_color_open}some text${lua_parse conky_color_close}
--   ${lua_parse conky_alignment}
--
-- State files:
--   ~/.local/run/conky_color.txt       -- single line hex color, e.g. "cacaca" (no '#')
--   ~/.local/run/conky_alignment.txt   -- single line corner, e.g. "top_right"
--
-- NOTE: conky_alignment() is for DISPLAY purposes only (e.g. printing the
-- current corner somewhere in the TEXT section). It cannot move the conky
-- window itself — the actual window placement is controlled by launching
-- conky with `-a <corner>` (see conkyposition.sh), since the "alignment"
-- setting is only read once at window-creation time and isn't something
-- lua_parse can change at runtime.

local HOME = os.getenv("HOME")
local COLOR_FILE = HOME .. "/.local/run/conky_color.txt"
local ALIGNMENT_FILE = HOME .. "/.local/run/conky_alignment.txt"

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if content then
        content = content:gsub("%s+$", "") -- trim trailing whitespace/newline
    end
    return content
end

-- Returns the current contrast color as a conky-compatible ${color #xxxxxx} tag.
function conky_color_open()
    local color = read_file(COLOR_FILE)
    if not color or color == "" then
        color = "191919"
    end
    return "${color #" .. color .. "}"
end

function conky_color_close()
    return "${color}"
end

-- Returns the current corner (e.g. "top_right") as written by
-- conkyposition.sh. Display-only, see NOTE above.
function conky_alignment()
    local alignment = read_file(ALIGNMENT_FILE)
    if not alignment or alignment == "" then
        alignment = "top_right"
    end
    return alignment
end