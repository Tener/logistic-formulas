-- Sandbox for trying the mod by hand: everything researched, sample formulas, a sheet with
-- the README's examples, a small bot-fed factory west of the spawn, and with Space Age a
-- rocket silo south of it supplying a platform in orbit.

-- The logistic group a formula definition writes, with the configured prefix.
local function formula_group(name) return remote.call("logistic-formulas", "group_name", name) end

local function maker(surface, force)
  return function(name, position, extra, modules)
    local spec = {name = name, position = position, force = force}
    for k, v in pairs(extra or {}) do spec[k] = v end
    local e = assert(surface.create_entity(spec), "could not create " .. name)
    if modules then e.get_module_inventory().insert(modules) end
    return e
  end
end

local function prepare(surface)
  local area = {{-46, -20}, {20, 36}}
  for _, e in pairs(surface.find_entities(area)) do
    if e.type ~= "character" then e.destroy() end
  end
  local tiles = {}
  for x = -46, 19 do for y = -20, 35 do tiles[#tiles + 1] = {name = "refined-concrete", position = {x, y}} end end
  surface.set_tiles(tiles)
end

local NETWORK = "Main"

-- Requester chest -> inserter -> assembler -> inserter -> passive provider, left to right.
-- The requester asks for the logistic group named after the line.
local function line(make, y, recipe, group)
  local requester = make("requester-chest", {-36.5, y})
  requester.get_requester_point().add_section(formula_group(group))
  -- An inserter's direction is the side it picks up from.
  make("fast-inserter", {-35.5, y}, {direction = defines.direction.west})
  make("assembling-machine-2", {-33.5, y}, {recipe = recipe})
  make("fast-inserter", {-31.5, y}, {direction = defines.direction.west})
  return make("passive-provider-chest", {-30.5, y})
end

local function build_factory(surface, force)
  local make = maker(surface, force)
  local power = make("electric-energy-interface", {-20, -8})
  power.power_production = 1e9
  power.electric_buffer_size = 1e9
  local poles = {}
  for _, at in ipairs{{-26, -4}, {-38, -4}, {-38, 6}, {-26, 6}} do poles[#poles + 1] = make("substation", at) end
  local copper = defines.wire_connector_id.pole_copper
  for i = 2, #poles do
    poles[i - 1].get_wire_connector(copper, true).connect_to(poles[i].get_wire_connector(copper, true))
  end

  for _, at in ipairs{{-32, -12}, {-22, 0}} do
    local roboport = make("roboport", at)
    local robots = roboport.get_inventory(defines.inventory.roboport_robot)
    robots.insert{name = "logistic-robot", count = 30}
    robots.insert{name = "construction-robot", count = 10}
  end
  surface.find_entities_filtered{name = "roboport", limit = 1}[1].logistic_network.custom_name = NETWORK

  for i, item in ipairs{"iron-plate", "copper-plate", "iron-plate"} do
    make("storage-chest", {-42.5 + i, -8.5}).insert{name = item, count = 4800}
  end
  -- Some of the mall in stock, so the README sheet's "missing" is a real difference.
  make("storage-chest", {-38.5, -8.5}).insert{name = "transport-belt", count = 120}

  storage.outputs = {
    gears = line(make, 0.5, "iron-gear-wheel", "gear line"),
    cables = line(make, 5.5, "copper-cable", "cable line"),
    circuits = line(make, 10.5, "electronic-circuit", "circuit line"),
  }
end

local PLATFORM = "Demo platform"

-- A silo fed with rocket parts by robots, which fills the platform's requests from the network,
-- and a block of storage chests with rocket components.
local function build_space(surface, force)
  local make = maker(surface, force)
  local south = make("substation", {-26, 16})
  local copper = defines.wire_connector_id.pole_copper
  south.get_wire_connector(copper, true).connect_to(
    surface.find_entity("substation", {-26, 6}).get_wire_connector(copper, true))
  local robots = make("roboport", {-22, 22}).get_inventory(defines.inventory.roboport_robot)
  robots.insert{name = "logistic-robot", count = 30}

  for i, item in ipairs{"processing-unit", "low-density-structure", "low-density-structure", "rocket-fuel", "rocket-fuel"} do
    make("storage-chest", {-42.5 + i, -6.5}).insert{name = item, count = 4800}
  end

  -- Speed modules shorten the wait for a rocket to under a minute.
  local silo = make("rocket-silo", {-34.5, 24.5}, nil, {name = "speed-module-3", count = 4})
  silo.use_transitional_requests = true
  local requester = make("requester-chest", {-28.5, 24.5})
  requester.get_requester_point().add_section(formula_group("rocket parts"))
  make("fast-inserter", {-29.5, 24.5}, {direction = defines.direction.east})

  local platform = force.create_space_platform{name = PLATFORM, planet = "nauvis", starter_pack = "space-platform-starter-pack"}
  platform.apply_starter_pack()
  platform.hub.get_requester_point().add_section(formula_group("platform supplies"))
  storage.silo, storage.platform = silo, platform
end

local SPACE_PROGRAM = [[

; Space Age: the silo is fed by its recipe; the platform imports from Nauvis.
(def "rocket parts" (ingredients rocket-part 50))
(def "platform supplies" (import-from {iron-plate 200 copper-plate 200 low-density-structure 20} nauvis))
]]

local PROGRAM = [[
(def "mall" {transport-belt 200 underground-belt 50 splitter 20 fast-inserter 50 medium-electric-pole 50})
(def "mall rare" (quality-up (group "mall") 2))
(def "mall stacks" (round-to-stacks (group "mall")))
(def "mall rare buffer" (round-to-stacks (multiply 3 (drop (quality-up (group "mall") 2) splitter))))

; The demo factory's requester chests use these three groups.
(def "gear line" {iron-plate 100})
(def "cable line" {copper-plate 100})
(def "circuit line" (multiply 40 {iron-plate 1 copper-cable 3}))

(def "demo stock" (network "Main"))
(def "demo products" (keep (network "Main" providers) iron-gear-wheel electronic-circuit))
(def "demo shortfall" (keep-positive (subtract {iron-gear-wheel 500 electronic-circuit 500} (group "demo products"))))
]]

-- The README's examples, on a sheet of their own for screenshots.
local README_PROGRAM = [[
(def "mall"      {transport-belt 200 fast-inserter 50 pipe:rare 10})
(def "mall rare" (quality-up (group "mall") 2))
(def "missing"   (keep-positive (subtract (group "mall") (network "Main" storage))))
(def "line x4"   (round-to-stacks (multiply 4 (ingredients electronic-circuit 1k))))
(def "to orbit"  (import-from (set-max (group "mall") (multiply 2 (group "mall"))) nauvis))
]]

script.on_event(defines.events.on_player_created, function(event)
  local player = game.get_player(event.player_index)
  player.cheat_mode = true
  -- Alt mode, so recipes, chest contents and requests show on the map.
  player.game_view_settings.show_entity_info = true
  player.force.research_all_technologies()
  -- Everything is known from the start; nothing is flagged as newly unlocked.
  player.clear_recipe_notifications()
  prepare(player.surface)
  build_factory(player.surface, player.force)
  local space = script.active_mods["space-age"] ~= nil
  if space then build_space(player.surface, player.force) end
  player.insert{name = "requester-chest", count = 10}
  local ok, err = remote.call("logistic-formulas", "set_program", player.force.name, PROGRAM .. (space and SPACE_PROGRAM or ""))
  assert(ok, err)
  local readme = assert(remote.call("logistic-formulas", "add_sheet", player.force.name))
  ok, err = remote.call("logistic-formulas", "set_sheet_program", player.force.name, readme, README_PROGRAM)
  assert(ok, err)
  storage.readme = readme
  player.print({"logf-ui.playtest-hint"})
  if space then
    player.print("A rocket silo south of the factory supplies \"" .. PLATFORM .. "\" in orbit; open it from the remote view.")
  end
end)

local function count(chest, item) return chest.get_item_count(item) end

local function hub_count(item)
  return storage.platform.hub.get_inventory(defines.inventory.hub_main).get_item_count(item)
end

script.on_event(defines.events.on_tick, function(event)
  if script.test_arg == "smoke" and event.tick == 2 then
    local player = assert(game.get_player(1), "no player")
    assert(player.get_item_count("requester-chest") == 10, "sandbox items missing")
    assert(player.game_view_settings.show_entity_info, "alt mode is on")
    local fresh = #player.get_recipe_notifications()
    assert(fresh == 0, fresh .. " recipes flagged as newly researched")
    for i, status in ipairs(remote.call("logistic-formulas", "program_status", "player")) do
      assert(not status.error, "sandbox formula " .. i .. ": " .. tostring(status.error))
    end
    for i, status in ipairs(remote.call("logistic-formulas", "sheet_status", "player", storage.readme)) do
      assert(not status.error, "README formula " .. i .. ": " .. tostring(status.error))
    end
    print("[TEST] playtest sandbox: passed")
    script.finish_test(true)
  elseif script.test_arg == "factory" and event.tick == 3600 then
    -- After a minute, robots have fed every line, including cables carried from line to line.
    local out = storage.outputs
    local gears, cables, circuits = count(out.gears, "iron-gear-wheel"), count(out.cables, "copper-cable"),
      count(out.circuits, "electronic-circuit")
    print(string.format("[TEST] after 60 s: %d gears, %d cables, %d circuits", gears, cables, circuits))
    assert(gears > 0 and circuits > 0, "the demo factory must produce")
    local products = game.forces.player.get_logistic_group(formula_group("demo products"))
    assert(products and #products.filters > 0, "the network formula sees the products")
    print("[TEST] demo factory: passed")
    script.finish_test(true)
  elseif script.test_arg == "space" and event.tick > 1 then
    local platform = storage.platform
    if event.tick == 2 then
      assert(platform.hub and platform.space_location and platform.space_location.name == "nauvis",
        "the platform waits in Nauvis orbit")
      assert(storage.silo.transitional_request_target == nil or storage.silo.transitional_request_target.valid, "silo target")
    end
    -- A rocket built from robot-delivered parts carries the platform's requests up.
    if hub_count("iron-plate") > 0 then
      print(string.format("[TEST] at tick %d the hub holds %d iron, %d copper, %d low density structures", event.tick,
        hub_count("iron-plate"), hub_count("copper-plate"), hub_count("low-density-structure")))
      print("[TEST] demo platform supply: passed")
      script.finish_test(true)
    end
    assert(event.tick < 18000, string.format("no delivery to the platform; silo has %d parts, status %d",
      storage.silo.rocket_parts, storage.silo.rocket_silo_status))
  end
end)
