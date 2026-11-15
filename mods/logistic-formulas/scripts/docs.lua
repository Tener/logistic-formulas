-- Function documentation shared by the Factoriopedia pages (data stage) and the editor's
-- tooltips (runtime). Signatures come from the specs in lang.lua and the examples are checked
-- by the test suite; the prose is in the locale, in the [logf-fn-*] sections.
local lang = require("scripts.lang")

local docs = {}

-- Function families, in Factoriopedia order, with the color of their name in the editor.
-- tools/make-icons.py draws the icons in the same families.
docs.families = {
  {name = "sources", color = "115,185,255", functions = {"group", "constant", "network", "ingredients", "products"}},
  {name = "arithmetic", color = "130,230,130", functions = {"sum", "subtract", "multiply", "divide"}},
  {name = "clamping", color = "255,185,90", functions = {"highest", "lowest", "at-least", "at-most", "keep-positive"}},
  {name = "quality", color = "210,150,255", functions = {"quality-up", "quality-down", "set-quality"}},
  {name = "stacks", color = "245,215,90", functions = {"round-to-stacks", "set-stacks"}},
  {name = "filtering", color = "90,230,230", functions = {"keep", "drop"}},
  {name = "settings", color = "255,140,155",
    functions = {"set-max", "no-max", "get-max", "import-from", "request-from", "min-delivery"}},
}

docs.family_of = {}
for _, family in ipairs(docs.families) do
  for _, fn in ipairs(family.functions) do docs.family_of[fn] = family end
end
for _, fn in ipairs(lang.order) do assert(docs.family_of[fn], "no family for " .. fn) end

-- Functions whose arguments are not plain parameters: how they are written, and their parts.
local SPECIAL = {
  group = {
    forms = {'(group "name")'},
    params = {{word = "name", kind = "name of a group"}},
  },
  constant = {
    forms = {"{signal count ...}", "(constant signal count ...)"},
    params = {{word = "signal", kind = "[type/]name[:quality], repeats"}, {word = "count", kind = "number, after each signal"}},
  },
  network = {
    forms = {'(network "name" [member])', '(network "surface" x y [member])'},
    params = {
      {word = "name", kind = "name of a logistic network"},
      {word = "surface x y", kind = "surface name and a position"},
      {word = "member", kind = "all, storage or providers; optional, default all"},
    },
  },
}

local KIND = {
  bag = "group", number = "number", value = "group or number", recipe = "recipe", quality = "quality",
  ["space-location"] = "space location or anywhere", ["request-source"] = "planet, platforms or all",
  filter = "signal or group",
}

local function word(param) return (param.name:gsub(" ", "-")) end

local function number_text(n)
  if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
  return (string.format("%.4f", n):gsub("0+$", ""))
end

