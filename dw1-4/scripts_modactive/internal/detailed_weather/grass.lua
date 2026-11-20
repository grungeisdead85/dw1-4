-- Grass and texture helpers for Detailed Weather, shared by the other modules: where the game's
-- grass edge art is, which grass overhangs which, the map blocks and their snow, and reading a
-- texture's pixels.
--
-- How the game draws grass (worked out in notes/handover.md):
--   * a grass tile's own clump is its screentexpos_background texture
--   * every overhang, grass or ground, comes from screentexpos_floor_flag: four bytes for the
--     tile's sides S, W, E, N, each the edging ID of the neighbour on that side (0 = none). 1 is
--     generic grass (the GRASS_1-9 tiles), 10 and up a grass with [CUSTOM_EDGING:n] (ID n + 9),
--     the rest soil and stone. The renderer picks the piece itself, and adds small corner pieces
--     where only a diagonal neighbour's grass reaches.
-- (This module once redrew the grass itself to sway it in the wind; the lean is now done by
-- swapping grass textures, in colour.lua.)
--@ module = true

-- The corners of a tile, with the two sides (S, W, E, N: floor_flag's byte order) each sits between.
CORNERS = {
    {name = 'NW', dx = -1, dy = -1, sides = {2, 4}},
    {name = 'NE', dx = 1, dy = -1, sides = {3, 4}},
    {name = 'SW', dx = -1, dy = 1, sides = {1, 2}},
    {name = 'SE', dx = 1, dy = 1, sides = {1, 3}},
}
-- Generic grass pieces: GRASS_1-9 are a 3x3 blob around a grass tile, so the piece for a tile
-- with grass to its north is the cell south of the centre, and so on.
GENERIC_PIECE = {N = 8, S = 2, W = 6, E = 4, NW = 9, NE = 7, SW = 3, SE = 1}
local GENERIC_GRASS = 1
local FIRST_CUSTOM = 10
local TILE = 32

----------------------------------------------------------------------------------------------
-- Where the edge art is: read from the active mods' graphics files
----------------------------------------------------------------------------------------------

function page_texpos(token, x, y)
    for _, page in ipairs(df.global.texture.page) do
        if page.token == token then
            local width = page.page_dim_x > 0 and page.page_dim_x or 1
            return page.texpos[y * width + x]
        end
    end
end

-- Mod paths are relative to the user data folder (installed mods) or the game folder (vanilla).
function graphics_files(mod_path)
    local dir
    for _, root in ipairs{dfhack.filesystem.getBaseDir(), dfhack.filesystem.getInstallDir(), ''} do
        if dfhack.filesystem.isdir(root .. mod_path) then dir = root .. mod_path:gsub('/$', '') .. '/graphics' break end
    end
    local files = {}
    for _, f in ipairs(dir and dfhack.filesystem.listdir_recursive(dir) or {}) do
        local path = f.path:sub(1, 1) == '/' and f.path or dir .. '/' .. f.path
        if not f.isdir and path:lower():match('%.txt$') then files[#files + 1] = path end
    end
    table.sort(files)
    return files
end

-- texpos -> the graphics token that names it (DIRT_FLOOR_5, SOIL_RAMP_WITH_WALL_N...), from every
-- active mod's graphics files; later mods override earlier ones, as the game does. Read once a
-- world (it reads every graphics file, ~200 ms).
local token_of
function texture_tokens()
    if token_of then return token_of end
    token_of = {}
    local pages = {}
    for _, page in ipairs(df.global.texture.page) do pages[page.token] = page end
    for _, mod in ipairs(require('script-manager').get_active_mods()) do
        for _, path in ipairs(graphics_files(mod.path)) do
            local file = io.open(path, 'r')
            local text = file and file:read('a') or ''
            if file then file:close() end
            for page, x, y, token in text:gmatch('%[TILE_GRAPHICS:([%w_]+):(%d+):(%d+):([%u_%d]+)') do
                local p = pages[page]
                local i = p and tonumber(y) * (p.page_dim_x > 0 and p.page_dim_x or 1) + tonumber(x)
                if i and i < #p.texpos then token_of[p.texpos[i]] = token end
            end
        end
    end
    return token_of
end
function forget_tokens() token_of = nil end

-- edges[id][piece name] = texpos, for every grass edging ID. Later mods override earlier ones,
-- as the game does.
function find_edge_art()
    local edges = {[GENERIC_GRASS] = {}}
    for _, mod in ipairs(require('script-manager').get_active_mods()) do
        for _, path in ipairs(graphics_files(mod.path)) do
            local file = io.open(path, 'r')
            local text = file and file:read('a') or ''
            if file then file:close() end
            for page, x, y, n in text:gmatch('%[TILE_GRAPHICS:([%w_]+):(%d+):(%d+):GRASS_(%d)%]') do
                for name, cell in pairs(GENERIC_PIECE) do
                    if cell == tonumber(n) then edges[GENERIC_GRASS][name] = page_texpos(page, tonumber(x), tonumber(y)) end
                end
            end
            -- each PLANT_GRAPHICS block: its CUSTOM_EDGING number and CUSTOM_EDGE_* pieces
            local starts = {}
            for at in text:gmatch('()%[PLANT_GRAPHICS:') do starts[#starts + 1] = at end
            starts[#starts + 1] = #text + 1
            for i = 1, #starts - 1 do
                local block = text:sub(starts[i], starts[i + 1] - 1)
                local number = tonumber(block:match('%[CUSTOM_EDGING:(%d+)%]'))
                if number then
                    local pieces = {}
                    for name, page, x, y in block:gmatch('%[CUSTOM_EDGE_(%u+):([%w_]+):(%d+):(%d+)%]') do
                        pieces[name] = page_texpos(page, tonumber(x), tonumber(y))
                    end
                    edges[number + FIRST_CUSTOM - 1] = pieces
                end
            end
        end
    end
    return edges
end

----------------------------------------------------------------------------------------------
-- Which grass is where
----------------------------------------------------------------------------------------------

-- The map block holding a tile, or nil off the map. Blocks are kept between calls, as
-- dfhack.maps.getTileBlock costs ~50 us; they're pointers into the game, so the cache is dropped
-- whenever a map loads or unloads.
block_cache = block_cache or {}
function block_at(x, y, z)
    local key = ((z * 1024) + x // 16) * 1024 + (y // 16)
    local block = block_cache[key]
    if block == nil then
        block = dfhack.maps.getTileBlock(x, y, z) or false
        block_cache[key] = block
    end
    return block or nil
end
dfhack.onStateChange.detailed_weather_blocks = function(event)
    if event == SC_MAP_LOADED or event == SC_MAP_UNLOADED or event == SC_WORLD_UNLOADED then
        block_cache, block_snow = {}, {}
    end
end

-- The snow on a tile (0-255; the game draws it from about 100). Each block's snow is read in one go
-- (its events walked once, not once per tile) and kept for SNOW_KEPT_MS: snow comes and goes slowly.
local SNOW_KEPT_MS = 10000
local WATER = 6
block_snow = block_snow or {}   -- by block: {amounts (bx * 16 + by), due}
function snow_amount(x, y, z, now)
    local key = ((z * 1024) + x // 16) * 1024 + (y // 16)
    local kept = block_snow[key]
    if not kept or now >= kept.due then
        local block = block_at(x, y, z)
        if not block then return 0 end
        local amounts = {}
        for n = 0, 255 do amounts[n] = 0 end
        for _, event in ipairs(block.block_events) do
            if df.block_square_event_material_spatterst:is_instance(event) and event.mat_type == WATER
                    and event.mat_state == df.matter_state.Powder then
                for bx = 0, 15 do
                    local column = event.amount[bx]
                    for by = 0, 15 do
                        local a = column[by]
                        if a > amounts[bx * 16 + by] then amounts[bx * 16 + by] = a end
                    end
                end
            end
        end
        kept = {amounts = amounts, due = now + SNOW_KEPT_MS + math.random(0, SNOW_KEPT_MS // 2)}
        block_snow[key] = kept
    end
    return kept.amounts[(x % 16) * 16 + y % 16]
end
function forget_snow() block_snow = {} end

local grass_tiletype = {}   -- by tiletype: whether it's grass (df.tiletype.attrs costs ~40 us)

-- The edging ID of the grass on a tile, or nil if it isn't grass.
function grass_edging(x, y, z)
    local block = block_at(x, y, z)
    if not block then return nil end
    local tiletype = block.tiletype[x % 16][y % 16]
    local grassy = grass_tiletype[tiletype]
    if grassy == nil then
        local material = df.tiletype.attrs[tiletype].material
        grassy = material == df.tiletype_material.GRASS_LIGHT or material == df.tiletype_material.GRASS_DARK
        grass_tiletype[tiletype] = grassy
    end
    if not grassy then return nil end
    local best, amount = nil, 0
    for _, event in ipairs(block.block_events) do
        if df.block_square_event_grassst:is_instance(event) then
            local a = event.amount[x % 16][y % 16]
            if a > amount then best, amount = event.plant_index, a end
        end
    end
    local plant = best and df.global.world.raws.plants.all[best]
    if not plant then return nil end
    local custom = plant.texpos[5]   -- CUSTOM_EDGING minus one, or -1
    return custom >= 0 and custom + FIRST_CUSTOM or GENERIC_GRASS
end

-- Whether grass with edging `id` overhangs a tile whose own edging is `own` (nil: not grass).
-- Custom edging beats generic grass; between two customs the lower number wins.
function beats(id, own)
    if not own then return true end
    if id == own then return false end
    if id >= FIRST_CUSTOM and own >= FIRST_CUSTOM then return id < own end
    return id >= FIRST_CUSTOM
end

----------------------------------------------------------------------------------------------
-- Pixels
----------------------------------------------------------------------------------------------

-- A texture's pixels as {r, g, b, a} tables, row by row, or nil. The game's surfaces are SDL
-- ABGR8888: bytes R, G, B, A.
-- Kept by texture number, with what they were read from: the game builds some pictures as it
-- draws (trees, workshops, ramps) and gives a freed number to a new one, so a kept read is only
-- used while the number still has the same surface and a few of the same pixels.
local SIGNATURE_POINTS = {}
for k = 0, 15 do SIGNATURE_POINTS[#SIGNATURE_POINTS + 1] = (k * 389) % (TILE * TILE) end
local pixel_cache = {}

local function surface_of(texpos)
    local surface = df.global.enabler.textures.raws[texpos]
    if not surface then return nil end
    local ints = df.reinterpret_cast('int32_t', surface)
    local w, h, pitch = ints:_displace(4)[0], ints:_displace(5)[0], ints:_displace(6)[0]
    if w ~= TILE or h ~= TILE then return nil end
    local address = df.reinterpret_cast('uint64_t', surface):_displace(4)[0]
    return df.reinterpret_cast('uint8_t', address), pitch, address
end

local function signature(bytes, pitch)
    local sum = 0
    for _, n in ipairs(SIGNATURE_POINTS) do
        local o = (n // TILE) * pitch + (n % TILE) * 4
        sum = (sum * 31 + bytes[o] + bytes[o + 1] * 7 + bytes[o + 2] * 13 + bytes[o + 3] * 17) % 2147483647
    end
    return sum
end

function pixels_of(texpos)
    if not texpos or texpos <= 0 then return nil end
    local bytes, pitch, address = surface_of(texpos)
    if not bytes then pixel_cache[texpos] = nil return nil end
    local sig = signature(bytes, pitch)
    local cached = pixel_cache[texpos]
    if cached and cached.address == address and cached.sig == sig then return cached.px end
    local px = {}
    for y = 0, TILE - 1 do
        for x = 0, TILE - 1 do
            local o = y * pitch + x * 4
            px[#px + 1] = {bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]}
        end
    end
    pixel_cache[texpos] = {px = px, address = address, sig = sig}
    return px
end

-- Textures the modules have finished with are not deleted on the spot: discard() puts them here and
-- empty_trash() deletes them a few at a time while the overlay draws a frame (colour.update).
--   - Deleting takes about 0.04 ms each, and thousands at once stalled a frame for half a second.
--   - A texture must never be deleted once the world it was made in has gone. When a world loads,
--     the game frees every texture made since it started, so a handle from the world before then
--     names freed memory, and deleting it crashes (DFHack issue 6045, from a player's crash in
--     1.2, which kept its trash across worlds and went on emptying it in the next one). So when
--     a world unloads nothing is deleted and nothing is kept: abandon_trash() lets go of what's
--     waiting, and each module's forget_world() drops its textures the same way.
--   - Deleting is only done while a frame is being drawn, a little at a time: the game's other
--     threads are waiting then. (DFHack's deleteHandle also reads a texture's memory once more
--     after freeing it; its developers think that unlikely to go wrong, but it's one more reason
--     not to delete thousands at once from a state change.)
local TRASH_MS = 1
texture_trash = texture_trash or {}

function discard(handle)
    if handle then texture_trash[#texture_trash + 1] = handle end
end

function empty_trash()
    local started = dfhack.getTickCount()
    while #texture_trash > 0 and dfhack.getTickCount() - started < TRASH_MS do
        dfhack.textures.deleteHandle(table.remove(texture_trash))
    end
end

function abandon_trash()
    texture_trash = {}
end

-- Another map or world loading: the next world's graphics may differ, so pixels and textures kept
-- by texture number could be another texture's.
function forget_world()
    block_cache, block_snow = {}, {}
    pixel_cache = {}
    token_of = nil
end
