-- Functional tests, one case per process: tools/factorio-test.sh mods logistic-formulas/test CASE
local sexp = require("__logistic-formulas__/scripts/sexp")
local lang = require("__logistic-formulas__/scripts/lang")
local docs = require("__logistic-formulas__/scripts/docs")
local mod_gui = require("mod-gui")

local function finish(label)
  print("[TEST] " .. label .. ": passed")
  script.finish_test(true)
end

local function lab()
  local s = game.create_surface("lab")
  s.request_to_generate_chunks({0, 0}, 3)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities()) do e.destroy() end
  local tiles = {}
  for x = -64, 63 do for y = -64, 63 do tiles[#tiles + 1] = {name = "refined-concrete", position = {x, y}} end end
  s.set_tiles(tiles)
  return s
end

local function make(name, position, extra, modules)
  local spec = {name = name, position = position, force = "player"}
  for k, v in pairs(extra or {}) do spec[k] = v end
  local e = assert(storage.surface.create_entity(spec), "could not create " .. name)
  if modules then
    local inserted = e.get_module_inventory().insert(modules)
    assert(inserted == modules.count, "modules did not fit in " .. name)
  end
  return e
end

local function powered(position)
  local source = make("electric-energy-interface", position)
  source.power_production = 1e9
  source.electric_buffer_size = 1e9
end

local CASES = {}

local function call(method, ...) return remote.call("logistic-formulas", method, ...) end

-- The editor of the formula window's selected sheet tab.
local function editor_in(w)
  local pane = w.children[2].pane
  return pane.tabs[pane.selected_tab_index].content.editor
end

-- Reader and printer round trips.
CASES.sexp = function(tick)
  if tick ~= 1 then return end
  local text = '(def "a b" (+ (group "x") {iron-plate 100 fluid/water 2.5 copper-plate:rare 1}))\n(def "c" (* (group "a b") -3))'
  local forms = assert(sexp.parse(text))
  assert(#forms == 2 and forms[1][2].str == "a b" and forms[1][3][1].sym == "+", "structure")
  assert(forms[1][3][3][1].sym == "constant" and forms[1][3][3][5] == 2.5, "braces read as a constant")
  assert(sexp.print_program(forms) == text, "round trip:\n" .. sexp.print_program(forms))
  local commented = assert(sexp.parse('; note\n(def x ; trailing\n  (group "say \\"hi\\""))'))
  assert(commented[1][3][2].str == 'say "hi"', "escapes")
  assert(sexp.print(commented[1]) == '(def x (group "say \\"hi\\""))', "escapes print")
  local long = assert(sexp.parse('(def "long" (+ (group "one group") (group "another group") (* (group "third group") 5) {iron-plate 1}))'))
  local printed = sexp.print_program(long)
  assert(printed:find("\n"), "long forms wrap")
  assert(sexp.print(assert(sexp.parse(printed))[1]) == sexp.print(long[1]), "wrapped text reads back")
  for bad, want in pairs{["(def a"] = "missing %)", ["(a))"] = "unexpected %)", ['"abc'] = "unterminated", ["\n\n{a 1"] = "line 3"} do
    local ok, err = sexp.parse(bad)
    assert(not ok and err:find(want), "error for " .. bad .. ": " .. tostring(err))
  end
  finish("sexp")
end

-- Contents of a logistic group as "type/name/quality" -> count.
local function group(name)
  local g = game.forces.player.get_logistic_group(name)
  if not g then return nil end
  local out = {}
  for _, filter in pairs(g.filters) do
    if filter.value then out[filter.value.type .. "/" .. filter.value.name .. "/" .. filter.value.quality] = filter.min end
  end
  return out
end

local function expect_group(name, expected)
  local got = assert(group(name), "no group " .. name)
  for k, v in pairs(expected) do
    assert(got[k] == v, string.format("%s: %s expected %s, got %s", name, k, v, tostring(got[k])))
  end
  for k, v in pairs(got) do
    assert(expected[k], string.format("%s: unexpected %s = %s", name, k, v))
  end
end

local function set_program(text)
  local ok, err = call("set_program", "player", text)
  assert(ok, "program rejected: " .. tostring(err))
  return call("program_status", "player")
end

local function item(name, quality, count)
  return {value = {type = "item", name = name, quality = quality, comparator = "="}, min = count}
end

CASES.formulas = function(tick)
  local force = game.forces.player
  if tick == 1 then
    storage.surface = lab()
    for _, q in ipairs{"uncommon", "rare", "epic"} do force.unlock_quality(q) end
    force.lock_quality("legendary")
    local source = make("constant-combinator", {0.5, 0.5})
    local behavior = source.get_or_create_control_behavior()
    storage.mall = behavior.get_section(1)
    storage.mall.group = "mall"
    storage.mall.filters = {
      item("iron-plate", "normal", 150), item("copper-plate", "rare", 50), item("pipe", "epic", 7),
      {value = {type = "fluid", name = "water", quality = "normal", comparator = "="}, min = 10},
    }
    local have = behavior.add_section("have")
    have.filters = {item("iron-plate", "normal", 200), item("copper-plate", "rare", 20)}

    local status = set_program[[
      (def "up"      (quality-up (group "mall")))
      (def "up2"     (quality-up (group "mall") 2))
      (def "down"    (quality-down (group "mall")))
      (def "rare"    (set-quality (group "mall") rare))
      (def "triple"  (multiply 3 (group "mall")))
      (def "half"    (divide (group "mall") 4))
      (def "sum"     (sum (group "mall") (group "have") {iron-plate 1 repair-pack:uncommon 5}))
      (def "missing" (keep-positive (subtract (group "mall") (group "have"))))
      (def "delta"   (subtract (group "mall") (group "have")))
      (def "floor"   (at-least (group "mall") 20))
      (def "cap"     (at-most (group "mall") 20))
      (def "both"    (lowest (group "mall") (group "have")))
      (def "either"  (highest (group "mall") (group "have")))
      (def "round"   (round-to-stacks (group "mall")))
      (def "stacks"  (set-stacks (group "mall") 2))
      (def "only"    (keep (group "mall") iron-plate water))
      (def "without" (drop (group "mall") iron-plate water))
      (def "rare cu" (keep (group "mall") copper-plate:rare iron-plate:rare))
      (def "as have" (keep (group "mall") (group "have")))
      (def "chain"   (multiply (group "base") 2))
      (def "base"    (sum (group "up") {coal (sum 1 1)}))
    ]]
    for i, s in ipairs(status) do assert(not s.error, "definition " .. i .. ": " .. tostring(s.error)) end

    expect_group("up", {["item/iron-plate/uncommon"] = 150, ["item/copper-plate/epic"] = 50, ["item/pipe/epic"] = 7, ["fluid/water/normal"] = 10})
    expect_group("up2", {["item/iron-plate/rare"] = 150, ["item/copper-plate/epic"] = 50, ["item/pipe/epic"] = 7, ["fluid/water/normal"] = 10})
    expect_group("down", {["item/iron-plate/normal"] = 150, ["item/copper-plate/uncommon"] = 50, ["item/pipe/rare"] = 7, ["fluid/water/normal"] = 10})
    expect_group("rare", {["item/iron-plate/rare"] = 150, ["item/copper-plate/rare"] = 50, ["item/pipe/rare"] = 7, ["fluid/water/normal"] = 10})
    expect_group("triple", {["item/iron-plate/normal"] = 450, ["item/copper-plate/rare"] = 150, ["item/pipe/epic"] = 21, ["fluid/water/normal"] = 30})
    expect_group("half", {["item/iron-plate/normal"] = 38, ["item/copper-plate/rare"] = 13, ["item/pipe/epic"] = 2, ["fluid/water/normal"] = 3})
    expect_group("sum", {["item/iron-plate/normal"] = 351, ["item/copper-plate/rare"] = 70, ["item/pipe/epic"] = 7, ["fluid/water/normal"] = 10, ["item/repair-pack/uncommon"] = 5})
    expect_group("missing", {["item/copper-plate/rare"] = 30, ["item/pipe/epic"] = 7, ["fluid/water/normal"] = 10})
    expect_group("delta", {["item/iron-plate/normal"] = -50, ["item/copper-plate/rare"] = 30, ["item/pipe/epic"] = 7, ["fluid/water/normal"] = 10})
    expect_group("floor", {["item/iron-plate/normal"] = 150, ["item/copper-plate/rare"] = 50, ["item/pipe/epic"] = 20, ["fluid/water/normal"] = 20})
    expect_group("cap", {["item/iron-plate/normal"] = 20, ["item/copper-plate/rare"] = 20, ["item/pipe/epic"] = 7, ["fluid/water/normal"] = 10})
    expect_group("both", {["item/iron-plate/normal"] = 150, ["item/copper-plate/rare"] = 20})
    expect_group("either", {["item/iron-plate/normal"] = 200, ["item/copper-plate/rare"] = 50, ["item/pipe/epic"] = 7, ["fluid/water/normal"] = 10})
    expect_group("round", {["item/iron-plate/normal"] = 200, ["item/copper-plate/rare"] = 100, ["item/pipe/epic"] = 100, ["fluid/water/normal"] = 10})
    expect_group("stacks", {["item/iron-plate/normal"] = 200, ["item/copper-plate/rare"] = 200, ["item/pipe/epic"] = 200, ["fluid/water/normal"] = 10})
    expect_group("only", {["item/iron-plate/normal"] = 150, ["fluid/water/normal"] = 10})
    expect_group("without", {["item/copper-plate/rare"] = 50, ["item/pipe/epic"] = 7})
    expect_group("rare cu", {["item/copper-plate/rare"] = 50})
    expect_group("as have", {["item/iron-plate/normal"] = 150, ["item/copper-plate/rare"] = 50})
    expect_group("base", {["item/iron-plate/uncommon"] = 150, ["item/copper-plate/epic"] = 50, ["item/pipe/epic"] = 7, ["fluid/water/normal"] = 10, ["item/coal/normal"] = 2})
    expect_group("chain", {["item/iron-plate/uncommon"] = 300, ["item/copper-plate/epic"] = 100, ["item/pipe/epic"] = 14, ["fluid/water/normal"] = 20, ["item/coal/normal"] = 4})

    -- The text form survives a round trip through the stored definitions.
    local text = call("program_text", "player")
    set_program(text)
    assert(call("program_text", "player") == text, "program text is stable")
    expect_group("chain", {["item/iron-plate/uncommon"] = 300, ["item/copper-plate/epic"] = 100, ["item/pipe/epic"] = 14, ["fluid/water/normal"] = 20, ["item/coal/normal"] = 4})

    -- A requester chest in a computed group gets the requests.
    storage.chest = make("requester-chest", {4.5, 0.5})
    storage.requests = storage.chest.get_requester_point().add_section("missing")
    assert(storage.requests.filters_count == 3, "chest joins the computed group")

    -- Errors stay with their definition; the others keep working, and a broken one keeps its last output.
    status = set_program[[
      (def "oops"    (frobnicate (group "mall")))
      (def "missing" (keep-positive (subtract (group "mall") (group "nope"))))
      (def "loop-a"  (sum (group "loop-b")))
      (def "loop-b"  (sum (group "loop-a")))
      (def "number"  (sum 1 2))
      (def "up"      (quality-up (group "mall")))
      (def "up"      (group "mall"))
      (def "mixed"   (sum (group "mall") 1))
      (def "arity"   (divide (group "mall")))
      (def "badsig"  {no-such-thing 1})
      (def "fine"    (multiply (group "up") 2))
      (def "floored" (highest (group "mall") 1))
      (def "negated" (subtract (group "mall")))
      (def "two"     (multiply (group "mall") (group "mall")))
      (def "nofilter" (keep (group "mall")))
    ]]
    local wanted = {"unknown function", "no group named 'nope'", "", "depends on itself", "number, not a group", false,
      "already named", "cannot mix", "takes 2 arguments", "unknown item", false, "highest cannot mix",
      "at least 2 arguments", "at most one group", "at least 2 arguments"}
    for i, want in ipairs(wanted) do
      local err = status[i].error
      if want == false then assert(not err, "definition " .. i .. " should work: " .. tostring(err))
      else assert(err and err:find(want, 1, true), "definition " .. i .. " error: " .. tostring(err)) end
    end
    assert(status[3].error:find("loop%-b") or status[3].error:find("depends on itself"), "cycle reported: " .. status[3].error)
    expect_group("missing", {["item/copper-plate/rare"] = 30, ["item/pipe/epic"] = 7, ["fluid/water/normal"] = 10})
    expect_group("fine", {["item/iron-plate/uncommon"] = 300, ["item/copper-plate/epic"] = 100, ["item/pipe/epic"] = 14, ["fluid/water/normal"] = 20})
    assert(storage.requests.filters_count == 3, "chest keeps the last good requests")

    local ok, err = call("set_program", "player", "(def \"a\" (group \"mall\")")
    assert(not ok and err:find("line 1"), "syntax errors are rejected: " .. tostring(err))
    ok, err = call("set_program", "player", "(group \"mall\")")
    assert(not ok and err:find("expected %(def"), "non-definitions are rejected: " .. tostring(err))
    expect_group("fine", {["item/iron-plate/uncommon"] = 300, ["item/copper-plate/epic"] = 100, ["item/pipe/epic"] = 14, ["fluid/water/normal"] = 20})

    set_program[[
      (def "missing" (keep-positive (subtract (group "mall") (group "have"))))
      (def "up" (quality-up (group "mall")))
    ]]
    -- Changed without an event, as scripts and combinators do.
    storage.mall.filters = {item("iron-plate", "normal", 500), item("copper-plate", "legendary", 1), item("pipe", "epic", 7)}
  elseif tick == 40 then
    expect_group("missing", {["item/iron-plate/normal"] = 300, ["item/copper-plate/legendary"] = 1, ["item/pipe/epic"] = 7})
    expect_group("up", {["item/iron-plate/uncommon"] = 500, ["item/copper-plate/legendary"] = 1, ["item/pipe/epic"] = 7})
    assert(storage.requests.get_slot(1).min == 300, "chest follows the source change")
    -- Unlocking a quality lets quality-up reach it.
    force.technologies["legendary-quality"].researched = true
    expect_group("up", {["item/iron-plate/uncommon"] = 500, ["item/copper-plate/legendary"] = 1, ["item/pipe/legendary"] = 7})
    set_program("")
    assert(not group("up"), "an unreferenced removed definition has its group deleted")
    expect_group("missing", {["item/iron-plate/normal"] = 300, ["item/copper-plate/legendary"] = 1, ["item/pipe/epic"] = 7})
    local hidden = game.surfaces["logf-groups"]
    local others = hidden.count_entities_filtered{name = "logf-group-owner", invert = true}
    assert(others == 0, others .. " stray entities generated on the owner surface")
    finish("formulas")
  end
end

local find

-- Where a group's contents are shown: beside its definition, or below the definitions for
-- groups no formula computes. Slots in such a block as "sprite/quality" -> slot.
local function tree_of(player)
  return editor_in(player.gui.screen.logf_window).scroll.tree
end

local function preview_block(player, name)
  local tree = tree_of(player)
  return find(tree, {logf = "def-value", name = name}) or find(tree.others, {logf = "preview-group", name = name})
end

local function slots_in(container)
  local out = {}
  if container.slots then
    for _, slot in pairs(container.slots.children) do
      out[slot.sprite .. "/" .. (slot.quality and slot.quality.name or "normal")] = slot
    end
  end
  return out
end

-- Request settings of a group, as "type/name/quality" -> "count max from request delivery".
local function settings_of(name)
  local g = assert(game.forces.player.get_logistic_group(name), "no group " .. name)
  local out = {}
  for _, f in pairs(g.filters) do
    if f.value then
      local from = f.import_from
      if from and type(from) ~= "string" then from = from.name end
      out[f.value.type .. "/" .. f.value.name .. "/" .. f.value.quality] = string.format("%s %s %s %s %s",
        f.min, tostring(f.max), tostring(from), tostring(f.request_from or "planet"), tostring(f.minimum_delivery_count or 0))
    end
  end
  return out
end

local function expect_settings(name, expected)
  local got = settings_of(name)
  for k, v in pairs(expected) do
    assert(got[k] == v, string.format("%s: %s expected '%s', got '%s'", name, k, v, tostring(got[k])))
  end
  for k in pairs(got) do assert(expected[k], name .. ": unexpected " .. k) end
end

-- Limits, import locations, request sources and minimum deliveries: carried through, set, written.
CASES.settings = function(tick)
  if tick ~= 1 then return end
  storage.surface = lab()
  local force = game.forces.player
  force.unlock_quality("uncommon")
  local section = make("constant-combinator", {0.5, 0.5}).get_or_create_control_behavior().get_section(1)
  section.group = "orders"
  section.filters = {
    {value = {type = "item", name = "iron-plate", quality = "normal", comparator = "="}, min = 100, max = 300, import_from = "vulcanus"},
    {value = {type = "item", name = "pipe", quality = "normal", comparator = "="}, min = 10},
  }
  expect_settings("orders", {["item/iron-plate/normal"] = "100 300 vulcanus planet 0", ["item/pipe/normal"] = "10 nil nil planet 0"})

  local status = set_program[[
    (def "copied"   (quality-up (group "orders")))
    (def "tripled"  (multiply 3 (group "orders")))
    (def "summed"   (sum (group "orders") {iron-plate 1}))
    (def "minus"    (subtract (group "orders") {iron-plate 50}))
    (def "lowest"   (lowest (group "orders") (set-max {iron-plate 999} 150)))
    (def "capped"   (set-max (group "orders") 40))
    (def "per item" (set-max (group "orders") (multiply 5 (group "orders"))))
    (def "uncapped" (no-max (group "orders")))
    (def "limits"   (get-max (group "orders")))
    (def "imported" (request-from (import-from (group "orders") gleba) all))
    (def "anywhere" (import-from (group "orders") anywhere))
    (def "delivery" (min-delivery (group "orders") 25))
    (def "rounded"  (round-to-stacks (group "orders")))
    (def "bad"      (import-from (group "orders") atlantis))
  ]]
  for i = 1, 13 do assert(not status[i].error, "definition " .. i .. ": " .. tostring(status[i].error)) end
  assert(status[14].error:find("unknown location 'atlantis'"), status[14].error)

  expect_settings("copied", {["item/iron-plate/uncommon"] = "100 300 vulcanus planet 0", ["item/pipe/uncommon"] = "10 nil nil planet 0"})
  expect_settings("tripled", {["item/iron-plate/normal"] = "300 900 vulcanus planet 0", ["item/pipe/normal"] = "30 nil nil planet 0"})
  -- The constant has no limit, so neither has the sum.
  expect_settings("summed", {["item/iron-plate/normal"] = "101 nil vulcanus planet 0", ["item/pipe/normal"] = "10 nil nil planet 0"})
  expect_settings("minus", {["item/iron-plate/normal"] = "50 300 vulcanus planet 0", ["item/pipe/normal"] = "10 nil nil planet 0"})
  expect_settings("lowest", {["item/iron-plate/normal"] = "100 150 vulcanus planet 0"})
  -- A limit below the count is raised to the count.
  expect_settings("capped", {["item/iron-plate/normal"] = "100 100 vulcanus planet 0", ["item/pipe/normal"] = "10 40 nil planet 0"})
  expect_settings("per item", {["item/iron-plate/normal"] = "100 500 vulcanus planet 0", ["item/pipe/normal"] = "10 50 nil planet 0"})
  expect_settings("uncapped", {["item/iron-plate/normal"] = "100 nil vulcanus planet 0", ["item/pipe/normal"] = "10 nil nil planet 0"})
  expect_settings("limits", {["item/iron-plate/normal"] = "300 nil nil planet 0"})
  expect_settings("imported", {["item/iron-plate/normal"] = "100 300 gleba all 0", ["item/pipe/normal"] = "10 nil gleba all 0"})
  expect_settings("anywhere", {["item/iron-plate/normal"] = "100 300 nil planet 0", ["item/pipe/normal"] = "10 nil nil planet 0"})
  expect_settings("delivery", {["item/iron-plate/normal"] = "100 300 vulcanus planet 25", ["item/pipe/normal"] = "10 nil nil planet 25"})
  expect_settings("rounded", {["item/iron-plate/normal"] = "100 300 vulcanus planet 0", ["item/pipe/normal"] = "100 nil nil planet 0"})

  -- A change to settings alone is a change: the groups follow.
  section.set_slot(1, {value = {type = "item", name = "iron-plate", quality = "normal", comparator = "="}, min = 100, max = 200, import_from = "fulgora"})
  call("set_program", "player", call("program_text", "player"))
  expect_settings("copied", {["item/iron-plate/uncommon"] = "100 200 fulgora planet 0", ["item/pipe/uncommon"] = "10 nil nil planet 0"})

  -- The preview shows the limit as the slot's second number, and the settings in its tooltip.
  local player = game.get_player(1)
  call("formulas_open", player.index)
  local tree = editor_in(player.gui.screen.logf_window).scroll.tree
  local shown = slots_in(assert(preview_block(player, "copied"), "group listed"))["item/iron-plate/uncommon"]
  assert(shown and shown.number == 100 and shown.secondary_number == 200, "limit shown")
  assert(shown.tooltip:find("max 200") and shown.tooltip:find("space%-location=fulgora"), shown.tooltip)
  -- Location and source parameters use pickers.
  local picker = find(tree, {logf = "choice", def = 10, path = {3}})
  assert(picker and picker.items[picker.selected_index] == "all", "request source picker")
  picker = find(tree, {logf = "choice", def = 10, path = {2, 3}})
  assert(picker and picker.items[picker.selected_index]:find("gleba$"), "location picker")
  picker.selected_index = 1
  call("gui_event", "on_selection", {element = picker, player_index = player.index})
  expect_settings("imported", {["item/iron-plate/normal"] = "100 200 nil all 0", ["item/pipe/normal"] = "10 nil nil all 0"})
  finish("settings")
end

-- Recipe inputs and outputs, chosen by recipe.
CASES.recipes = function(tick)
  if tick ~= 1 then return end
  storage.surface = lab()
  local status = set_program[[
    (def "circuits x10" (ingredients electronic-circuit 10))
    (def "one gear"     (ingredients iron-gear-wheel))
    (def "oil"          (products advanced-oil-processing))
    (def "uranium"      (products uranium-processing 1000))
    (def "kovarex net"  (subtract (products kovarex-enrichment-process) (ingredients kovarex-enrichment-process)))
    (def "nope"         (products no-such-recipe))
    (def "item"         (products iron-plate-but-not-a-recipe 2))
  ]]
  for i = 1, 5 do assert(not status[i].error, "definition " .. i .. ": " .. tostring(status[i].error)) end
  assert(status[6].error:find("unknown recipe 'no%-such%-recipe'"), status[6].error)
  expect_group("circuits x10", {["item/iron-plate/normal"] = 10, ["item/copper-cable/normal"] = 30})
  expect_group("one gear", {["item/iron-plate/normal"] = 2})
  expect_group("oil", {["fluid/heavy-oil/normal"] = 25, ["fluid/light-oil/normal"] = 45, ["fluid/petroleum-gas/normal"] = 55})
  -- Products count at their average yield.
  expect_group("uranium", {["item/uranium-235/normal"] = 7, ["item/uranium-238/normal"] = 993})
  expect_group("kovarex net", {["item/uranium-235/normal"] = 1, ["item/uranium-238/normal"] = -3})

  -- In the editor, a recipe parameter is picked with the game's recipe chooser.
  local player = game.get_player(1)
  set_program('(def "picked" (group "one gear"))')
  call("formulas_open", player.index)
  local tree = editor_in(player.gui.screen.logf_window).scroll.tree
  local fn = find(tree, {logf = "function", def = 1, path = {}})
  for i, item in ipairs(fn.items) do if item:find(" ingredients$") then fn.selected_index = i end end
  call("gui_event", "on_selection", {element = fn, player_index = player.index})
  assert(call("program_text", "player") == '(def "picked" (ingredients iron-gear-wheel))', call("program_text", "player"))
  local picker = assert(find(tree, {logf = "recipe-pick", def = 1, path = {2}}), "recipe chooser shown")
  assert(picker.elem_value == "iron-gear-wheel", tostring(picker.elem_value))
  picker.elem_value = "copper-cable"
  call("gui_event", "on_elem_changed", {element = picker, player_index = player.index})
  expect_group("picked", {["item/copper-plate/normal"] = 1})
  picker = find(tree, {logf = "recipe-pick", def = 1, path = {2}})
  picker.elem_value = nil
  call("gui_event", "on_elem_changed", {element = picker, player_index = player.index})
  assert(call("program_text", "player") == '(def "picked" (ingredients copper-cable))', "clearing keeps the recipe")
  finish("recipes")
end

-- Reading a logistic network's contents, by name and by position, and following changes.
CASES.network = function(tick)
  local force = game.forces.player
  if tick == 1 then
    storage.surface = lab()
    make("substation", {0, -4})
    powered({2, -6})
    local roboport = make("roboport", {-4, 4})
    local network = assert(roboport.logistic_network, "a roboport makes a network")
    network.custom_name = "Test net"
    storage.store = make("storage-chest", {2.5, 2.5})
    storage.store.insert{name = "iron-plate", count = 100}
    storage.store.insert{name = "copper-plate", count = 7, quality = "rare"}
    storage.provider = make("passive-provider-chest", {3.5, 2.5})
    storage.provider.insert{name = "iron-gear-wheel", count = 5}
    -- A second, unnamed network far away.
    make("roboport", {60, 60}).logistic_network.custom_name = ""

    local status = set_program[[
      (def "all"      (network "Test net"))
      (def "stored"   (network "Test net" storage))
      (def "provided" (network "Test net" providers))
      (def "by place" (network "lab" 2.5 2.5))
      (def "doubled"  (multiply 2 (network "Test net" storage)))
      (def "nowhere"  (network "No such net"))
      (def "bad"      (network "Test net" chests))
      (def "half"     (network "lab" 2.5))
    ]]
    for i = 1, 5 do assert(not status[i].error, "definition " .. i .. ": " .. tostring(status[i].error)) end
    assert(status[6].error:find("no logistic network named"), status[6].error)
    assert(status[7].error:find("storage or providers"), status[7].error)
    assert(status[8].error:find("needs x and y"), status[8].error)
    local everything = {["item/iron-plate/normal"] = 100, ["item/copper-plate/rare"] = 7, ["item/iron-gear-wheel/normal"] = 5}
    expect_group("all", everything)
    expect_group("by place", everything)
    expect_group("stored", {["item/iron-plate/normal"] = 100, ["item/copper-plate/rare"] = 7})
    expect_group("provided", {["item/iron-gear-wheel/normal"] = 5})
    expect_group("doubled", {["item/iron-plate/normal"] = 200, ["item/copper-plate/rare"] = 14})

    local choices = call("network_choices", "player")
    assert(#choices == 2, "both networks are offered: " .. serpent.line(choices))
    local labels = choices[1].label .. " | " .. choices[2].label
    assert(labels:find("Test net", 1, true) and labels:find("lab #%d+ %(1 roboport%)"), labels)

    -- Contents change without any event; the program notices on its own.
    storage.store.remove_item{name = "iron-plate", count = 60}
  elseif tick == 40 then
    expect_group("stored", {["item/iron-plate/normal"] = 40, ["item/copper-plate/rare"] = 7})

    -- In the editor: a new node turned into a network reads the first network; the member picker narrows it.
    -- Hold "stored" on a real combinator so it survives losing its formula definition, while unused ones are deleted.
    local holder = make("constant-combinator", {6.5, 2.5})
    holder.get_or_create_control_behavior().get_section(1).group = "stored"
    local player = game.get_player(1)
    set_program('(def "picked" (group "all"))')
    assert(not group("provided") and not group("doubled"), "unused removed groups are deleted")
    call("formulas_open", player.index)
    local w = player.gui.screen.logf_window
    local tree = editor_in(w).scroll.tree
    local function fire(kind, element) call("gui_event", kind, {element = element, player_index = player.index}) end
    local fn = find(tree, {logf = "function", def = 1, path = {}})
    for i, item in ipairs(fn.items) do if item:find(" network$") then fn.selected_index = i end end
    fire("on_selection", fn)
    local pick = assert(find(tree, {logf = "network-pick", def = 1, path = {}}), "network picker shown")
    for i, item in ipairs(pick.items) do if item == "Test net" then pick.selected_index = i end end
    fire("on_selection", pick)
    local member = find(tree, {logf = "network-member", def = 1, path = {}})
    member.selected_index = 3
    fire("on_selection", member)
    assert(call("program_text", "player") == '(def "picked" (network "Test net" providers))', call("program_text", "player"))
    expect_group("picked", {["item/iron-gear-wheel/normal"] = 5})

    -- Contents show beside each definition; groups no formula computes are listed below.
    local others = tree_of(player).others
    assert(find(others, {logf = "preview-group", name = "stored"}) and not find(others, {logf = "preview-group", name = "picked"}),
      "only groups without a definition are listed below")
    assert(find(tree_of(player), {logf = "def-value", name = "picked"}), "a definition shows its contents")
    local stored = assert(preview_block(player, "stored"), "groups outside the program are listed")
    local counts = slots_in(stored)
    assert(counts["item/iron-plate/normal"].number == 40 and counts["item/copper-plate/rare"].number == 7, "stored contents")
    -- "stored" lost its definition when the program was replaced: it keeps its contents but no longer updates.
    assert(not stored.header.tooltip:find("formula"), stored.header.tooltip)
    storage.provider.insert{name = "iron-gear-wheel", count = 1}
  elseif tick == 100 then
    -- The open preview follows the change without any input.
    local gear = slots_in(preview_block(game.get_player(1), "picked"))["item/iron-gear-wheel/normal"]
    assert(gear and gear.number == 6, "preview refreshed")
    finish("network")
  end
end

-- The first element under root whose tags match, depth first.
function find(root, match)
  local t = root.tags
  local ok = t and t.logf
  if ok then
    ok = true
    for k, v in pairs(match) do
      local have = t[k]
      if type(v) == "table" then have = have and serpent.line(have) or nil; v = serpent.line(v) end
      if have ~= v then ok = false; break end
    end
    if ok then return root end
  end
  for _, c in pairs(root.children) do
    local found = find(c, match)
    if found then return found end
  end
end

-- The tree editor and text view, driven through their widgets.
CASES.editor = function(tick)
  if tick ~= 1 then return end
  storage.surface = lab()
  local force = game.forces.player
  for _, q in ipairs{"uncommon", "rare", "epic", "legendary"} do force.unlock_quality(q) end
  local section = make("constant-combinator", {0.5, 0.5}).get_or_create_control_behavior().get_section(1)
  section.group = "mall"
  section.filters = {item("iron-plate", "normal", 100), item("pipe", "rare", 10)}
  local player = game.get_player(1)

  call("formulas_open", player.index)
  local w = assert(player.gui.screen.logf_window, "window opens")
  local tree = editor_in(w).scroll.tree
  local function el(match) return assert(find(tree, match), "no element " .. serpent.line(match)) end
  local function fire(kind, element) call("gui_event", kind, {element = element, player_index = player.index}) end
  local function click(match) fire("on_click", el(match)) end
  local function choose(match, caption)
    local element = el(match)
    for i, item in ipairs(element.items) do
      -- Function options carry an icon before the name.
      if item == caption or item:sub(-#caption - 1) == " " .. caption then
        element.selected_index = i
        return fire("on_selection", element)
      end
    end
    error("no option " .. caption .. " in " .. serpent.line(element.items))
  end
  -- Selects a step by its count, unless selected already, and uses an action on it.
  local function action_button(action, def, path)
    return find(editor_in(w).step, {logf = action, def = def, path = path})
  end
  local function act(action, def, path)
    if not action_button(action, def, path) then click{logf = "result", def = def, path = path} end
    local button = assert(action_button(action, def, path), "no action " .. action)
    assert(button.enabled, action .. " is disabled")
    fire("on_click", button)
  end
  local function type_in(match, text, confirm)
    local element = el(match)
    element.text = text
    fire("on_text_changed", element)
    if confirm then fire("on_confirmed", element) end
  end

  click{logf = "def-new"}
  assert(call("program_status", "player")[1].error, "a new definition starts without a group")
  choose({logf = "group-name", def = 1, path = {}}, "mall")
  -- Names are text with an edit button, as in the game; editing shows a field with the icon picker.
  assert(not find(tree, {logf = "rename", def = 1}), "the name is plain text until edited")
  click{logf = "label-edit", def = 1}
  assert(el{logf = "rename", def = 1}.icon_selector, "the field has the game's icon picker")
  type_in({logf = "rename", def = 1}, "mall up", true)
  assert(not find(tree, {logf = "rename", def = 1}), "confirming ends editing")
  -- The edit button applies too.
  click{logf = "label-edit", def = 1}
  el{logf = "rename", def = 1}.text = "mall upper"
  click{logf = "label-edit", def = 1}
  assert(call("program_text", "player"):find('"mall upper"'), "the edit button applies the name")
  click{logf = "label-edit", def = 1}
  type_in({logf = "rename", def = 1}, "mall up", true)
  expect_group("mall up", {["item/iron-plate/normal"] = 100, ["item/pipe/rare"] = 10})

  -- Choosing a function for a leaf makes the leaf its first argument.
  choose({logf = "function", def = 1, path = {}}, "quality-up")
  expect_group("mall up", {["item/iron-plate/uncommon"] = 100, ["item/pipe/epic"] = 10})
  -- An optional number sits on its function's row, at its default until typed in.
  assert(not find(tree, {logf = "add-arg", def = 1, path = {}}), "no button for an argument on the row")
  local field = el{logf = "number", def = 1, path = {3}}
  assert(field.text == "1" and field.parent == el{logf = "function", def = 1, path = {}}.parent,
    "the number is on the function's row")
  type_in({logf = "number", def = 1, path = {3}}, "2")
  expect_group("mall up", {["item/iron-plate/rare"] = 100, ["item/pipe/legendary"] = 10})
  -- Typing updates results without rebuilding, so the field keeps focus.
  assert(el{logf = "result", def = 1, path = {2}}.caption == "2", "result caption")
  assert(el{logf = "result", def = 1, path = {}, root = true}.caption == "2 signals", "the root's count is in the header")
  -- Selecting a step shows the actions on it: fixed arguments neither move nor go away.
  click{logf = "result", def = 1, path = {2}}
  assert(not action_button("up", 1, {2}).enabled and not action_button("remove", 1, {2}).enabled,
    "the group argument of quality-up is fixed")
  type_in({logf = "number", def = 1, path = {3}}, "1", true)
  assert(not field.valid, "confirming rebuilds the tree")
  assert(action_button("remove", 1, {2}), "typing keeps the selection")

  -- Wrap, then change the wrapper's function: the wrapped node stays as its first argument.
  act("wrap", 1, {})
  assert(action_button("unwrap", 1, {}).enabled, "the selection moves to the new function")
  choose({logf = "function", def = 1, path = {}}, "multiply")
  click{logf = "add-arg", def = 1, path = {}}
  type_in({logf = "number", def = 1, path = {3}}, "3", true)
  -- Optional arguments can be removed; a number's count is a plain handle.
  click{logf = "result", def = 1, path = {3}}
  assert(action_button("remove", 1, {3}).enabled and action_button("up", 1, {3}).enabled, "steps can be removed")
  assert(not action_button("unwrap", 1, {3}).enabled, "a number cannot be unwrapped")
  assert(el{logf = "result", def = 1, path = {3}}.caption == "#", "a number's count is a plain handle")
  expect_group("mall up", {["item/iron-plate/uncommon"] = 300, ["item/pipe/epic"] = 30})
  assert(call("program_text", "player") == '(def "mall up" (multiply (quality-up (group "mall") 1) 3))', call("program_text", "player"))

  -- Reorder arguments; the selection follows.
  act("up", 1, {3})
  assert(call("program_text", "player") == '(def "mall up" (multiply 3 (quality-up (group "mall") 1)))', call("program_text", "player"))
  assert(el{logf = "result", def = 1, path = {2}}.toggled, "the moved step stays selected")
  act("down", 1, {2})
  act("up", 1, {3})
  -- Copy and paste replace a step; unwrap puts the first argument in its function's place.
  act("copy", 1, {3})
  act("paste", 1, {2})
  assert(call("program_text", "player"):gsub("%s+", " ") == '(def "mall up" (multiply (quality-up (group "mall") 1) (quality-up (group "mall") 1)))',
    call("program_text", "player"))
  act("unwrap", 1, {3})
  assert(call("program_text", "player"):gsub("%s+", " ") == '(def "mall up" (multiply (quality-up (group "mall") 1) (group "mall")))',
    call("program_text", "player"))
  -- Cut takes a step out to paste elsewhere; a right-click on a count removes its step.
  act("cut", 1, {3})
  assert(call("program_text", "player") == '(def "mall up" (multiply (quality-up (group "mall") 1)))', call("program_text", "player"))
  assert(not editor_in(w).step.visible, "removing a step clears the selection")
  click{logf = "add-arg", def = 1, path = {}}
  type_in({logf = "number", def = 1, path = {3}}, "3", true)
  local three = el{logf = "result", def = 1, path = {3}}
  assert(three.mouse_button_filter.right, "counts report right clicks")
  call("gui_event", "on_click", {element = three, player_index = player.index, button = defines.mouse_button_type.right})
  call("gui_event", "on_click", {element = el{logf = "result", def = 1, path = {2}}, player_index = player.index,
    button = defines.mouse_button_type.right})
  assert(call("program_text", "player") == '(def "mall up" (multiply (quality-up (group "mall") 1)))',
    "a right-click removes only what can go: " .. call("program_text", "player"))
  act("unwrap", 1, {})
  fire("on_click", find(editor_in(w).step, {logf = "step-close"}))
  expect_group("mall up", {["item/iron-plate/uncommon"] = 100, ["item/pipe/epic"] = 10})

  -- Each definition shows its group's contents in its own frame, beside the formula, live.
  local editor = editor_in(w)
  local function previewed(name)
    local out = {}
    for k, slot in pairs(slots_in(preview_block(player, name))) do out[k] = slot.number end
    return out
  end
  local value = assert(find(tree, {logf = "def-value", name = "mall up"}), "contents beside the definition")
  local name_edit = el{logf = "label-edit", def = 1}
  assert(value.parent.parent == name_edit.parent.parent.parent, "contents sit in the definition's own frame")
  assert(find(tree.others, {logf = "preview-group", name = "mall"}), "groups outside the program are listed below")
  assert(previewed("mall up")["item/iron-plate/uncommon"] == 100, serpent.line(previewed("mall up")))
  type_in({logf = "number", def = 1, path = {3}}, "2")
  assert(previewed("mall up")["item/iron-plate/rare"] == 100, "contents follow typing: " .. serpent.line(previewed("mall up")))
  type_in({logf = "number", def = 1, path = {3}}, "1", true)
  -- Clicking a step's count selects it and shows that step above the tree, until cleared.
  assert(not editor.step.visible, "no step until one is picked")
  click{logf = "result", def = 1, path = {2}}
  assert(editor.step.visible and editor.step.head.title.caption:find("group$"), editor.step.head.title.caption)
  assert(slots_in(editor.step.slots)["item/iron-plate/normal"].number == 100, "the step before quality-up")
  assert(el{logf = "result", def = 1, path = {2}}.toggled, "the step is marked in the tree")
  fire("on_click", find(editor.step, {logf = "step-close"}))
  assert(not editor.step.visible, "the step closes")
  click{logf = "result", def = 1, path = {2}}
  click{logf = "result", def = 1, path = {2}}
  assert(not editor.step.visible, "clicking the selected count clears the selection")
  -- The selection is the opened GUI: Escape clears it and leaves the window.
  click{logf = "result", def = 1, path = {2}}
  assert(player.opened == editor.step, "the selection is the opened GUI")
  player.opened = nil
  assert(not editor.step.visible and player.opened == w, "Escape clears the selection only")
  -- The checkbox hides all contents.
  local toggle = editor.bar.show_preview
  toggle.state = false
  call("gui_event", "on_checked", {element = toggle, player_index = player.index})
  assert(not el{logf = "def-value", name = "mall up"}.visible and not tree.others.visible, "contents hidden")
  toggle.state = true
  call("gui_event", "on_checked", {element = toggle, player_index = player.index})
  assert(el{logf = "def-value", name = "mall up"}.visible and tree.others.visible, "contents shown again")

  -- A literal list: slots with counts on them; clicking one edits it below the slots.
  click{logf = "def-new"}
  choose({logf = "function", def = 2, path = {}}, "constant")
  local add = el{logf = "item-add", def = 2}
  add.elem_value = {type = "item", name = "iron-gear-wheel", quality = "rare"}
  fire("on_elem_changed", add)
  assert(el{logf = "item-count", def = 2, pair = 2}, "a new signal opens for its count")
  add = el{logf = "item-add", def = 2}
  add.elem_value = {type = "fluid", name = "water"}
  fire("on_elem_changed", add)
  assert(not find(tree, {logf = "item-count", def = 2, pair = 2}), "one signal is edited at a time")
  click{logf = "item-slot", def = 2, pair = 2}
  assert(el{logf = "item-slot", def = 2, pair = 2}.toggled, "the edited slot is marked")
  type_in({logf = "item-count", def = 2, pair = 2}, "40", true)
  expect_group("new group", {["item/iron-gear-wheel/rare"] = 40, ["fluid/water/normal"] = 1})
  assert(not find(tree, {logf = "item-count", def = 2}), "Enter closes the editor")
  local gear = el{logf = "item-slot", def = 2, pair = 2}
  assert(gear.number == 40 and gear.sprite == "item/iron-gear-wheel" and gear.quality.name == "rare", "the slot shows the count")
  -- Clearing the signal in the editor removes it; so does a right-click on its slot.
  click{logf = "item-slot", def = 2, pair = 4}
  local slot = el{logf = "item-signal", def = 2, pair = 4}
  slot.elem_value = nil
  fire("on_elem_changed", slot)
  expect_group("new group", {["item/iron-gear-wheel/rare"] = 40})
  add = el{logf = "item-add", def = 2}
  add.elem_value = {type = "item", name = "coal"}
  fire("on_elem_changed", add)
  assert(find(tree, {logf = "def-value", name = "new group"}), "every definition keeps its contents column")
  local coal = el{logf = "item-slot", def = 2, pair = 4}
  assert(coal.mouse_button_filter.right, "the slot reports right clicks")
  call("gui_event", "on_click", {element = coal, player_index = player.index, button = defines.mouse_button_type.right})
  expect_group("new group", {["item/iron-gear-wheel/rare"] = 40})
  -- An open signal editor is the opened GUI, so Escape closes it and leaves the window.
  click{logf = "item-slot", def = 2, pair = 2}
  assert(player.opened == el{logf = "item-editor"}, "the signal editor is the opened GUI")
  click{logf = "def-new"}
  assert(player.opened == el{logf = "item-editor"}, "it stays open through redraws")
  click{logf = "def-delete", def = 3}
  assert(#call("program_status", "player") == 3 and el{logf = "def-delete", def = 3}.sprite == "utility/trash_white",
    "first click arms definition delete")
  fire("on_click", editor.bar)
  assert(el{logf = "def-delete", def = 3}.sprite == "utility/trash", "clicking elsewhere disarms definition delete")
  click{logf = "def-delete", def = 3}
  assert(#call("program_status", "player") == 3, "re-arming still requires two clicks")
  click{logf = "def-delete", def = 3}
  assert(#call("program_status", "player") == 2, "second click deletes the definition")
  player.opened = nil
  assert(not find(tree, {logf = "item-editor"}) and player.opened == w, "Escape closes the signal editor only")
  -- Edits that move nodes close it, since its position may now hold another node.
  local before = call("program_text", "player")
  click{logf = "item-slot", def = 2, pair = 2}
  act("wrap", 1, {})
  assert(not find(tree, {logf = "item-editor"}) and player.opened == editor.step, "reshaping closes the signal editor")
  fire("on_click", find(editor.step, {logf = "step-close"}))
  assert(call("set_program", "player", before))

  -- Definitions reorder and delete; a quality argument uses its own picker.
  click{logf = "def-up", def = 2}
  assert(call("program_text", "player"):find('^%(def "new group"'), "moved up")
  click{logf = "def-new"}
  choose({logf = "group-name", def = 3, path = {}}, "mall")
  choose({logf = "function", def = 3, path = {}}, "set-quality")
  local quality = el{logf = "choice", def = 3, path = {3}}
  quality.selected_index = 3
  fire("on_selection", quality)
  expect_group("new group 2", {["item/iron-plate/rare"] = 100, ["item/pipe/rare"] = 10})
  click{logf = "def-delete", def = 3}
  click{logf = "def-delete", def = 3}
  assert(not group("new group 2"), "deleted unreferenced definition group is cleaned up")

  -- Counts take k, M and G; text that is not a number marks the field and changes nothing.
  click{logf = "item-slot", def = 1, pair = 2}
  type_in({logf = "item-count", def = 1, pair = 2}, "5k", true)
  expect_group("new group", {["item/iron-gear-wheel/rare"] = 5000})
  click{logf = "item-slot", def = 1, pair = 2}
  assert(el{logf = "item-count", def = 1, pair = 2}.text == "5k", "round counts show with units")
  type_in({logf = "item-count", def = 1, pair = 2}, "1.5M")
  expect_group("new group", {["item/iron-gear-wheel/rare"] = 1500000})
  type_in({logf = "item-count", def = 1, pair = 2}, "lots")
  expect_group("new group", {["item/iron-gear-wheel/rare"] = 1500000})
  assert(el{logf = "item-count", def = 1, pair = 2}.style.name == "invalid_value_textfield", "invalid text is marked")
  type_in({logf = "item-count", def = 1, pair = 2}, "40", true)
  local parsed = sexp.parse('(def "x" {coal 2k}) (def "y" (multiply 1.5M (group "x")))')
  assert(parsed[1][3][3] == 2000 and parsed[2][3][2] == 1500000, "the text form reads units")

  -- Search hides the groups whose name does not match, definitions and others alike. The
  -- game's search key reaches it; focus itself cannot be read back.
  call("focus_search", player.index)
  local bar = editor_in(w).bar
  bar.search.text = "MALL"
  fire("on_text_changed", bar.search)
  local function frame_of(name) return find(tree, {logf = "def-frame", name = name}) end
  assert(frame_of("mall up").visible and not frame_of("new group").visible, "definitions filtered")
  assert(find(tree.others, {logf = "preview-group", name = "mall"}).visible, "other groups filtered too")
  bar.search.text = ""
  fire("on_text_changed", bar.search)
  assert(frame_of("new group").visible, "clearing the search shows everything")

  -- Collapse all leaves each definition a header line, its contents in one row; expand all brings them back.
  fire("on_click", find(bar, {logf = "collapse-all"}))
  assert(not find(frame_of("mall up"), {logf = "number"}), "collapsed definitions hide their formula")
  local inline = el{logf = "def-value", name = "mall up"}
  assert(inline.tags.inline and inline.slots and #inline.slots.children == 2, "contents on the collapsed line")
  -- Slots follow the game's item order (logistics before intermediates), not the formula's.
  assert(inline.slots.children[1].sprite == "item/pipe", inline.slots.children[1].sprite)
  local count = find(frame_of("mall up"), {logf = "result", root = true})
  assert(count.tooltip:find("iron%-plate"), "the count lists the contents: " .. serpent.line(count.tooltip))
  fire("on_click", find(bar, {logf = "expand-all"}))
  assert(not el{logf = "def-value", name = "mall up"}.tags.inline, "expanded again")

  -- The text window opens beside the window, showing the sheet highlighted; Edit turns it into
  -- a text box that applies edits and reports errors without applying.
  fire("on_click", find(editor_in(w).bar, {logf = "text-open"}))
  local text = assert(player.gui.screen.logf_text, "text window opens").text_view
  assert(text.view.code.caption:find("[color=", 1, true) and not text.box, "the sheet shows highlighted")
  fire("on_click", text.bar.edit)
  assert(text.box.text == call("program_text", "player"), "the text box holds the program")
  text.box.text = '(def "mall up" (set-stacks (group "mall")))'
  fire("on_click", find(text, {logf = "apply"}))
  expect_group("mall up", {["item/iron-plate/normal"] = 100, ["item/pipe/rare"] = 100})
  assert(not text.box and text.view.code.caption:find("mall up", 1, true), "applying shows the new text highlighted")
  assert(text.bar.message.caption == "Applied.", "applying says so")
  fire("on_click", text.view.code)
  assert(#call("program_status", "player") == 1, "apply replaces the program")
  tree = editor_in(w).scroll.tree
  local fn_node = find(tree, {logf = "function", def = 1, path = {}})
  assert(fn_node.items[fn_node.selected_index] == "[img=logf-fn-set-stacks] set-stacks", "tree follows the text")
  text.box.text = '(def "mall up" (set-stacks (group "mall"))'
  fire("on_click", find(text, {logf = "apply"}))
  assert(text.bar.message.caption:find("missing"), "syntax error shown: " .. text.bar.message.caption)
  expect_group("mall up", {["item/iron-plate/normal"] = 100, ["item/pipe/rare"] = 100})
  -- Applying empty text over non-empty definitions asks for a second click; clicking elsewhere disarms it.
  text.box.text = ""
  fire("on_click", find(text, {logf = "apply"}))
  assert(#call("program_status", "player") == 1, "first empty apply does not wipe definitions")
  assert(text.bar.message.caption:find("Click Apply again"), text.bar.message.caption)
  fire("on_click", text.box)
  assert(text.bar.message.caption == "", "clicking elsewhere clears the wipe confirmation")
  fire("on_click", find(text, {logf = "apply"}))
  assert(#call("program_status", "player") == 1, "re-arming after clicking elsewhere still asks again")
  fire("on_click", find(text, {logf = "revert"}))
  assert(not text.box and text.view.code.caption:find("mall up", 1, true), "revert shows the sheet again")
  fire("on_click", text.bar.edit)
  assert(text.box.text == '(def "mall up" (set-stacks (group "mall")))', "revert keeps the definitions")
  text.box.text = ""
  fire("on_click", find(text, {logf = "apply"}))
  assert(#call("program_status", "player") == 1, "revert clears pending wipe confirmation")
  fire("on_click", find(text, {logf = "apply"}))
  assert(#call("program_status", "player") == 0 and not group("mall up"), "second empty apply wipes and cleans up")
  fire("on_click", text.bar.edit)
  text.box.text = '(def "mall up" (set-stacks (group "mall")))'
  fire("on_click", find(text, {logf = "apply"}))
  expect_group("mall up", {["item/iron-plate/normal"] = 100, ["item/pipe/rare"] = 100})
  fire("on_click", find(player.gui.screen.logf_text, {logf = "text-close"}))
  assert(not player.gui.screen.logf_text, "the text window closes")
  assert(player.opened == w, "the main window is the opened GUI again")
  -- Escape in the text window closes only it.
  fire("on_click", find(editor_in(w).bar, {logf = "text-open"}))
  assert(player.opened == player.gui.screen.logf_text and w.valid, "the text window is the opened GUI")
  player.opened = nil
  assert(not player.gui.screen.logf_text and w.valid and player.opened == w, "Escape closes the text window only")

  -- Wrap and unwrap on tree rows, and the formula text below the tree.
  tree = editor_in(w).scroll.tree
  click{logf = "wrap", def = 1, path = {}}
  choose({logf = "function", def = 1, path = {}}, "multiply")
  click{logf = "add-arg", def = 1, path = {}}
  type_in({logf = "number", def = 1, path = {3}}, "2", true)
  assert(call("program_text", "player") == '(def "mall up" (multiply (set-stacks (group "mall")) 2))',
    call("program_text", "player"))
  expect_group("mall up", {["item/iron-plate/normal"] = 200, ["item/pipe/rare"] = 200})
  -- Inline unwrap on the inner `set-stacks` node replaces it with its first argument `(group "mall")`.
  click{logf = "unwrap", def = 1, path = {2}}
  assert(call("program_text", "player") == '(def "mall up" (multiply (group "mall") 2))',
    call("program_text", "player"))
  expect_group("mall up", {["item/iron-plate/normal"] = 200, ["item/pipe/rare"] = 20})

  -- The formula text opens a text box on click, applies a valid formula, and reports an
  -- error without closing.
  local sexp_label = el{logf = "sexp-open", def = 1}
  assert(sexp_label.caption:find("%[color=") and sexp_label.caption:find("multiply"), "syntax-highlighted sexp shown")
  click{logf = "sexp-open", def = 1}
  local box = el{logf = "def-sexp", def = 1}
  assert(box.type == "text-box", "multi-line text-box opened")
  box.text = "(round-to-stacks\n  (multiply 3\n    (drop\n      (quality-up (group \"mall\") 2)\n      pipe)))"
  click{logf = "sexp-apply", def = 1}
  expect_group("mall up", {["item/iron-plate/rare"] = 300})
  assert(not find(tree, {logf = "def-sexp", def = 1}), "applying closes the text-box and shows highlighted view")
  assert(el{logf = "group-name", def = 1, path = {2, 3, 2, 2}}, "nested group node in tree")
  assert(el{logf = "function", def = 1, path = {2, 3, 2}}, "nested quality-up node in tree")
  assert(el{logf = "function", def = 1, path = {2, 3}}, "nested drop node in tree")
  -- A filter's signals are pickers on its row: changing one rewrites it, the empty one adds one,
  -- and clearing one removes it while another is left.
  local pick = el{logf = "filter-pick", def = 1, path = {2, 3, 3}}
  assert(pick.elem_value.name == "pipe", "the filter's signal is shown")
  pick.elem_value = {type = "item", name = "iron-plate", quality = "rare"}
  fire("on_elem_changed", pick)
  local add = el{logf = "filter-add", def = 1, path = {2, 3}}
  add.elem_value = {type = "item", name = "pipe"}
  fire("on_elem_changed", add)
  assert(call("program_text", "player"):find("(drop (quality-up (group \"mall\") 2) iron-plate:rare pipe)", 1, true),
    call("program_text", "player"))
  expect_group("mall up", {})
  pick = el{logf = "filter-pick", def = 1, path = {2, 3, 3}}
  pick.elem_value = nil
  fire("on_elem_changed", pick)
  assert(call("program_text", "player"):find("(drop (quality-up (group \"mall\") 2) pipe)", 1, true),
    call("program_text", "player"))
  expect_group("mall up", {["item/iron-plate/rare"] = 300})
  assert(el{logf = "function", def = 1, path = {2}}, "nested multiply node in tree")
  assert(el{logf = "function", def = 1, path = {}}, "root round-to-stacks node in tree")
  click{logf = "sexp-open", def = 1}
  el{logf = "def-sexp", def = 1}.text = "(broken"
  click{logf = "sexp-apply", def = 1}
  assert(find(tree, {logf = "def-sexp", def = 1}), "invalid sexp keeps the editor open")
  click{logf = "sexp-cancel", def = 1}
  assert(not find(tree, {logf = "def-sexp", def = 1}), "cancel closes the editor")

  -- Duplicating a definition clones its formula right below it.
  click{logf = "def-duplicate", def = 1}
  expect_group("mall up copy", {["item/iron-plate/rare"] = 300})

  -- Every function has a Factoriopedia page, which the docs case checks; the '?' in the sheet
  -- bar opens the guide.
  assert(prototypes.font["logf-mono"], "missing logf-mono font prototype")
  for _, fn_name in ipairs(lang.order) do
    local p = assert(prototypes.virtual_signal["logf-fn-" .. fn_name], "missing fn prototype " .. fn_name)
    assert(p.group.name == "logistic-formulas" and p.factoriopedia_description, fn_name .. " in factoriopedia")
  end
  fire("on_click", find(editor_in(w).bar, {logf = "factoriopedia"}))

  player.opened = nil
  assert(not player.gui.screen.logf_window, "closing removes the window")
  finish("editor")
end

-- Opening the formula window from the corner button, pinning it, and where it reopens.
CASES.window = function(tick)
  if tick ~= 1 then return end
  storage.surface = lab()
  local player = game.get_player(1)
  local function fire(element) call("gui_event", "on_click", {element = element, player_index = player.index}) end
  local button = assert(mod_gui.get_button_flow(player).logf_toggle, "corner button exists")

  fire(button)
  local w = assert(player.gui.screen.logf_window, "corner button opens the window")
  assert(player.opened == w, "an unpinned window is the opened GUI")
  assert(player.is_shortcut_toggled("logf-formulas"), "shortcut shows the window is open")
  -- The window opens maximized and restores to the large size.
  assert(w.children[1].maximize.toggled, "the window opens maximized")
  fire(w.children[1].maximize)
  w = player.gui.screen.logf_window
  assert(editor_in(w).style.maximal_width == 1375, "a maximized window restores to the large size")
  fire(button)
  assert(not player.gui.screen.logf_window, "corner button closes the window")
  assert(not player.is_shortcut_toggled("logf-formulas"), "shortcut shows the window is closed")

  fire(button)
  w = player.gui.screen.logf_window
  w.location = {x = 123, y = 45}
  player.opened = nil
  assert(not player.gui.screen.logf_window, "Escape closes an unpinned window")
  fire(button)
  w = player.gui.screen.logf_window
  assert(w.location.x == 123 and w.location.y == 45, "window reopens where it was")

  -- Size buttons grow and shrink the content, within the screen.
  local scroll = editor_in(w)
  local width = scroll.style.maximal_width
  fire(find(w.children[1], {logf = "larger"}))
  assert(scroll.style.maximal_width > width, "larger grows the window")
  for _ = 1, 20 do fire(find(w.children[1], {logf = "larger"})) end
  local screen = player.display_resolution.width / player.display_scale
  assert(scroll.style.maximal_width < screen, "the window stays inside the screen")
  call("set_program", "player", '(def "w" (sum {iron-plate 1}))')
  call("formulas_open", player.index)
  w = player.gui.screen.logf_window
  scroll = editor_in(w)
  local value = find(editor_in(w).scroll.tree, {logf = "def-value", name = "w"})
  assert(value.parent.direction == "horizontal", "contents beside the formula in a wide window")
  for _ = 1, 30 do fire(find(w.children[1], {logf = "smaller"})) end
  assert(scroll.style.maximal_width == 560, "the window has a minimum size")
  value = find(editor_in(w).scroll.tree, {logf = "def-value", name = "w"})
  assert(value.parent.direction == "vertical", "contents under the formula in a narrow window")
  fire(find(w.children[1], {logf = "larger"}))
  width = scroll.style.maximal_width
  call("formulas_open", player.index)
  w = player.gui.screen.logf_window
  assert(editor_in(w).style.maximal_width == width, "the size is remembered")

  -- Maximizing fills the screen and keeps the window in place; restoring brings back the
  -- size and place it had.
  w.location = {x = 200, y = 100}
  fire(w.children[1].maximize)
  w = player.gui.screen.logf_window
  local screen_h = player.display_resolution.height / player.display_scale
  assert(editor_in(w).style.maximal_width > width and editor_in(w).style.maximal_height > screen_h - 120, "maximized fills the screen")
  assert(w.location.x == 0 and w.location.y == 0 and not w.children[1].drag_target, "a maximized window stays in place")
  assert(w.children[1].maximize.toggled and not find(w.children[1], {logf = "larger"}).enabled, "size buttons are off")
  call("formulas_open", player.index)
  w = player.gui.screen.logf_window
  assert(w.children[1].maximize.toggled, "maximized is remembered")
  fire(w.children[1].maximize)
  w = player.gui.screen.logf_window
  assert(editor_in(w).style.maximal_width == width and w.location.x == 200 and w.location.y == 100, "restored")
  assert(w.children[1].drag_target == w, "the window drags again")

  local pin = w.children[1].pin
  fire(pin)
  assert(pin.toggled and player.opened ~= w, "pinning releases the opened GUI")
  assert(player.gui.screen.logf_window, "pinning keeps the window")
  player.teleport({0.5, 2.5}, storage.surface)
  local chest = make("iron-chest", {0.5, 0.5})
  player.opened = chest
  assert(player.opened == chest and player.gui.screen.logf_window, "other windows open beside a pinned one")
  player.opened = nil
  assert(player.gui.screen.logf_window, "closing other windows leaves a pinned one")
  call("gui_event", "on_closed", {element = w, player_index = player.index})
  assert(player.gui.screen.logf_window, "a close event does not remove a pinned window")
  call("formulas_open", player.index)
  w = player.gui.screen.logf_window
  assert(w.children[1].pin.toggled and player.opened ~= w, "the pin is remembered")

  fire(w.children[1].pin)
  assert(player.opened == w, "unpinning makes the window the opened GUI again")

  -- A new size setting replaces the size the player left.
  call("set_window_size", player.index, "small")
  w = player.gui.screen.logf_window
  assert(editor_in(w).style.maximal_width == 1040 and not w.children[1].maximize.toggled, "the window takes the size setting")
  player.opened = w
  player.opened = nil
  assert(not player.gui.screen.logf_window, "Escape closes it again")
  -- Another window closes an unpinned one also while its selection is the opened GUI.
  call("formulas_open", player.index)
  w = player.gui.screen.logf_window
  fire(find(editor_in(w).scroll.tree, {logf = "result", root = true}))
  assert(player.opened == editor_in(w).step, "the selection is the opened GUI")
  player.opened = chest
  assert(player.opened == chest and not player.gui.screen.logf_window, "another window closes the editor")
  finish("window")
end

-- State written before a save must keep working after loading it (run by tools/test.sh in two processes).
CASES.save = function(tick)
  if tick == 1 then
    storage.surface = lab()
    game.forces.player.unlock_quality("uncommon")
    local mall = make("constant-combinator", {0.5, 0.5}).get_or_create_control_behavior().get_section(1)
    mall.group = "mall"
    mall.filters = {item("iron-plate", "normal", 100)}
    storage.mall = mall
    local ok, err = call("set_program", "player", '(def "up" (quality-up (group "mall")))')
    assert(ok, err)
    -- A second sheet, reading the same outside group.
    assert(call("set_prefix", "A/"))
    storage.sheet = call("add_sheet", "player")
    ok, err = call("set_sheet_program", "player", storage.sheet, '(def "double" (multiply 2 (group "mall")))')
    assert(ok, err)
    expect_group("[virtual-signal=signal-F] double", {["item/iron-plate/normal"] = 200})
  elseif tick == 20 then
    storage.resume_tick = tick
    game.auto_save("logf-reload")
  elseif tick == 25 then
    finish("save created")
  end
end

CASES.reload = function(tick)
  assert(storage.resume_tick, "reload requires the save test's file")
  local elapsed = tick - storage.resume_tick
  if elapsed == 2 then
    expect_group("A/up", {["item/iron-plate/uncommon"] = 100})
    storage.mall.filters = {item("iron-plate", "normal", 7)}
  elseif elapsed == 40 then
    expect_group("A/up", {["item/iron-plate/uncommon"] = 7})
    expect_group("[virtual-signal=signal-F] double", {["item/iron-plate/normal"] = 14})
    finish("save/load of sheets and formulas")
  end
end

-- Formula groups are owned by their formulas; their names carry the configured prefix.
CASES.guard = function(tick)
  local force = game.forces.player
  if tick == 1 then
    storage.surface = lab()
    call("set_prefix", "[F] ")
    local source = make("constant-combinator", {0.5, 0.5}).get_or_create_control_behavior().get_section(1)
    source.group = "plates"
    source.filters = {item("iron-plate", "normal", 10)}
    local status = set_program[[
      (def "doubled" (multiply 2 (group "plates")))
      (def "quadrupled" (multiply 2 (group "doubled")))
    ]]
    assert(not status[1].error and not status[2].error, serpent.line(status))
    assert(not group("doubled"), "no group without the prefix")
    expect_group("[F] doubled", {["item/iron-plate/normal"] = 20})
    -- Definitions refer to each other by their plain names.
    expect_group("[F] quadrupled", {["item/iron-plate/normal"] = 40})

    -- An edit through a member section is undone at once, with a warning.
    storage.chest = make("requester-chest", {4.5, 0.5})
    storage.member = storage.chest.get_requester_point().add_section("[F] doubled")
    storage.member.set_slot(1, item("copper-plate", "normal", 99))
    expect_group("[F] doubled", {["item/iron-plate/normal"] = 20})
    local warning = call("last_warning")
    assert(warning and warning:find('"%[F%] doubled" is computed by a formula'), tostring(warning))

    -- A change that raises no event is caught by the poll.
    storage.member.filters = {item("coal", "normal", 5)}
    expect_group("[F] doubled", {["item/coal/normal"] = 5})
  elseif tick == 40 then
    expect_group("[F] doubled", {["item/iron-plate/normal"] = 20})
    -- A new prefix, set in the editor, renames every formula group; unused old ones are deleted while those in use keep their contents.
    local player = game.get_player(1)
    call("formulas_open", player.index)
    local bar = editor_in(player.gui.screen.logf_window).bar
    assert(bar.prefix_row.label.caption == "[F] " and bar.prefix_example.caption == "→ [F] mall", bar.prefix_example.caption)
    call("gui_event", "on_click", {element = bar.prefix_row.edit, player_index = player.index})
    bar = editor_in(player.gui.screen.logf_window).bar
    bar.prefix_row.field.text = "fx/"
    call("gui_event", "on_confirmed", {element = bar.prefix_row.field, player_index = player.index})
    bar = editor_in(player.gui.screen.logf_window).bar
    assert(bar.prefix_example.caption == "→ fx/mall", bar.prefix_example.caption)
    expect_group("fx/doubled", {["item/iron-plate/normal"] = 20})
    expect_group("fx/quadrupled", {["item/iron-plate/normal"] = 40})
    expect_group("[F] doubled", {["item/iron-plate/normal"] = 20})
    assert(not group("[F] quadrupled"), "unused old-prefix group is deleted")
    finish("guard")
  end
end

-- Sheets: separate sets of groups, each with its own prefix, unable to read each other.
CASES.sheets = function(tick)
  if tick ~= 1 then return end
  storage.surface = lab()
  local player = game.get_player(1)
  local source = make("constant-combinator", {0.5, 0.5}).get_or_create_control_behavior().get_section(1)
  source.group = "plates"
  source.filters = {item("iron-plate", "normal", 10)}
  set_program('(def "x" {coal 1})')

  -- With an empty prefix, the first sheet leaves no room for a second.
  local id, problem = call("add_sheet", "player")
  assert(not id and problem:find("without a prefix"), tostring(problem))
  assert(call("set_prefix", "A/"))
  expect_group("A/x", {["item/coal/normal"] = 1})
  set_program('(def "x" {coal 1}) (def "y" {coal 2})')

  -- The last tab adds a sheet, with the first free letter icon as its prefix.
  call("formulas_open", player.index)
  local pane = player.gui.screen.logf_window.children[2].pane
  assert(#pane.tabs == 2 and pane.tabs[1].tab.caption == "A/" and pane.tabs[2].tab.caption == "+", "one sheet tab and +")
  pane.selected_tab_index = 2
  call("gui_event", "on_tab_changed", {element = pane, player_index = player.index})
  local ids = call("sheet_ids", "player")
  assert(#ids == 2 and call("sheet_prefix", "player", ids[2]) == "[virtual-signal=signal-F] ", serpent.line(ids))
  pane = player.gui.screen.logf_window.children[2].pane
  assert(#pane.tabs == 3 and pane.selected_tab_index == 2, "the new sheet's tab is selected")

  -- A sheet reads its own definitions and groups no formula computes, never another sheet's.
  local ok, err = call("set_sheet_program", "player", ids[2], [[
    (def "own"     (multiply 2 (group "plates")))
    (def "chained" (multiply 2 (group "own")))
    (def "other"   (group "A/x"))
    (def "plain"   (group "y"))
  ]])
  assert(ok, err)
  local F = "[virtual-signal=signal-F] "
  expect_group(F .. "own", {["item/iron-plate/normal"] = 20})
  expect_group(F .. "chained", {["item/iron-plate/normal"] = 40})
  local status = call("sheet_status", "player", ids[2])
  assert(status[3].error:find('computed by the sheet "A/"'), status[3].error)
  assert(status[4].error and status[4].error:find("no group named 'y'"), tostring(status[4].error))
  -- The group picker offers neither the other sheet's groups nor this sheet's by full name.
  call("formulas_open", player.index)
  local editor = editor_in(player.gui.screen.logf_window)
  local picker = find(editor.scroll.tree, {logf = "group-name", def = 3, path = {}})
  -- The current, invalid reference stays shown as the selection.
  for i, name in ipairs(picker.items) do
    if i ~= picker.selected_index then
      assert(not name:find("A/x", 1, true) and not name:find(F .. "own", 1, true), "picker offers " .. name)
    end
  end
  -- Its contents list leaves out other sheets' groups as well.
  assert(not find(editor.scroll.tree.others, {logf = "preview-group", name = "A/x"}), "other sheets' groups not listed")

  -- Prefixes may not repeat or start one another.
  assert(not call("set_prefix", "[virtual-signal=signal-F] "), "same prefix")
  assert(not call("set_prefix", "[virtual"), "a prefix starting another")
  call("gui_event", "on_click", {element = editor.bar.prefix_row.edit, player_index = player.index})
  editor = editor_in(player.gui.screen.logf_window)
  editor.bar.prefix_row.field.text = "A/"
  call("gui_event", "on_confirmed", {element = editor.bar.prefix_row.field, player_index = player.index})
  editor = editor_in(player.gui.screen.logf_window)
  assert(not editor.bar.prefix_row.field, "a refused prefix ends editing")
  assert(call("sheet_prefix", "player", ids[2]) == F, "a clashing prefix is refused in the editor")

  -- Switching tabs shows that sheet's definitions.
  pane = player.gui.screen.logf_window.children[2].pane
  pane.selected_tab_index = 1
  call("gui_event", "on_tab_changed", {element = pane, player_index = player.index})
  editor = editor_in(player.gui.screen.logf_window)
  assert(find(editor.scroll.tree, {logf = "def-frame", name = "x"}) and not find(editor.scroll.tree, {logf = "def-frame", name = "own"}),
    "the first sheet's tree")

  -- Deleting a sheet takes two clicks; groups still in use keep their contents while unused ones are deleted.
  make("constant-combinator", {2.5, 0.5}).get_or_create_control_behavior().get_section(1).group = F .. "own"
  pane = player.gui.screen.logf_window.children[2].pane
  pane.selected_tab_index = 2
  call("gui_event", "on_tab_changed", {element = pane, player_index = player.index})
  editor = editor_in(player.gui.screen.logf_window)
  call("gui_event", "on_click", {element = editor.bar.delete, player_index = player.index})
  assert(#call("sheet_ids", "player") == 2 and editor.bar.delete.sprite == "utility/trash_white", "one click arms sheet delete")
  call("gui_event", "on_click", {element = editor.bar, player_index = player.index})
  assert(editor.bar.delete.sprite == "utility/trash", "clicking elsewhere disarms sheet delete")
  call("gui_event", "on_click", {element = editor.bar.delete, player_index = player.index})
  assert(#call("sheet_ids", "player") == 2, "re-arming does not delete")
  call("gui_event", "on_click", {element = editor.bar.delete, player_index = player.index})
  assert(#call("sheet_ids", "player") == 1, "the second click deletes")
  expect_group(F .. "own", {["item/iron-plate/normal"] = 20})
  assert(not group(F .. "chained"), "unused sheet groups are deleted")
  pane = player.gui.screen.logf_window.children[2].pane
  assert(#pane.tabs == 2, "its tab is gone")
  assert(not editor_in(player.gui.screen.logf_window).bar.delete.enabled, "the last sheet cannot be deleted")
  finish("sheets")
end

-- Documentation: every example gives the result it shows, every guide snippet evaluates, and
-- every text the reference shows translates, so no locale key is missing.
CASES.docs = function(tick)
  local force = game.forces.player
  local player = game.get_player(1)
  if tick == 1 then
    local function bag_of(entries)
      local bag = {}
      for _, entry in ipairs(entries) do
        local type, name, quality = lang.parse_signal(entry[1])
        bag[type .. "/" .. name .. "/" .. quality] = {type = type, name = name, quality = quality, count = entry[2],
          max = entry.max, import_from = entry.import_from, request_from = entry.request_from, min_delivery = entry.min_delivery}
      end
      return bag
    end
    local function describe(value) return type(value) == "table" and serpent.line(value) or tostring(value) end
    local qualities = lang.choices.quality()
    for _, fn in ipairs(lang.order) do
      for i, example in ipairs(docs.examples[fn]) do
        local given = example.given or {}
        local unlocked = true
        for _, q in ipairs(qualities) do
          if unlocked then force.unlock_quality(q) else force.lock_quality(q) end
          if q == given.unlocked then unlocked = false end
        end
        local label = fn .. " example " .. i
        local value, err = lang.evaluate(assert(sexp.parse(example.expr))[1], {
          force = force,
          group = function(name) return bag_of(assert((given.groups or {})[name], label .. ": no group " .. name)) end,
          network = function(selector, member)
            return bag_of(assert((given.networks or {})[selector.name .. "/" .. member], label .. ": no network"))
          end,
        })
        assert(not err, label .. ": " .. tostring(err))
        if type(example.result) == "number" then
          assert(value == example.result, label .. ": got " .. describe(value))
        else
          local want = bag_of(example.result)
          assert(type(value) == "table", label .. ": got " .. describe(value))
          for k, e in pairs(value) do
            if e.count == 0 then goto continue end
            local w = want[k]
            assert(w, label .. ": unexpected " .. k .. " in " .. describe(value))
            assert(math.abs(e.count - w.count) < 1e-6 and e.max == w.max and e.import_from == w.import_from
              and e.request_from == w.request_from and e.min_delivery == w.min_delivery, label .. ": got " .. describe(e))
            ::continue::
          end
          for k in pairs(want) do assert(value[k], label .. ": missing " .. k) end
        end
      end
    end

    for key, snippets in pairs(docs.snippets) do
      for i, text in ipairs(snippets) do
        local label = key .. " snippet " .. i
        local forms = assert(sexp.parse(text))
        local defs = {}
        for _, form in ipairs(forms) do
          if sexp.is_list(form) and sexp.is_sym(form[1], "def") then defs[form[2].str or form[2].sym] = form[3] end
        end
        local ctx = {force = force, network = function() return {} end}
        function ctx.group(name)
          if not defs[name] then return {} end
          local value, err = lang.evaluate(defs[name], ctx)
          if err then lang.fail("%s", err) end
          return value
        end
        for _, form in ipairs(forms) do
          local expr = sexp.is_sym(form[1], "def") and form[3] or form
          local value, err = lang.evaluate(expr, ctx)
          assert(not err, label .. ": " .. tostring(err))
          assert(type(value) == "table", label .. ": gives a number")
        end
      end
    end

    -- What Factoriopedia, the tips and the editor's tooltips show.
    local texts = {}
    local function add(label, text) texts[#texts + 1] = {label = label, text = text} end
    for name, p in pairs(prototypes.virtual_signal) do
      if name:find("^logf%-") then
        add(name .. " name", p.localised_name)
        add(name .. " description", p.localised_description)
        add(name .. " page", p.factoriopedia_description)
        for _, field in ipairs(p.custom_tooltip_fields or {}) do add(name .. " field", field.value) end
      end
    end
    for _, fn in ipairs(lang.order) do add(fn .. " tooltip", docs.tooltip(fn)) end
    for _, tip in ipairs(docs.tips) do
      add(tip.name .. " name", {"tips-and-tricks-item-name." .. tip.name})
      add(tip.name .. " description", docs.with_snippets("tips-and-tricks-item-description", tip.name))
    end
    storage.pending = {}
    for _, t in ipairs(texts) do
      local id = player.request_translation(t.text)
      assert(id, "translation request for " .. t.label)
      storage.pending[id] = t.label
    end
  elseif tick == 2 then
    -- Each function row has a ? that opens the function's page.
    for _, q in ipairs(lang.choices.quality()) do force.unlock_quality(q) end
    set_program('(def "x" (quality-up {iron-plate 1}))')
    call("formulas_open", player.index)
    local tree = editor_in(player.gui.screen.logf_window).scroll.tree
    local help = assert(find(tree, {logf = "fn-help", def = 1, path = {}}), "? on the function row")
    assert(help.tags.fn == "quality-up", serpent.line(help.tags))
    call("gui_event", "on_click", {element = help, player_index = player.index})
  elseif next(storage.pending) == nil then
    finish("docs")
  elseif tick > 600 then
    error("no translation for: " .. serpent.line(storage.pending))
  end
end

script.on_event(defines.events.on_string_translated, function(e)
  if not (storage.pending and storage.pending[e.id]) then return end
  assert(e.translated, storage.pending[e.id] .. " has a missing locale key: " .. e.result)
  storage.pending[e.id] = nil
end)

-- Tests name groups without the prefix; CASES.guard covers it.
script.on_init(function() remote.call("logistic-formulas", "set_prefix", "") end)

script.on_event(defines.events.on_tick, function(e)
  if e.tick == 0 then return end
  -- The save fixture is created by a server run, which has no test argument.
  local handler = assert(CASES[script.test_arg or "save"], "unknown case: " .. tostring(script.test_arg))
  handler(e.tick)
end)