-- How the function is written: one line per form.
function docs.forms(name)
  if SPECIAL[name] then return SPECIAL[name].forms end
  local spec = lang.functions[name]
  local parts = {"(" .. name}
  for _, p in ipairs(spec.params) do parts[#parts + 1] = word(p) end
  for _, p in ipairs(spec.optional or {}) do parts[#parts + 1] = "[" .. word(p) .. "]" end
  -- A repeated parameter that is also the last required one reads "minus ...", not "minus minus ...".
  if spec.rest and parts[#parts] == word(spec.rest) then parts[#parts] = parts[#parts] .. " ..."
  elseif spec.rest then parts[#parts + 1] = word(spec.rest) .. " ..." end
  return {table.concat(parts, " ") .. ")"}
end

-- Parameters as {word, kind, key}: key names the parameter's description in [logf-fn-param].
function docs.params(name)
  local out = {}
  if SPECIAL[name] then
    for _, p in ipairs(SPECIAL[name].params) do
      out[#out + 1] = {word = p.word, kind = p.kind, key = name .. "-" .. p.word:gsub(" ", "-")}
    end
    return out
  end
  local spec = lang.functions[name]
  local function push(p, suffix)
    out[#out + 1] = {word = word(p), kind = KIND[p.type] .. suffix, key = name .. "-" .. word(p)}
  end
  for _, p in ipairs(spec.params) do push(p, "") end
  for _, p in ipairs(spec.optional or {}) do push(p, ", optional, default " .. number_text(p.default)) end
  if spec.rest and out[#out] and out[#out].word == word(spec.rest) then out[#out].kind = out[#out].kind .. ", repeats"
  elseif spec.rest then push(spec.rest, ", repeats") end
  return out
end

-- Examples: a formula, what it reads, and its exact result, checked by the test suite.
-- `given` holds the groups and networks the formula reads (networks as "name/member") and the
-- best unlocked quality. Result entries are {signal, count, settings...}, leaving out signals at 0,
-- which are never written; a number result is a number.
docs.examples = {
  group = {{
    given = {groups = {mall = {{"transport-belt", 200, max = 400}}}},
    expr = '(sum (group "mall") {pipe 50})',
    result = {{"transport-belt", 200, max = 400}, {"pipe", 50}},
  }},
  constant = {{
    expr = "{iron-plate 100 iron-plate:rare 5 fluid/water 1k iron-plate 50}",
    result = {{"iron-plate", 150}, {"iron-plate:rare", 5}, {"fluid/water", 1000}},
  }},
  network = {{
    given = {networks = {["Main/storage"] = {{"iron-plate", 400}, {"copper-plate", 120}}}},
    expr = '(network "Main" storage)',
    result = {{"iron-plate", 400}, {"copper-plate", 120}},
  }},
  ingredients = {{
    expr = "(ingredients electronic-circuit 10)",
    result = {{"iron-plate", 10}, {"copper-cable", 30}},
  }},
  products = {{
    expr = "(products uranium-processing 1k)",
    result = {{"uranium-235", 7}, {"uranium-238", 993}},
  }},
  sum = {{
    expr = "(sum {iron-plate 100 pipe 10} {iron-plate 50 copper-plate 20})",
    result = {{"iron-plate", 150}, {"pipe", 10}, {"copper-plate", 20}},
  }, {
    expr = "(sum 10 20 5)",
    result = 35,
  }},
  subtract = {{
    expr = "(subtract {iron-plate 100 pipe 10} {iron-plate 30 copper-plate 20})",
    result = {{"iron-plate", 70}, {"pipe", 10}, {"copper-plate", -20}},
  }},
  multiply = {{
    expr = "(multiply 1.5 {iron-plate 100 pipe 10})",
    result = {{"iron-plate", 150}, {"pipe", 15}},
  }},
  divide = {{
    expr = "(divide {iron-plate 10 pipe 3} 4)",
    result = {{"iron-plate", 2.5}, {"pipe", 0.75}},
  }},
  highest = {{
    expr = "(highest {iron-plate 100 pipe 10} {iron-plate 50 copper-plate 20})",
    result = {{"iron-plate", 100}, {"pipe", 10}, {"copper-plate", 20}},
  }},
  lowest = {{
    expr = "(lowest {iron-plate 100 pipe 10} {iron-plate 50 copper-plate 20})",
    result = {{"iron-plate", 50}},
  }},
  ["at-least"] = {{
    expr = "(at-least {iron-plate 100 pipe 10} 50)",
    result = {{"iron-plate", 100}, {"pipe", 50}},
  }},
  ["at-most"] = {{
    expr = "(at-most {iron-plate 100 pipe 10} 50)",
    result = {{"iron-plate", 50}, {"pipe", 10}},
  }},
  ["keep-positive"] = {{
    expr = "(keep-positive {iron-plate 70 pipe 0 copper-plate -20})",
    result = {{"iron-plate", 70}},
  }},
  ["quality-up"] = {{
    given = {unlocked = "rare"},
    expr = "(quality-up {iron-plate 10 iron-plate:uncommon 5} 2)",
    result = {{"iron-plate:rare", 15}},
  }},
  ["quality-down"] = {{
    expr = "(quality-down {iron-plate:rare 10 iron-plate:uncommon 5})",
    result = {{"iron-plate:uncommon", 10}, {"iron-plate", 5}},
  }},
  ["set-quality"] = {{
    expr = "(set-quality {iron-plate 10 iron-plate:rare 5 fluid/water 100} epic)",
    result = {{"iron-plate:epic", 15}, {"fluid/water", 100}},
  }},
  ["round-to-stacks"] = {{
    expr = "(round-to-stacks {iron-plate 150 steel-chest 1 fluid/water 10})",
    result = {{"iron-plate", 200}, {"steel-chest", 50}, {"fluid/water", 10}},
  }},
  ["set-stacks"] = {{
    expr = "(set-stacks {iron-plate 1 steel-chest 12} 2)",
    result = {{"iron-plate", 200}, {"steel-chest", 100}},
  }},
  keep = {{
    expr = "(keep {iron-plate 100 iron-plate:rare 5 pipe 10} iron-plate)",
    result = {{"iron-plate", 100}, {"iron-plate:rare", 5}},
  }, {
    expr = "(keep {iron-plate 100 iron-plate:rare 5 pipe 10} iron-plate:rare pipe)",
    result = {{"iron-plate:rare", 5}, {"pipe", 10}},
  }},
  drop = {{
    expr = "(drop {iron-plate 100 iron-plate:rare 5 pipe 10} iron-plate)",
    result = {{"pipe", 10}},
  }},
  ["set-max"] = {{
    expr = "(set-max {iron-plate 100 pipe 10} 500)",
    result = {{"iron-plate", 100, max = 500}, {"pipe", 10, max = 500}},
  }, {
    expr = "(set-max {iron-plate 100 pipe 10} {iron-plate 300})",
    result = {{"iron-plate", 100, max = 300}, {"pipe", 10}},
  }},
  ["no-max"] = {{
    expr = "(no-max (set-max {iron-plate 100} 500))",
    result = {{"iron-plate", 100}},
  }},
  ["get-max"] = {{
    expr = "(get-max (set-max {iron-plate 100 pipe 10} {iron-plate 300}))",
    result = {{"iron-plate", 300}},
  }},
  ["import-from"] = {{
    expr = "(import-from {iron-plate 100} nauvis)",
    result = {{"iron-plate", 100, import_from = "nauvis"}},
  }},
  ["request-from"] = {{
    expr = "(request-from {iron-plate 100} platforms)",
    result = {{"iron-plate", 100, request_from = "platforms"}},
  }},
  ["min-delivery"] = {{
    expr = "(min-delivery {iron-plate 1k pipe 100} 200)",
    result = {{"iron-plate", 1000, min_delivery = 200}, {"pipe", 100, min_delivery = 200}},
  }},
}
for _, fn in ipairs(lang.order) do assert(docs.examples[fn], "no example for " .. fn) end

-- Sheets quoted by the guide pages and tips, by locale key, in the order of their __N__
-- parameters. The test suite evaluates each; groups a snippet does not define read as empty.
docs.snippets = {
  ["logf-doc-overview"] = {[[
(def "mall" {transport-belt 200 inserter 50 small-electric-pole 50})
(def "mall rare" (set-quality (group "mall") rare))]]},
  ["logf-doc-settings"] = {
    [[(set-max (sum (group "mall") {iron-plate 50}) 400)]],
    [[
(def "platform order"
  (min-delivery
    (import-from (set-max {iron-plate 400 copper-plate 400} 800) nauvis)
    100))]],
  },
  ["logf-doc-strategy-mall"] = {
    [[
(def "mall" {transport-belt 200 inserter 50 assembling-machine-2 20})
(def "mall rare" (set-quality (group "mall") rare))
(def "mall rare, no belts" (drop (group "mall rare") transport-belt))]],
    [[
(def "mall short"
  (keep-positive (subtract (group "mall") (network "Main" providers))))]],
    [[
(def "circuit line" (round-to-stacks (ingredients electronic-circuit 200)))]],
    [[
(def "train load" (round-to-stacks (multiply 4 (group "mall"))))
(def "personal" (set-max (group "mall") (multiply 2 (group "mall"))))]],
  },
  ["logf-doc-strategy-space"] = {
    [[
(def "platform base" {iron-plate 400 copper-plate 400 low-density-structure 40})
(def "platform order"
  (min-delivery
    (import-from
      (set-max (group "platform base") (multiply 2 (group "platform base")))
      nauvis)
    100))]],
    [[
(def "ship"
  (sum (import-from (group "from nauvis") nauvis)
       (import-from (group "from vulcanus") vulcanus)))]],
    [[
(def "fuel relay" (request-from {rocket-fuel 200} platforms))]],
    [[
(def "silo feed" (ingredients rocket-part 50))]],
  },
  ["logf-overview"] = {[[
(def "mall" {transport-belt 200 inserter 50})
(def "mall rare" (set-quality (group "mall") rare))]]},
  ["logf-restock"] = {[[
(def "mall" {transport-belt 200 inserter 50})
(def "mall short"
  (keep-positive (subtract (group "mall") (network "Main" storage))))]]},
}

-- Tips and tricks entries, the first being the category's title.
docs.tips = {
  {name = "logf-overview", tag = "[img=logf-formulas]"},
  {name = "logf-restock", tag = "[virtual-signal=logf-fn-keep-positive]"},
  {name = "logf-reference", tag = "[virtual-signal=logf-doc-language]"},
}

-- A locale key's text with its snippets as code blocks.
function docs.with_snippets(section, key)
  local out = {section .. "." .. key}
  for i, snippet in ipairs(docs.snippets[key] or {}) do
    out[i + 1] = docs.concat{"[font=logf-mono]" .. snippet:gsub("^\n", "") .. "[/font]"}
  end
  return out
end

local RICH = {
  item = "item", fluid = "fluid", virtual = "virtual-signal", entity = "entity", recipe = "recipe",
  ["space-location"] = "space-location", ["asteroid-chunk"] = "asteroid-chunk", quality = "quality",
}

-- Rich text icon of a signal.
function docs.rich(type, name, quality)
  local text = "[" .. (RICH[type] or "item") .. "=" .. name
  if quality and quality ~= "normal" then text = text .. ",quality=" .. quality end
  return text .. "]"
end

-- "[type/]name[:quality]" -> type, name, quality, without looking up prototypes: examples
-- write a type for every signal that is not an item.
local function split_signal(token)
  local rest, quality = token:match("^(.-):([^:/]+)$")
  if not rest then rest, quality = token, "normal" end
  local type, name = rest:match("^([^/]+)/(.+)$")
  if not type then type, name = "item", rest end
  return type, name, quality
end

local function entry_text(entry)
  local text = docs.rich(split_signal(entry[1])) .. " " .. number_text(entry[2])
  local parts = {}
  if entry.max then parts[#parts + 1] = "max " .. number_text(entry.max) end
  if entry.import_from then parts[#parts + 1] = "from [space-location=" .. entry.import_from .. "]" end
  if entry.request_from then parts[#parts + 1] = "request from " .. entry.request_from end
  if entry.min_delivery then parts[#parts + 1] = "min delivery " .. number_text(entry.min_delivery) end
  if #parts > 0 then text = text .. " (" .. table.concat(parts, ", ") .. ")" end
  return text
end

local function value_text(value)
  if type(value) == "number" then return number_text(value) end
  local parts = {}
  for i, entry in ipairs(value) do parts[i] = entry_text(entry) end
  return table.concat(parts, "   ")
end

-- An example as rich text: what it reads, the formula, and the result.
function docs.example_text(example)
  local lines = {}
  local given = example.given or {}
  for name, entries in pairs(given.groups or {}) do
    lines[#lines + 1] = 'group "' .. name .. '" holds ' .. value_text(entries)
  end
  for key, entries in pairs(given.networks or {}) do
    local network, member = key:match("^(.*)/(.*)$")
    lines[#lines + 1] = 'network "' .. network .. '" ' .. member .. " holds " .. value_text(entries)
  end
  if given.unlocked then lines[#lines + 1] = "best unlocked quality: [quality=" .. given.unlocked .. "]" end
  lines[#lines + 1] = "[font=logf-mono]" .. example.expr .. "[/font]"
  lines[#lines + 1] = "→ " .. value_text(example.result)
  return table.concat(lines, "\n")
end

-- Localised strings take at most 20 parameters, and strings of at most 200 characters.
local MAX_PARAMS, MAX_STRING = 19, 200

-- Pieces of at most MAX_STRING bytes, never splitting a UTF-8 character.
local function chunks(text)
  local out, i = {}, 1
  while i <= #text do
    local j = math.min(i + MAX_STRING - 1, #text)
    while j < #text and text:byte(j + 1) >= 0x80 and text:byte(j + 1) < 0xC0 do j = j - 1 end
    out[#out + 1] = text:sub(i, j)
    i = j + 1
  end
  return out
end

-- Concatenates text and localised strings into one localised string within the engine's limits.
function docs.concat(parts)
  local flat = {}
  for _, part in ipairs(parts) do
    if type(part) == "string" and #part > MAX_STRING then
      for _, chunk in ipairs(chunks(part)) do flat[#flat + 1] = chunk end
    else
      flat[#flat + 1] = part
    end
  end
  if #flat <= MAX_PARAMS then return {"", table.unpack(flat)} end
  local out = {""}
  for i = 1, #flat, MAX_PARAMS do out[#out + 1] = docs.concat({table.unpack(flat, i, math.min(i + MAX_PARAMS - 1, #flat))}) end
  return out
end

-- The parameters as a localised string: one line each, name, kind and description.
function docs.params_text(name)
  local parts = {}
  for i, p in ipairs(docs.params(name)) do
    if i > 1 then parts[#parts + 1] = "\n" end
    parts[#parts + 1] = "[font=default-semibold]" .. p.word .. "[/font] [color=0.7,0.7,0.7](" .. p.kind .. ")[/color]  "
    parts[#parts + 1] = {"logf-fn-param." .. p.key}
  end
  return docs.concat(parts)
end

function docs.forms_text(name)
  return docs.concat{"[font=logf-mono]" .. table.concat(docs.forms(name), "\n") .. "[/font]"}
end

function docs.examples_text(name)
  local texts = {}
  for i, example in ipairs(docs.examples[name]) do texts[i] = docs.example_text(example) end
  return docs.concat{table.concat(texts, "\n\n")}
end

-- The editor's tooltip on a function: how it is written, what it does, its parameters and an example.
function docs.tooltip(name)
  if not lang.functions[name] then return "" end
  return docs.concat{
    "[img=logf-fn-" .. name .. "] ", docs.forms_text(name), "\n",
    {"logf-fn-summary." .. name}, "\n\n",
    docs.params_text(name), "\n\n",
    docs.example_text(docs.examples[name][1]), "\n\n",
    "[color=0.7,0.7,0.7]? beside the function opens its full reference.[/color]",
  }
end

return docs
