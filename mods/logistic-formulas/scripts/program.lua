-- Group formulas: per force, a list of sheets; a sheet is a list of definitions, each
-- computing one logistic group named with the sheet's prefix. Sheets are independent: a
-- formula reads its own sheet's definitions and groups no formula computes, never another
-- sheet's groups, so no cycle can span sheets. The groups are written through sections of
-- hidden combinators the mod owns, separate for each sheet.
local sexp = require("scripts.sexp")
local lang = require("scripts.lang")

local program = {}

program.SURFACE = "logf-groups"
program.OWNER = "logf-group-owner"
local SECTIONS_PER_OWNER = 100

-- storage.programs[force_index] = {sheets = {sheet, ...}, next_id = number}
-- sheet = {
--   id = number, prefix = string,
--   defs = {{name = string, expr = form}, ...},
--   status = {[i] = {error = string or nil, signals = count}},  parallel to defs
--   owners = {LuaEntity, ...},
--   sources = {[group name] = signature}   groups read from outside the program
--   last = {[def name] = filters}          what each definition last produced
--   dynamic = boolean                      reads a logistic network
--   history = {
--     undo = {entry, ...}, redo = {entry, ...},   most recent last
--     saved = snapshot of the sheet as last recorded,
--     merge = key of the last change, if the next one with that key joins it,
--     version = number, raised on every change to the history,
--   }
-- }
-- snapshot = {prefix = string, defs = copy of defs, text = the defs as text}
-- entry = snapshot plus {label = string}: the sheet before (undo) or after (redo) that change
program.DEFAULT_PREFIX = "[virtual-signal=signal-F] "
-- Letters tried, in order, for the prefix icon of a new sheet.
local LETTERS = "FGHJKLMNPQRSTUVWXYZABCDE"

-- Changes kept for undo, per sheet.
program.HISTORY = 50

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

local function snapshot(sheet)
  return {prefix = sheet.prefix, defs = copy(sheet.defs), text = sexp.print_program(program.forms_from_defs(sheet.defs))}
end

local function same(a, b) return a.prefix == b.prefix and a.text == b.text end

local function new_history(sheet)
  sheet.history = {undo = {}, redo = {}, saved = snapshot(sheet), version = 0}
  return sheet.history
end

-- A sheet's history. Saves from before undo get theirs in program.init; this covers a sheet
-- that missed it, starting from its current state.
local function history(sheet)
  return sheet.history or new_history(sheet)
end

function program.init()
  storage.programs = storage.programs or {}
  for _, record in pairs(storage.programs) do
    for _, sheet in ipairs(record.sheets) do
      if not sheet.history then new_history(sheet) end
    end
  end
end

