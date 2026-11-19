local G = "__WePlayRailgunEquipment__/graphics/"
local s = settings.startup

local shot_mj = s["wp-railgun-shot-energy"].value

local NAME = "wp-personal-railgun-equipment"
local NOAMMO = NAME .. "-no-ammo"
local SLUG = "wp-railgun-slug"

-- With Space Age, Space Exploration or Krastorio 2 the railgun fires that mod's railgun ammo and is
-- unlocked by its railgun research. Without any of them, it fires our own slug and has its own research.
local host_tech
if mods["space-age"] and data.raw.technology["railgun"] and data.raw.ammo["railgun-ammo"] then
  host_tech = data.raw.technology["railgun"]
elseif mods["space-exploration"] and data.raw.technology["se-railgun"] and data.raw.ammo["se-railgun-ammo"] then
  host_tech = data.raw.technology["se-railgun"]
elseif mods["Krastorio2"] and data.raw.technology["kr-railgun-turret"] and data.raw.ammo["kr-basic-railgun-shell"] then
  host_tech = data.raw.technology["kr-railgun-turret"]
end

-- Fog left behind by the slug: a copy of a vanilla smoke, made pale, slow and long-lived.
local fog
for _, base_name in pairs({"light-smoke", "smoke-fast", "smoke", "turbine-smoke"}) do
  local src = data.raw["trivial-smoke"][base_name]
  if src then
    fog = table.deepcopy(src)
    break
  end
end
if fog then
  fog.name = "wp-railgun-fog"
  fog.color = {r = 0.78, g = 0.86, b = 1.0, a = 0.45}
  fog.duration = 300
  fog.fade_in_duration = 0
  fog.fade_away_duration = 240
  fog.spread_duration = 300
  fog.start_scale = 0.35
  fog.end_scale = 1.8
  fog.affected_by_wind = true
  fog.movement_slow_down_factor = 0.97
  fog.cyclic = true
  fog.show_when_smoke_off = true
  data:extend({fog})
end

-- Charge-only battery: the grid fills it, control.lua spends it on shots and idle drain,
-- and control.lua also does all of the targeting and firing.
local function railgun_equipment(name, sprite_file)
  return {
    type = "battery-equipment",
    name = name,
    take_result = NAME,
    sprite = {
      filename = G .. "equipment/" .. sprite_file,
      width = 256,
      height = 256,
      priority = "medium",
      scale = 0.5,
    },
    shape = {width = 4, height = 4, type = "full"},
    energy_source = {
      type = "electric",
      usage_priority = "secondary-input",
      buffer_capacity = (shot_mj * 1.2) .. "MJ",
      input_flow_limit = shot_mj .. "MW", -- refills a full shot in about a second
      output_flow_limit = "0W",
    },
    categories = {"armor"},
  }
end

data:extend({
  {
    type = "sound",
    name = "wp-railgun-shot",
    filename = "__WePlayRailgunEquipment__/sounds/railgun-shot.ogg",
    category = "weapon",
    volume = 0.8,
    audible_distance_modifier = 1.5,
  },
  {
    type = "item",
    name = NAME,
    icon = G .. "icons/personal-railgun-equipment.png",
    icon_size = 64,
    place_as_equipment_result = NAME,
    subgroup = "military-equipment",
    order = "b[active-defense]-z[wp-railgun]",
    stack_size = 10,
  },
  railgun_equipment(NAME, "personal-railgun-equipment.png"),
  {
    type = "recipe",
    name = NAME,
    enabled = false,
    energy_required = 60,
    ingredients = {
      {type = "item", name = "personal-laser-defense-equipment", amount = 2},
      {type = "item", name = "processing-unit", amount = 50},
      {type = "item", name = "low-density-structure", amount = 25},
      {type = "item", name = "battery-mk2-equipment", amount = 1},
    },
    results = {{type = "item", name = NAME, amount = 1}},
  },
})

-- Swapped in by control.lua while the wearer has no ammo. Same look as the Personal Rocket Launcher
-- Equipment: dimmed, with the game's red no-ammo icon on top at half the equipment's size.
do
  local no_ammo_eq = railgun_equipment(NOAMMO, "personal-railgun-equipment.png")
  local dimmed = table.deepcopy(no_ammo_eq.sprite)
  dimmed.tint = {r = 0.55, g = 0.55, b = 0.55, a = 1}
  local utility = data.raw["utility-sprites"] and data.raw["utility-sprites"]["default"]
  local icon = utility and utility.ammo_icon and table.deepcopy(utility.ammo_icon)
  if icon and icon.filename then
    local size = icon.width or icon.size or 64
    if type(size) == "table" then size = size[1] end
    icon.scale = 64 / size -- half of the 128 px the railgun is drawn at
    icon.shift = nil
    icon.priority = "medium"
    no_ammo_eq.sprite = {layers = {dimmed, icon}}
  else
    no_ammo_eq.sprite = dimmed
  end
  data:extend({no_ammo_eq})
end

if host_tech then
  -- Unlocked alongside that mod's railgun.
  host_tech.effects = host_tech.effects or {}
  table.insert(host_tech.effects, {type = "unlock-recipe", recipe = NAME})
else
  data:extend({
    -- Our own ammo: an endgame round.
    {
      type = "item",
      name = SLUG,
      icon = G .. "icons/railgun-slug.png",
      icon_size = 64,
      subgroup = "ammo",
      order = "d[cannon-shell]-z[wp-railgun-slug]",
      stack_size = 50,
    },
    {
      type = "recipe",
      name = SLUG,
      enabled = false,
      energy_required = 16,
      ingredients = {
        {type = "item", name = "explosives", amount = 4},
        {type = "item", name = "plastic-bar", amount = 4},
        {type = "item", name = "low-density-structure", amount = 4},
      },
      results = {{type = "item", name = SLUG, amount = 1}},
    },
    {
      type = "technology",
      name = NAME,
      icon = G .. "technology/personal-railgun-equipment.png",
      icon_size = 256,
      prerequisites = {"personal-laser-defense-equipment", "military-4"},
      effects = {
        {type = "unlock-recipe", recipe = NAME},
        {type = "unlock-recipe", recipe = SLUG},
      },
      unit = {
        count = 500,
        time = 60,
        ingredients = {
          {"automation-science-pack", 1},
          {"logistic-science-pack", 1},
          {"military-science-pack", 1},
          {"chemical-science-pack", 1},
          {"production-science-pack", 1},
          {"utility-science-pack", 1},
        },
      },
    },
  })
end
