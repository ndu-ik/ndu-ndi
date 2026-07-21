-- conky_helpers.lua
--
-- Drives dynamic content (greeting text, contrast color) for conky WITHOUT
-- ever touching .conkyrc or forcing a reload. Conky calls these functions
-- on every update cycle (per update_interval in .conkyrc); they just read
-- small plain-text state files that other scripts write to.
--
-- Usage in .conkyrc:
--   lua_load ~/scripts/lib/conky_helpers.lua
--   ...
--   ${lua conky_greeting}
--   ${lua_parse conky_color_open}some text${lua_parse conky_color_close}
--
-- State files:
--   ~/.local/run/conky_color.txt         -- single line hex color, e.g. "cacaca" (no '#')

local HOME = os.getenv("HOME")
local GREETINGS_FILE = HOME .. "/greetings3.txt"
local COLOR_FILE = HOME .. "/.local/run/conky_color.txt"

-- Cache for greeting to avoid changing on every Conky update
local greeting_cache = {
    text = "",
    timestamp = 0
}

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

-- Returns a random greeting from the greetings file (raw text only)
-- Changes every 5 seconds
function conky_greeting()
    local current_time = os.time()
    
    -- Check if we need to update the greeting (every 5 seconds)
    if current_time - greeting_cache.timestamp >= 60 then
        local f = io.open(GREETINGS_FILE, "r")
        if not f then 
            greeting_cache.text = "No greeting file found"
            greeting_cache.timestamp = current_time
            return greeting_cache.text
        end
        
        local lines = {}
        for line in f:lines() do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed and #trimmed > 0 then
                table.insert(lines, trimmed)
            end
        end
        f:close()
        
        if #lines == 0 then 
            greeting_cache.text = "No greetings available"
            greeting_cache.timestamp = current_time
            return greeting_cache.text
        end
        
        -- Seed random
        math.randomseed(current_time + math.random(1000))
        greeting_cache.text = lines[math.random(#lines)]
        greeting_cache.timestamp = current_time
    end
    
    return greeting_cache.text
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