local function new_sheet(record, prefix)
  local sheet = {id = record.next_id, prefix = prefix, defs = {}, status = {}, owners = {}, sources = {}, last = {}}
  new_history(sheet)
  record.next_id = record.next_id + 1
  record.sheets[#record.sheets + 1] = sheet
  return sheet
end

-- The force's record, with one empty sheet to start.
function program.get(force)
  -- Remote calls can arrive before on_init, from a scenario initialised first.
  program.init()
  local record = storage.programs[force.index]
  if not record then
    record = {sheets = {}, next_id = 1}
    storage.programs[force.index] = record
    new_sheet(record, program.DEFAULT_PREFIX)
  end
  return record
end

function program.sheets(force) return program.get(force).sheets end

function program.sheet(force, id)
  for _, sheet in ipairs(program.sheets(force)) do
    if sheet.id == id then return sheet end
  end
end

-- Why a prefix cannot be used for this sheet, or nil. A prefix that starts another sheet's
-- prefix could produce the same group names, so prefixes must not start one another.
function program.prefix_problem(force, sheet, prefix)
  for _, other in ipairs(program.sheets(force)) do
    if other ~= sheet and (other.prefix:sub(1, #prefix) == prefix or prefix:sub(1, #other.prefix) == other.prefix) then
      if other.prefix == prefix then return "another sheet has this prefix" end
      return "it overlaps the prefix of another sheet, \"" .. other.prefix .. "\""
    end
  end
end

function program.set_prefix(force, sheet, prefix)
  local problem = program.prefix_problem(force, sheet, prefix)
  if problem then return false, problem end
  sheet.prefix = prefix
  program.record(sheet, "change the prefix")
  program.run(force)
  return true
end

-- A new sheet with the first free letter icon as its prefix. Returns nil and a reason when
-- no prefix fits, which happens when a sheet has an empty prefix.
function program.add_sheet(force)
  local record = program.get(force)
  for i = 1, #LETTERS do
    local prefix = "[virtual-signal=signal-" .. LETTERS:sub(i, i) .. "] "
    if not program.prefix_problem(force, nil, prefix) then return new_sheet(record, prefix) end
  end
  local prefix = "sheet " .. record.next_id .. ": "
  if program.prefix_problem(force, nil, prefix) then return nil, "a sheet without a prefix leaves no room for another" end
  return new_sheet(record, prefix)
end

local function surface()
  local s = game.surfaces[program.SURFACE]
  if not s then
    local empty = {treat_missing_as_default = false, settings = {}}
    s = game.create_surface(program.SURFACE, {
      default_enable_all_autoplace_controls = false,
      autoplace_settings = {entity = empty, tile = empty, decorative = empty},
      no_enemies_mode = true, peaceful_mode = true,
    })
    s.generate_with_lab_tiles = true
    for _, force in pairs(game.forces) do force.set_surface_hidden(s, true) end
  end
  return s
end

local function owner(p, force, index)
  local entity = p.owners[index]
  if not (entity and entity.valid) then
    -- A row per force and sheet: forces are at most 64.
    local row = p.id * 130 + force.index * 2
    entity = surface().create_entity{name = program.OWNER, position = {index * 2 + 0.5, row + 0.5}, force = force}
    entity.destructible = false
    p.owners[index] = entity
  end
  return entity
end

local function section(p, force, index)
  local behavior = owner(p, force, math.ceil(index / SECTIONS_PER_OWNER)).get_or_create_control_behavior()
  local slot = (index - 1) % SECTIONS_PER_OWNER + 1
  while behavior.sections_count < slot do behavior.add_section() end
  return behavior.get_section(slot)
end

local signature = lang.signature

-- The logistic network a selector names, or nil.
function program.find_network(force, selector)
  if selector.name then
    for _, networks in pairs(force.logistic_networks) do
      for _, network in pairs(networks) do
        if network.custom_name == selector.name then return network end
      end
    end
    return nil
  end
  local surface = game.surfaces[selector.surface]
  return surface and force.find_logistic_network_by_position({selector.x, selector.y}, surface)
end

local function network_bag(force, selector, member)
  local network = program.find_network(force, selector)
  if not network then
    if selector.name then lang.fail("there is no logistic network named '%s'", selector.name) end
    lang.fail("there is no logistic network at %s %g, %g", selector.surface, selector.x, selector.y)
  end
  if member == "all" then return lang.bag_from_contents(network.get_contents()) end
  return lang.bag_from_contents(network.get_contents(member))
end

-- Networks of a force, for pickers: {label, form arguments after "network"}.
function program.network_choices(force)
  local choices = {}
  for surface_name, networks in pairs(force.logistic_networks) do
    for _, network in pairs(networks) do
      local cell = network.cells[1]
      if network.custom_name and network.custom_name ~= "" then
        choices[#choices + 1] = {label = network.custom_name, args = {sexp.str(network.custom_name)}}
      elseif cell and cell.owner.type == "roboport" then
        local at = cell.owner.position
        choices[#choices + 1] = {
          label = string.format("%s #%d (%d roboport%s)", surface_name, network.network_id, #network.cells,
            #network.cells == 1 and "" or "s"),
          args = {sexp.str(surface_name), at.x, at.y},
        }
      end
    end
  end
  table.sort(choices, function(a, b) return a.label < b.label end)
  return choices
end

local function source_signature(force, name)
  local group = force.get_logistic_group(name)
  if not group then return "missing" end
  return signature(lang.filters_from_bag(lang.bag_from_filters(group.filters)))
end

-- The logistic group a definition writes: its name behind the sheet's prefix.
function program.group_name(sheet, name)
  return sheet.prefix .. name
end

-- The sheet and definition whose group this is, or nil.
function program.owner_of_group(force, group_name)
  local record = storage.programs[force.index]
  if not record then return nil end
  for _, sheet in ipairs(record.sheets) do
    for _, def in ipairs(sheet.defs) do
      if sheet.prefix .. def.name == group_name then return sheet, def end
    end
  end
end

-- The definition a formula in this sheet means by `name`: its own definition by plain or
-- full group name, or nil for a group outside every formula. Raises a formula error for
-- another sheet's group.
local function resolve(force, sheet, name)
  for _, def in ipairs(sheet.defs) do
    if def.name == name then return def.name end
  end
  local other, def = program.owner_of_group(force, name)
  if other == sheet then return def.name end
  if other then
    lang.fail("'%s' is computed by the sheet \"%s\"; a sheet cannot read another sheet's groups", name, other.prefix)
  end
end

function program.run(force)
  for _, sheet in ipairs(program.sheets(force)) do program.run_sheet(force, sheet) end
  if program.on_run then program.on_run(force) end
end

local function delete_if_unused(force, names)
  for name in pairs(names) do
    if name ~= "" then
      local group = force.get_logistic_group(name)
      if group and #group.members == 0 then force.delete_logistic_group(name) end
    end
  end
end

-- Evaluates every definition of a sheet in dependency order and writes the groups.
function program.run_sheet(force, p)
  local by_name, results, state = {}, {}, {}
  p.status, p.sources = {}, {}
  for i, def in ipairs(p.defs) do
    p.status[i] = {signals = 0}
    if by_name[def.name] then p.status[i].error = "another definition is already named '" .. def.name .. "'"
    else by_name[def.name] = i end
  end

  local visit
  local ctx = {force = force}
  p.dynamic = false
  function ctx.network(selector, member)
    -- Network contents change constantly; programs reading them run on every poll.
    p.dynamic = true
    return network_bag(force, selector, member)
  end
  function ctx.group(name)
    local own = resolve(force, p, name)
    local i = own and by_name[own]
    if not i then
      p.sources[name] = p.sources[name] or source_signature(force, name)
      local group = force.get_logistic_group(name)
      if not group then lang.fail("there is no group named '%s'", name) end
      return lang.bag_from_filters(group.filters)
    end
    if state[i] == "running" then lang.fail("'%s' depends on itself", name) end
    visit(i)
    if not results[i] then lang.fail("'%s' has an error", name) end
    return results[i]
  end

  function visit(i)
    if state[i] then return end
    state[i] = "running"
    local status = p.status[i]
    if not status.error then
      local value, err = lang.evaluate(p.defs[i].expr, ctx)
      if err then status.error = err
      elseif type(value) == "number" then status.error = "the result is a number, not a group"
      else results[i] = value end
    end
    state[i] = "done"
  end
  for i in ipairs(p.defs) do visit(i) end

  local used, released = 0, {}
  for i, def in ipairs(p.defs) do
    if by_name[def.name] == i then
      used = used + 1
      local s = section(p, force, used)
      local group_name = program.group_name(p, def.name)
      if s.group ~= group_name then
        if s.group ~= "" then released[s.group] = true end
        s.group = ""
        s.filters = {}
        s.group = group_name
      end
      if results[i] then p.last[def.name] = lang.filters_from_bag(results[i]) end
      local filters = p.last[def.name]
      if filters then
        p.status[i].signals = #filters
        if signature(filters) ~= signature(lang.filters_from_bag(lang.bag_from_filters(s.filters))) then s.filters = filters end
      end
    end
  end
  -- Release the sections of removed definitions; unreferenced groups are removed,
  -- while groups still used elsewhere keep their last contents.
  for name in pairs(p.last) do
    if not by_name[name] then p.last[name] = nil end
  end
  local index = used + 1
  while p.owners[math.ceil(index / SECTIONS_PER_OWNER)] do
    local entity = p.owners[math.ceil(index / SECTIONS_PER_OWNER)]
    if not entity.valid then break end
    local behavior = entity.get_or_create_control_behavior()
    local slot = (index - 1) % SECTIONS_PER_OWNER + 1
    if slot > behavior.sections_count then break end
    local s = behavior.get_section(slot)
    if s.group ~= "" then
      released[s.group] = true
      s.group = ""
      s.filters = {}
    end
    index = index + 1
  end
  delete_if_unused(force, released)
end

-- Evaluates one formula against the groups as currently written, for display.
-- Returns the value, or nil and an error message.
function program.preview(force, sheet, form)
  return lang.evaluate(form, {
    force = force,
    group = function(name)
      local own = resolve(force, sheet, name)
      if own then name = program.group_name(sheet, own) end
      local group = force.get_logistic_group(name)
      if not group then lang.fail("there is no group named '%s'", name) end
      return lang.bag_from_filters(group.filters)
    end,
    network = function(selector, member) return network_bag(force, selector, member) end,
  })
end

-- Re-runs the sheets whose outside groups changed since the last run, and restores formula
-- groups changed by hand or by scripts. on_overwrite(force, sheet, def name) reports each.
function program.poll()
  for _, force in pairs(game.forces) do
    local record = storage.programs[force.index]
    local any = false
    for _, p in ipairs(record and record.sheets or {}) do
      if #p.defs > 0 then
        local stale = p.dynamic
        for name, seen in pairs(p.sources) do
          if stale then break end
          stale = source_signature(force, name) ~= seen
        end
        for name, filters in pairs(p.last) do
          if source_signature(force, program.group_name(p, name)) ~= signature(filters) then
            stale = true
            if program.on_overwrite then program.on_overwrite(force, p, name) end
          end
        end
        if stale then
          program.run_sheet(force, p)
          any = true
        end
      end
    end
    if any and program.on_run then program.on_run(force) end
  end
end

-- Removes a sheet. Groups still used elsewhere keep their last contents; unreferenced
-- groups and the sheet's hidden combinators are removed.
function program.remove_sheet(force, sheet)
  local sheets = program.sheets(force)
  for i, other in ipairs(sheets) do
    if other == sheet then table.remove(sheets, i) end
  end
  local released = {}
  for _, entity in pairs(sheet.owners) do
    if entity.valid then
      local behavior = entity.get_or_create_control_behavior()
      for slot = 1, behavior.sections_count do
        local s = behavior.get_section(slot)
        if s.group ~= "" then released[s.group] = true end
      end
      entity.destroy()
    end
  end
  delete_if_unused(force, released)
  if program.on_run then program.on_run(force) end
end

function program.run_all()
  for _, force in pairs(game.forces) do
    if storage.programs[force.index] then program.run(force) end
  end
end

function program.forget(force_index)
  local record = storage.programs[force_index]
  if not record then return end
  for _, sheet in ipairs(record.sheets or {}) do
    for _, entity in pairs(sheet.owners) do
      if entity.valid then entity.destroy() end
    end
  end
  storage.programs[force_index] = nil
end

-- Top-level forms -> definitions, or nil and an error message.
function program.defs_from_forms(forms)
  local defs = {}
  for i, form in ipairs(forms) do
    if not (sexp.is_list(form) and sexp.is_sym(form[1], "def") and #form == 3) then
      return nil, "form " .. i .. ": expected (def \"group name\" formula)"
    end
    local name = type(form[2]) == "table" and (form[2].str or form[2].sym)
    if not name or name == "" then return nil, "form " .. i .. ": the group name must be a string" end
    defs[i] = {name = name, expr = form[3]}
  end
  return defs
end

function program.forms_from_defs(defs)
  local forms = {}
  for i, def in ipairs(defs) do forms[i] = {sexp.sym("def"), sexp.str(def.name), def.expr} end
  return forms
end

function program.text(sheet)
  return sexp.print_program(program.forms_from_defs(sheet.defs))
end

-- Parses S-expression text into definitions, or returns nil and an error message.
function program.parse_text(text)
  local forms, err = sexp.parse(text)
  if not forms then return nil, err end
  return program.defs_from_forms(forms)
end

-- Replaces a sheet's definitions from text. Returns true, or false and an error message.
function program.set_text(force, sheet, text)
  local defs, err = program.parse_text(text)
  if not defs then return false, err end
  sheet.defs = defs
  program.record(sheet, "apply the sheet text")
  program.run_sheet(force, sheet)
  if program.on_run then program.on_run(force) end
  return true
end

-- Records the sheet's current state as an undoable change named `label`, if it changed.
-- A change with the same `merge` key as the one before joins it, as typing in one field does.
function program.record(sheet, label, merge)
  local h = history(sheet)
  local now = snapshot(sheet)
  if same(now, h.saved) then return end
  h.redo = {}
  if not (merge and h.merge == merge and #h.undo > 0) then
    local entry = h.saved
    entry.label = label
    h.undo[#h.undo + 1] = entry
    if #h.undo > program.HISTORY then table.remove(h.undo, 1) end
  end
  h.saved, h.merge = now, merge
  h.version = (h.version or 0) + 1
end

-- Records the changes of every sheet of a force.
function program.record_all(force, label, merge)
  for _, sheet in ipairs(program.sheets(force)) do program.record(sheet, label, merge) end
end

-- Ends the change being merged, so the next one is recorded on its own.
function program.end_merge(sheet)
  history(sheet).merge = nil
end

-- Changes whenever the history does, so its display is redrawn only then.
function program.history_version(sheet)
  return history(sheet).version or 0
end

-- The change undo or redo would revert or repeat: its label and the sheet before and after,
-- as {prefix, defs}. Nil when there is none.
function program.next_change(sheet, redo)
  local h = history(sheet)
  local list = redo and h.redo or h.undo
  local entry = list[#list]
  if not entry then return nil end
  if redo then return {label = entry.label, before = h.saved, after = entry} end
  return {label = entry.label, before = entry, after = h.saved}
end

-- Undoes the last change of a sheet, or redoes the last undone one. Returns true, or false
-- and why not.
function program.step_history(force, sheet, redo)
  -- A change not recorded yet becomes the step to undo, rather than being lost.
  program.record(sheet, "edit the sheet")
  local h = history(sheet)
  local from, to = redo and h.redo or h.undo, redo and h.undo or h.redo
  local entry = from[#from]
  if not entry then return false, redo and "nothing to redo" or "nothing to undo" end
  if entry.prefix ~= sheet.prefix then
    local problem = program.prefix_problem(force, sheet, entry.prefix)
    if problem then return false, "the prefix \"" .. entry.prefix .. "\" cannot be restored: " .. problem end
  end
  table.remove(from)
  local current = h.saved
  current.label = entry.label
  to[#to + 1] = current
  sheet.prefix, sheet.defs = entry.prefix, copy(entry.defs)
  entry.label = nil
  h.saved, h.merge = entry, nil
  h.version = (h.version or 0) + 1
  program.run(force)
  return true
end

return program
