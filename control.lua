local NAME = "wp-personal-railgun-equipment"
local FOG = "wp-railgun-fog"
local SOUND = "wp-railgun-shot"

local S = settings.startup
local DAMAGE    = S["wp-railgun-damage"].value
local RANGE     = S["wp-railgun-range"].value
local COOLDOWN  = math.max(1, math.floor(S["wp-railgun-cooldown"].value * 60 + 0.5)) -- ticks
local SHOT_J    = S["wp-railgun-shot-energy"].value * 1000000
local DRAIN_J_S = S["wp-railgun-idle-drain"].value * 1000

local SCAN_EVERY    = 10   -- ticks between targeting checks; at most one railgun fires per wearer per check
local DRAIN_EVERY   = 30
local DRAIN_STEP    = DRAIN_J_S * DRAIN_EVERY / 60
local DEFAULT_WIDTH = 2.5  -- default slug width in tiles (matches the map setting's default)
local MAX_HEADINGS  = 80   -- candidate headings tried per shot (nearest enemies first)

local STREAK_TICKS = 45
local FOG_SPACING  = 0.8
local LIFT         = -0.7 -- the streak is drawn this far up, at shoulder height...
local MUZZLE       = 0.8  -- ...starting this far out from the wearer
local FADE_IN_TILES  = 2.5 -- streak brightens over this distance from the muzzle
local FADE_OUT_TILES = 10  -- and dims out over this distance before full range
local FADE_STEPS     = 8   -- pieces per fade
local BEAM_LAYERS = {      -- widths in pixels at the default slug width
  {width = 3.5, color = {r = 0.45, g = 0.7, b = 1.0, a = 0.35}},
  {width = 1,   color = {r = 1, g = 1, b = 1, a = 0.9}},
}

local TARGET_TYPES = {
  ["unit"] = true, ["unit-spawner"] = true, ["turret"] = true,
  ["spider-unit"] = true, ["segmented-unit"] = true, ["segment"] = true,
  ["character"] = true, ["car"] = true, ["spider-vehicle"] = true,
  ["ammo-turret"] = true, ["electric-turret"] = true, ["fluid-turret"] = true,
  ["artillery-turret"] = true,
}

---------------------------------------------------------------------------------------------------
-- Bookkeeping

local function init()
  storage.grids = storage.grids or {}     -- grid unique_id -> grid, for the idle drain
  storage.cool = storage.cool or {}       -- "grid_id:x,y" -> tick the railgun is ready again
  storage.streaks = storage.streaks or {}
end

local function track_grid(grid)
  if grid and grid.valid then storage.grids[grid.unique_id] = grid end
end

local function scan_all()
  for _, player in pairs(game.players) do
    if player.character and player.character.valid then track_grid(player.character.grid) end
    if player.vehicle and player.vehicle.valid then track_grid(player.vehicle.grid) end
  end
  for _, surface in pairs(game.surfaces) do
    for _, v in pairs(surface.find_entities_filtered({type = {"car", "spider-vehicle", "locomotive"}})) do
      if v.grid then track_grid(v.grid) end
    end
  end
end

script.on_init(function() init() scan_all() end)
script.on_configuration_changed(function() init() scan_all() end)

local function allow_multiple()
  return settings.global["wp-railgun-allow-multiple"].value
end

local function on_inserted(e)
  if e.equipment and e.equipment.valid and e.equipment.name == NAME then track_grid(e.grid) end
end
if defines.events.on_equipment_inserted then
  script.on_event(defines.events.on_equipment_inserted, on_inserted)
end

-- One per grid (unless the map setting allows more): hand a second railgun straight back.
local function hand_back(player, quality)
  local item = {name = NAME, count = 1, quality = quality}
  local cursor = player.cursor_stack
  if cursor then
    if not cursor.valid_for_read then
      cursor.set_stack(item)
      return
    elseif cursor.name == NAME and cursor.quality.name == quality and cursor.count < cursor.prototype.stack_size then
      cursor.count = cursor.count + 1
      return
    end
  end
  local inserted = player.insert(item)
  if inserted == 0 then
    local where = player.character or player
    where.surface.spill_item_stack({position = where.position, stack = item})
  end
end

script.on_event(defines.events.on_player_placed_equipment, function(e)
  local eq, grid = e.equipment, e.grid
  if not (eq and eq.valid and eq.name == NAME) then return end
  track_grid(grid)
  if allow_multiple() or grid.count(NAME) <= 1 then return end

  local player = game.get_player(e.player_index)
  local quality = eq.quality.name
  grid.take({equipment = eq})
  if player then
    hand_back(player, quality)
    player.create_local_flying_text({text = {"wp-railgun.one-per-grid"}, create_at_cursor = true})
  end
end)

script.on_event(defines.events.on_player_armor_inventory_changed, function(e)
  local player = game.get_player(e.player_index)
  if player and player.character and player.character.valid then
    local grid = player.character.grid
    if grid and grid.count(NAME) > 0 then track_grid(grid) end
  end
end)

---------------------------------------------------------------------------------------------------
-- Idle drain: bleed each railgun's own buffer; the grid refills it from batteries and generators.

script.on_nth_tick(DRAIN_EVERY, function()
  if DRAIN_STEP <= 0 then return end
  for id, grid in pairs(storage.grids) do
    if not grid.valid or grid.count(NAME) == 0 then
      storage.grids[id] = nil
    else
      for _, eq in pairs(grid.equipment) do
        if eq.name == NAME then eq.energy = math.max(0, eq.energy - DRAIN_STEP) end
      end
    end
  end
end)

---------------------------------------------------------------------------------------------------
-- Targeting

local radius_cache = {}
local function radius_of(entity)
  local r = radius_cache[entity.name]
  if not r then
    local box = entity.prototype.collision_box
    r = math.max(math.abs(box.left_top.x), math.abs(box.left_top.y),
                 math.abs(box.right_bottom.x), math.abs(box.right_bottom.y))
    radius_cache[entity.name] = r
  end
  return r
end

local function enemy_forces(force)
  local list = {}
  for _, f in pairs(game.forces) do
    if f ~= force and force.is_enemy(f) then list[#list + 1] = f end
  end
  return list
end

-- Slug width and damage multiplier are map settings, read on every shot.
local function half_width()
  return settings.global["wp-railgun-width"].value / 2
end

local function damage_per_hit()
  return DAMAGE * settings.global["wp-railgun-damage-multiplier"].value
end

-- Returns the enemies that a slug could reach as flat arrays, nearest first.
local function gather_enemies(owner, forces, half)
  local pos = owner.position
  local reach = math.sqrt(RANGE * RANGE + half * half) + 1 -- wide slugs reach past the range circle at the far corners
  local found = owner.surface.find_entities_filtered({position = pos, radius = reach, force = forces})
  local list = {}
  for _, e in pairs(found) do
    if TARGET_TYPES[e.type] and e.valid and e.health and e.health > 0 then
      local dx, dy = e.position.x - pos.x, e.position.y - pos.y
      list[#list + 1] = {entity = e, x = dx, y = dy, r = radius_of(e), d = math.sqrt(dx * dx + dy * dy)}
    end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  return list
end

-- Try a heading toward each of the nearest enemies within range and keep the one whose line hits the most.
local function best_heading(enemies, half)
  local best_count, best_ux, best_uy, best_hits = 0
  local tried = 0
  for c = 1, #enemies do
    if tried >= MAX_HEADINGS then break end
    local cand = enemies[c]
    if cand.d > 0.01 and cand.d <= RANGE + cand.r then
      tried = tried + 1
      local ux, uy = cand.x / cand.d, cand.y / cand.d
      local hits, count = {}, 0
      for _, e in ipairs(enemies) do
        local along = e.x * ux + e.y * uy
        if along >= -e.r and along <= RANGE + e.r then
          local across = math.abs(e.x * uy - e.y * ux)
          if across <= half + e.r then
            count = count + 1
            hits[count] = e.entity
          end
        end
      end
      -- Ties go to the earlier (nearer) heading.
      if count > best_count then
        best_count, best_ux, best_uy, best_hits = count, ux, uy, hits
      end
    end
  end
  return best_ux, best_uy, best_hits
end

---------------------------------------------------------------------------------------------------
-- Firing

local function draw_shot(surface, pos, ux, uy, half)
  -- The streak and fog are drawn as one straight line at the gun's height on the wearer's
  -- shoulder. The hit test (best_heading) uses the same heading along the ground and is never drawn.
  local function point(d)
    return {x = pos.x + ux * d, y = pos.y + uy * d + LIFT}
  end

  -- Wider slugs get a wider glow; the default width keeps the thin beam.
  local w = math.max(1, (half * 2) / DEFAULT_WIDTH)
  local widths = {BEAM_LAYERS[1].width * w, BEAM_LAYERS[2].width * math.sqrt(w)}

  -- The streak is cut into pieces so it can fade in at the muzzle and fade out at the far end
  -- instead of ending in hard edges. The middle stays one long piece.
  local objects = {}
  local function piece(d0, d1, k)
    local a, b = point(d0), point(d1)
    for i, layer in ipairs(BEAM_LAYERS) do
      local c = layer.color
      local col = {r = c.r * k, g = c.g * k, b = c.b * k, a = c.a * k}
      objects[#objects + 1] = {
        obj = rendering.draw_line({surface = surface, from = a, to = b, width = widths[i],
          color = col, time_to_live = STREAK_TICKS + 2}),
        color = col,
      }
    end
  end
  local start = MUZZLE
  local fade_in_end = math.min(FADE_IN_TILES, start + (RANGE - start) * 0.3)
  local fade_out_start = math.max(fade_in_end, RANGE - math.min(FADE_OUT_TILES, (RANGE - start) * 0.5))
  local function smooth(k) return k * k * (3 - 2 * k) end
  for i = 0, FADE_STEPS - 1 do
    local d0 = start + (fade_in_end - start) * i / FADE_STEPS
    local d1 = start + (fade_in_end - start) * (i + 1) / FADE_STEPS
    piece(d0, d1, smooth((i + 0.5) / FADE_STEPS))
  end
  piece(fade_in_end, fade_out_start, 1)
  for i = 0, FADE_STEPS - 1 do
    local d0 = fade_out_start + (RANGE - fade_out_start) * i / FADE_STEPS
    local d1 = fade_out_start + (RANGE - fade_out_start) * (i + 1) / FADE_STEPS
    piece(d0, d1, smooth(1 - (i + 0.5) / FADE_STEPS))
  end

  rendering.draw_light({surface = surface, sprite = "utility/light_small", target = point(start),
    scale = 1.5, intensity = 0.8, color = {r = 0.6, g = 0.8, b = 1.0}, time_to_live = 8})
  storage.streaks[#storage.streaks + 1] = {objects = objects, born = game.tick}

  -- Fog: a puff every FOG_SPACING tiles along the line, with extra rows spread across wide slugs.
  if prototypes.trivial_smoke[FOG] then
    local rows = math.min(8, math.max(1, math.ceil(w / 2)))
    local spread = math.max(0.15, (rows > 1) and half * 0.8 or 0.15)
    local px, py = -uy, ux -- perpendicular
    local d = start
    while d <= RANGE do
      local base = point(d)
      for _ = 1, rows do
        local off = (math.random() * 2 - 1) * spread
        surface.create_trivial_smoke({
          name = FOG,
          position = {
            x = base.x + px * off + (math.random() - 0.5) * 0.3,
            y = base.y + py * off + (math.random() - 0.5) * 0.3,
          },
        })
      end
      d = d + FOG_SPACING
    end
  end

  surface.play_sound({path = SOUND, position = pos})
end

-- Railguns in a grid that are charged and off cooldown. With the one-per-grid limit on,
-- only the best-quality railgun in the grid counts, even if more got in some other way.
local function ready_railguns(grid, tick)
  local candidates = {}
  for _, eq in pairs(grid.equipment) do
    if eq.name == NAME then candidates[#candidates + 1] = eq end
  end
  if not allow_multiple() and #candidates > 1 then
    local best = candidates[1]
    for i = 2, #candidates do
      if candidates[i].quality.level > best.quality.level then best = candidates[i] end
    end
    candidates = {best}
  end

  local ready
  local gid = grid.unique_id
  for _, eq in ipairs(candidates) do
    if eq.energy >= SHOT_J then
      local key = gid .. ":" .. eq.position.x .. "," .. eq.position.y
      if (storage.cool[key] or 0) <= tick then
        ready = ready or {}
        ready[#ready + 1] = {eq = eq, key = key}
      end
    end
  end
  return ready
end

local function try_fire(owner, grid, tick, forces_cache)
  if not (owner and owner.valid and grid and grid.valid) then return end
  if grid.count(NAME) == 0 then return end
  track_grid(grid)

  local ready = ready_railguns(grid, tick)
  if not ready then return end

  local force = owner.force
  local forces = forces_cache[force.index]
  if not forces then
    forces = enemy_forces(force)
    forces_cache[force.index] = forces
  end
  if #forces == 0 then return end

  local half = half_width()
  local enemies = gather_enemies(owner, forces, half)
  if #enemies == 0 then return end

  local ux, uy, hits = best_heading(enemies, half)
  if not hits then return end

  local gun = ready[1]
  gun.eq.energy = gun.eq.energy - SHOT_J
  storage.cool[gun.key] = tick + COOLDOWN

  local dmg = damage_per_hit()
  for _, e in ipairs(hits) do
    if e.valid then e.damage(dmg, force, "physical", owner, owner) end
  end
  draw_shot(owner.surface, owner.position, ux, uy, half)
end

script.on_nth_tick(SCAN_EVERY, function(event)
  local tick = event.tick
  local forces_cache = {}
  for _, player in pairs(game.connected_players) do
    local vehicle = player.vehicle
    if vehicle and vehicle.valid and vehicle.grid then
      try_fire(vehicle, vehicle.grid, tick, forces_cache)
    end
    local char = player.character
    if char and char.valid and char.grid then
      try_fire(char, char.grid, tick, forces_cache)
    end
  end
end)

---------------------------------------------------------------------------------------------------
-- Streak fade

script.on_nth_tick(2, function()
  local list = storage.streaks
  if not list or #list == 0 then return end
  for i = #list, 1, -1 do
    local s = list[i]
    local age = game.tick - s.born
    if age >= STREAK_TICKS then
      for _, o in pairs(s.objects) do
        if o.obj.valid then o.obj.destroy() end
      end
      table.remove(list, i)
    else
      local k = 1 - age / STREAK_TICKS
      k = k * k -- quick flash, slow tail
      for _, o in pairs(s.objects) do
        if o.obj.valid then
          local c = o.color
          o.obj.color = {r = c.r * k, g = c.g * k, b = c.b * k, a = c.a * k}
        end
      end
    end
  end
end)
