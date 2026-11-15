local program = require("scripts.program")
local formula_gui = require("scripts.formula_gui")

local function ensure_buttons()
  for _, player in pairs(game.players) do formula_gui.ensure_button(player) end
end

script.on_init(function()
  program.init()
  ensure_buttons()
end)
script.on_configuration_changed(function()
  program.init()
  program.run_all()
  ensure_buttons()
end)
script.on_event(defines.events.on_player_created, function(event)
  formula_gui.ensure_button(game.get_player(event.player_index))
end)

-- Recipe productivity does not enter formulas, but quality unlocks change what quality-up may produce.
local function on_research(event)
  if storage.programs[event.research.force.index] then program.run(event.research.force) end
end
script.on_event(defines.events.on_research_finished, on_research)
script.on_event(defines.events.on_research_reversed, on_research)

-- Formula groups are owned by their formulas: an edit through any member is undone, with a warning.
local function warn(force, sheet, name, player)
  storage.warned = storage.warned or {}
  local key = force.index .. "/" .. sheet.id .. "/" .. name
  -- One warning per group per tick, whether the event or the poll noticed first.
  if storage.warned[key] == game.tick then return end
  storage.warned[key] = game.tick
  local message = string.format("[color=yellow]Logistic formulas:[/color] the group \"%s\" is computed by a formula, so the "
    .. "change was undone. Edit its formula instead.", program.group_name(sheet, name))
  storage.last_warning = message
  local text = {"logf-ui.owned-warning", program.group_name(sheet, name)}
  if player then player.print(text) else force.print(text) end
end

program.on_overwrite = function(force, sheet, name) warn(force, sheet, name) end

script.on_event(defines.events.on_entity_logistic_slot_changed, function(event)
  local entity, section = event.entity, event.section
  if not (entity.valid and section.valid) or entity.name == program.OWNER then return end
  local sheet, def = program.owner_of_group(entity.force, section.group)
  if not def then return end
  warn(entity.force, sheet, def.name, event.player_index and game.get_player(event.player_index))
  program.run(entity.force)
end)

script.on_nth_tick(30, function()
  program.poll()
  formula_gui.tick()
end)
script.on_event(defines.events.on_forces_merged, function(event) program.forget(event.source_index) end)

script.on_event(defines.events.on_gui_closed, formula_gui.on_closed)
script.on_event(defines.events.on_gui_opened, formula_gui.on_opened)
script.on_event({defines.events.on_player_display_resolution_changed, defines.events.on_player_display_scale_changed},
  formula_gui.on_display_changed)
script.on_event(defines.events.on_gui_click, formula_gui.on_click)
script.on_event(defines.events.on_gui_text_changed, formula_gui.on_text_changed)
script.on_event(defines.events.on_gui_checked_state_changed, formula_gui.on_checked)
script.on_event(defines.events.on_gui_selection_state_changed, formula_gui.on_selection)
script.on_event(defines.events.on_gui_elem_changed, formula_gui.on_elem_changed)
script.on_event(defines.events.on_gui_confirmed, formula_gui.on_confirmed)
script.on_event(defines.events.on_gui_selected_tab_changed, formula_gui.on_tab_changed)
script.on_event(defines.events.on_runtime_mod_setting_changed, formula_gui.on_setting_changed)

local function toggle_formulas(event)
  formula_gui.toggle(game.get_player(event.player_index))
end
script.on_event("logf-formulas", toggle_formulas)
script.on_event("logf-focus-search", function(event) formula_gui.focus_search(game.get_player(event.player_index)) end)
script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name == "logf-formulas" then toggle_formulas(event) end
end)

-- Test and scenario hooks. Calls without a sheet id act on the force's first sheet.
remote.add_interface("logistic-formulas", {
  last_warning = function() return storage.last_warning end,
  set_prefix = function(prefix)
    local force = game.forces.player
    return program.set_prefix(force, program.sheets(force)[1], prefix)
  end,
  group_name = function(name) return program.group_name(program.sheets(game.forces.player)[1], name) end,
  add_sheet = function(force)
    local sheet, problem = program.add_sheet(game.forces[force])
    return sheet and sheet.id, problem
  end,
  sheet_ids = function(force)
    local ids = {}
    for i, sheet in ipairs(program.sheets(game.forces[force])) do ids[i] = sheet.id end
    return ids
  end,
  set_sheet_program = function(force, id, text)
    local f = game.forces[force]
    return program.set_text(f, program.sheet(f, id), text)
  end,
  sheet_status = function(force, id) return program.sheet(game.forces[force], id).status end,
  sheet_prefix = function(force, id) return program.sheet(game.forces[force], id).prefix end,
  set_program = function(force, text)
    local f = game.forces[force]
    return program.set_text(f, program.sheets(f)[1], text)
  end,
  program_text = function(force) return program.text(program.sheets(game.forces[force])[1]) end,
  network_choices = function(force)
    local out = {}
    for i, choice in ipairs(program.network_choices(game.forces[force])) do out[i] = {label = choice.label} end
    return out
  end,
  program_status = function(force) return program.sheets(game.forces[force])[1].status end,
  focus_search = function(player_index) formula_gui.focus_search(game.get_player(player_index)) end,
  formulas_open = function(player_index) formula_gui.open(game.get_player(player_index)) end,
  -- Only this mod may write its settings.
  set_window_size = function(player_index, value)
    game.get_player(player_index).mod_settings["logf-window-size"] = {value = value}
  end,
  gui_event = function(kind, event) formula_gui[kind](event) end,
})
