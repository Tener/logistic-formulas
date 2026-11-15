-- Holds the sections through which formulas write their logistic groups.
local owner = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
owner.name = "logf-group-owner"
owner.hidden = true
owner.minable = nil
owner.flags = {"not-on-map", "not-blueprintable", "not-deconstructable", "not-rotatable"}
data:extend{owner}

local function icon(name, file)
  return {type = "sprite", name = name, filename = "__logistic-formulas__/graphics/icons/" .. file .. ".png", size = 32,
    flags = {"gui-icon"}}
end

data:extend{
  {
    type = "font",
    name = "logf-mono",
    from = "default-mono",
    size = 12,
  },
  {
    type = "shortcut",
    name = "logf-formulas",
    order = "c[circuit]-g[logistic-formulas]",
    action = "lua",
    toggleable = true,
    icon = "__logistic-formulas__/graphics/icons/shortcut-x56.png",
    icon_size = 56,
    small_icon = "__logistic-formulas__/graphics/icons/shortcut-x24.png",
    small_icon_size = 24,
  },
  {
    type = "sprite",
    name = "logf-formulas",
    filename = "__logistic-formulas__/graphics/icons/mod-icon.png",
    size = 128,
    flags = {"gui-icon"},
  },
  icon("logf-pin-white", "pin-white"),
  icon("logf-pin-black", "pin-black"),
  icon("logf-larger-white", "larger-white"),
  icon("logf-larger-black", "larger-black"),
  icon("logf-smaller-white", "smaller-white"),
  icon("logf-smaller-black", "smaller-black"),
  icon("logf-maximize-white", "maximize-white"),
  icon("logf-maximize-black", "maximize-black"),
  icon("logf-wrap", "wrap"),
  icon("logf-undo", "undo"),
  icon("logf-redo", "redo"),
  {
    -- Follows the player's binding for the game's own search (Ctrl+F by default).
    type = "custom-input",
    name = "logf-focus-search",
    key_sequence = "",
    linked_game_control = "focus-search",
    action = "lua",
  },
  {
    type = "custom-input",
    name = "logf-formulas",
    key_sequence = "CONTROL + SHIFT + G",
    action = "lua",
  },
}

for _, name in ipairs(require("scripts.lang").order) do
  data:extend{{type = "sprite", name = "logf-fn-" .. name, size = 64, flags = {"gui-icon"},
    filename = "__logistic-formulas__/graphics/icons/fn-" .. name .. ".png"}}
end

-- Factoriopedia tab: the guide pages, then one page per function, by family.
local docs = require("scripts.docs")

data:extend{
  {
    type = "item-group",
    name = "logistic-formulas",
    order = "z[logistic-formulas]",
    icon = "__logistic-formulas__/graphics/icons/mod-icon.png",
    icon_size = 128,
  },
  {type = "item-subgroup", name = "logf-guide", group = "logistic-formulas", order = "a"},
}
for i, family in ipairs(docs.families) do
  data:extend{{type = "item-subgroup", name = "logf-" .. family.name, group = "logistic-formulas",
    order = string.format("b%02d", i)}}
end

local function field(name, value, order)
  return {name = {"logf-field." .. name}, value = value, order = order, show_in_tooltip = false,
    show_in_factoriopedia = true}
end

local GUIDES = {"overview", "language", "settings", "editor", "strategy-mall", "strategy-space"}
for i, key in ipairs(GUIDES) do
  local proto_name = "logf-doc-" .. key
  data:extend{{
    type = "virtual-signal",
    name = proto_name,
    subgroup = "logf-guide",
    order = string.format("%02d", i),
    icon = "__logistic-formulas__/graphics/icons/doc-" .. key .. ".png",
    icon_size = 64,
    factoriopedia_description = docs.with_snippets("factoriopedia-description", proto_name),
    custom_tooltip_fields = {field("related", {"logf-doc-related." .. key}, 1)},
  }}
end

for _, name in ipairs(require("scripts.lang").order) do
  local family = docs.family_of[name]
  local order = 0
  for i, fn in ipairs(family.functions) do if fn == name then order = i end end
  data:extend{{
    type = "virtual-signal",
    name = "logf-fn-" .. name,
    localised_name = name,
    localised_description = {"logf-fn-summary." .. name},
    subgroup = "logf-" .. family.name,
    order = string.format("%02d", order),
    icon = "__logistic-formulas__/graphics/icons/fn-" .. name .. ".png",
    icon_size = 64,
    factoriopedia_description = {"", {"logf-fn-summary." .. name}, "\n\n", {"logf-fn-details." .. name}},
    custom_tooltip_fields = {
      field("syntax", docs.forms_text(name), 1),
      field("params", docs.params_text(name), 2),
      field("returns", {"logf-fn-returns." .. name}, 3),
      field("settings", {"logf-fn-settings." .. name}, 4),
      field("examples", docs.examples_text(name), 5),
      field("related", {"logf-fn-related." .. name}, 6),
    },
  }}
end

-- Tips and tricks: a short introduction that points into Factoriopedia.
data:extend{{type = "tips-and-tricks-item-category", name = "logistic-formulas", order = "z-[logistic-formulas]"}}
for i, tip in ipairs(docs.tips) do
  data:extend{{
    type = "tips-and-tricks-item",
    name = tip.name,
    localised_description = docs.with_snippets("tips-and-tricks-item-description", tip.name),
    category = "logistic-formulas",
    order = string.format("%02d", i),
    is_title = i == 1 or nil,
    indent = i > 1 and 1 or nil,
    starting_status = "unlocked",
    dependencies = i > 1 and {docs.tips[1].name} or nil,
    tag = tip.tag,
  }}
end
