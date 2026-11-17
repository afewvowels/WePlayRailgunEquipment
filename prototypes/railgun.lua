local G = "__WePlayRailgunEquipment__/graphics/"
local s = settings.startup

local shot_mj = s["wp-railgun-shot-energy"].value

local NAME = "wp-personal-railgun-equipment"

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
  -- Charge-only battery: the grid fills it, control.lua spends it on shots and idle drain,
  -- and control.lua also does all of the targeting and firing.
  {
    type = "battery-equipment",
    name = NAME,
    sprite = {
      filename = G .. "equipment/personal-railgun-equipment.png",
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
  },
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
  {
    type = "technology",
    name = NAME,
    icon = G .. "technology/personal-railgun-equipment.png",
    icon_size = 256,
    prerequisites = {"personal-laser-defense-equipment", "military-4"},
    effects = {{type = "unlock-recipe", recipe = NAME}},
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
