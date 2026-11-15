-- Group formula editor: a window with a tab per sheet. Each definition shows its group's
-- contents on the left and its formula on the right, as a tree and as highlighted text.
-- A separate window edits a whole sheet as text.
local mod_gui = require("mod-gui")
local sexp = require("scripts.sexp")
local lang = require("scripts.lang")
local program = require("scripts.program")
local docs = require("scripts.docs")

local fgui = {}

local WINDOW = "logf_window"
local network_parts, apply_size, sheet_caption, build_editor, editable_label, sync_opened
local TOOLTIP_LINES = 40
local INDENT = 24
local DEF_DELETE_TOOLTIP = "Delete the definition (click twice). Groups still in use keep their last contents."
local function sheet_delete_tooltip(only)
  return only and "The last sheet cannot be deleted"
    or "Delete this sheet (click twice). Groups still in use keep their last contents."
end
local NUMBER_TOOLTIP = "A number; k, M and G multiply by a thousand, a million and a billion: 5k, 1.5M."
-- Slots per row of a group's contents, and the width they take.
local PREVIEW_COLUMNS = 7
local VALUE_WIDTH = PREVIEW_COLUMNS * 40 + 8

-- Syntax-highlighting RGB colors for function names, matching their icon families.
local FN_COLOR = {}
for fn, family in pairs(docs.family_of) do FN_COLOR[fn] = family.color end

local SEXP_WIDTH = 52

-- Pretty-prints an S-expression across multiple indented lines when it exceeds SEXP_WIDTH.
local function pretty_sexp(form, indent)
  indent = indent or ""
  local flat = sexp.print(form)
  if not sexp.is_list(form) or sexp.is_sym(form[1], "constant") or #flat + #indent <= SEXP_WIDTH or #form < 2 then
    return flat
  end
  local inner = indent .. "  "
  local first_line = "(" .. sexp.print(form[1])
  local start = 2
  if #form > 2 and not sexp.is_list(form[2]) then
    first_line = first_line .. " " .. sexp.print(form[2])
    start = 3
  end
  local parts = {first_line}
  for i = start, #form do
    parts[#parts + 1] = inner .. pretty_sexp(form[i], inner)
  end
  return table.concat(parts, "\n") .. ")"
end

-- Formats an S-expression with Factorio rich-text color tags for syntax highlighting.
local function highlight_token(form)
  if type(form) == "number" then
    return "[color=255,205,105]" .. sexp.print(form) .. "[/color]"
  end
  if sexp.is_str(form) then
    return '[color=165,235,150]"' .. form.str:gsub('[\\"]', "\\%0") .. '"[/color]'
  end
  if sexp.is_sym(form) then
    local c = FN_COLOR[form.sym]
    if c then return "[color=" .. c .. "][font=default-semibold]" .. form.sym .. "[/font][/color]" end
    return "[color=225,228,240]" .. form.sym .. "[/color]"
  end
  return sexp.print(form)
end

local function highlight_flat(form)
  if not sexp.is_list(form) then return highlight_token(form) end
  if sexp.is_sym(form[1], "constant") then
    local parts = {}
    for i = 2, #form do parts[#parts + 1] = highlight_flat(form[i]) end
    return "[color=140,145,160]{[/color]" .. table.concat(parts, " ") .. "[color=140,145,160]}[/color]"
  end
  local parts = {}
  for i = 1, #form do parts[i] = highlight_flat(form[i]) end
  return "[color=140,145,160]([/color]" .. table.concat(parts, " ") .. "[color=140,145,160])[/color]"
end

local function highlight_sexp(form, indent)
  indent = indent or ""
  local flat = sexp.print(form)
  if not sexp.is_list(form) or sexp.is_sym(form[1], "constant") or #flat + #indent <= SEXP_WIDTH or #form < 2 then
    return highlight_flat(form)
  end
  local inner = indent .. "  "
  local first_line = "[color=140,145,160]([/color]" .. highlight_flat(form[1])
  local start = 2
  if #form > 2 and not sexp.is_list(form[2]) then
    first_line = first_line .. " " .. highlight_flat(form[2])
    start = 3
  end
  local parts = {first_line}
  for i = start, #form do
    parts[#parts + 1] = inner .. highlight_sexp(form[i], inner)
  end
  return table.concat(parts, "\n") .. "[color=140,145,160])[/color]"
end

-- Per-player UI state: storage.formula_ui[player_index] = {
--   sheet = id of the sheet shown, collapsed = {["sheet id/def name"] = true},
--   pinned = boolean: the window stays open while other windows open and close,
--   location = where the window was last closed,
--   size = {width, height} of the window's content, or nil for the size setting's,
--   maximized = boolean: the window fills the screen; location and size are kept for later.
--     Nil until the window opens, which sets it from the size setting,
--   step = {sheet = id, name = def name, path = node path}: the selected step, shown above the
--     tree with the actions on it, or nil,
--   clipboard = a copied node,
--   hide_preview = boolean: hide group contents beside the definitions and below them,
--   narrow = boolean: the window is too narrow for contents beside the formulas,
--   editing = {sheet = id, def = name} or {sheet = id, prefix = true}: the name being edited,
--   item_edit = {sheet = id, def = name, path = node path, pair = index}: the constant signal being edited,
--   sexp_edit = {sheet = id, def = name}: the definition whose multi-line S-expression box is open for editing,
-- }
local function ui(player)
  storage.formula_ui = storage.formula_ui or {}
  local state = storage.formula_ui[player.index]
  if not state then
    state = {tab = 1, collapsed = {}}
    storage.formula_ui[player.index] = state
  end
  return state
end

-- The sheet shown to a player: the one they picked, else the force's first.
local function sheet_of(player)
  local state = ui(player)
  local sheet = program.sheet(player.force, state.sheet) or program.sheets(player.force)[1]
  state.sheet = sheet.id
  return sheet
end

local function collapse_key(sheet, name) return sheet.id .. "/" .. name end

-- The sheet build_tree is drawing; the node renderers below read it.
local rendering

local function copy(path)
  local out = {}
  for i, v in ipairs(path) do out[i] = v end
  return out
end

local function child(path, i)
  local out = copy(path)
  out[#out + 1] = i
  return out
end

local function deep_copy(form)
  if type(form) ~= "table" then return form end
  local out = {}
  for k, v in pairs(form) do out[k] = deep_copy(v) end
  return out
end

local function same_path(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function node_at(def, path)
  local form = def.expr
  for _, i in ipairs(path) do
    if type(form) ~= "table" then return nil end
    form = form[i]
  end
  return form
end

local function parent_of(def, path)
  local up = copy(path)
  local index = table.remove(up)
  return node_at(def, up), index
end

local function set_node(def, path, value)
  if #path == 0 then def.expr = value; return end
  local parent, index = parent_of(def, path)
  parent[index] = value
end

local function param_of(spec, i)
  local required = #spec.params
  if i <= required then return spec.params[i] end
  if spec.optional and spec.optional[i - required] then return spec.optional[i - required] end
  return spec.rest
end

local function max_args(spec)
  if spec.rest then return math.huge end
  return #spec.params + (spec.optional and #spec.optional or 0)
end

-- Whether the argument at path moves and can be removed: only arguments of functions that
-- take any number of them move; optional ones can be removed, and any of a function taking
-- any number of them while it has more than it needs.
local function arg_rules(def, path)
  if #path == 0 then return false, false end
  local parent, index = parent_of(def, path)
  local spec = sexp.is_sym(parent[1]) and lang.functions[parent[1].sym]
  if not spec then return false, true end
  local i, given = index - 1, #parent - 1
  return spec.rest ~= nil, i > #spec.params or (spec.rest ~= nil and given > #spec.params)
end

local function default_for(param)
  if param.default ~= nil then return param.default end
  if param.type == "number" then return 1 end
  if lang.choices[param.type] then return sexp.sym(lang.choices[param.type]()[1]) end
  if param.type == "recipe" then
    return sexp.sym(prototypes.recipe["iron-gear-wheel"] and "iron-gear-wheel" or next(prototypes.recipe))
  end
  if param.type == "filter" then return sexp.sym(prototypes.item["iron-plate"] and "iron-plate" or next(prototypes.item)) end
  return {sexp.sym("constant")}
end

local function is_expression(form)
  return type(form) == "number" or sexp.is_list(form)
end

-- Child index in `form` that holds the primary group/expression argument when unwrapping.
local function primary_arg_index(form)
  local fn = sexp.is_list(form) and sexp.is_sym(form[1]) and form[1].sym
  if fn == "multiply" then
    for i = 2, #form do
      if type(form[i]) ~= "number" then return i end
    end
  end
  return 2
end

local function can_unwrap_node(form)
  if not (sexp.is_list(form) and sexp.is_sym(form[1])) then return false end
  local spec = lang.functions[form[1].sym]
  if not spec or spec.special then return false end
  return is_expression(form[primary_arg_index(form)])
end

-- Replaces the function of the node at path, keeping the arguments that still fit. A leaf
-- (number, group, items, network) becomes the first argument of a non-source function.
local function set_function(def, path, name, force)
  local old, spec = node_at(def, path), lang.functions[name]
  if name == "network" then
    if sexp.is_sym(old and old[1], "network") then return end
    local choice = program.network_choices(force)[1]
    local new = {sexp.sym("network")}
    for _, arg in ipairs(choice and choice.args or {sexp.str("")}) do new[#new + 1] = arg end
    set_node(def, path, new)
    return
  elseif name == "group" then
    set_node(def, path, sexp.is_sym(old and old[1], "group") and old or {sexp.sym("group"), sexp.str("")})
    return
  elseif name == "constant" then
    set_node(def, path, sexp.is_sym(old and old[1], "constant") and old or {sexp.sym("constant")})
    return
  end
  local args = {}
  if type(old) == "number" or sexp.is_sym(old[1], "group") or sexp.is_sym(old[1], "constant")
      or sexp.is_sym(old[1], "network") then
    args = {old}
  else
    for i = 2, #old do args[#args + 1] = old[i] end
  end
  local new, next_arg = {sexp.sym(name)}, 1
  local function take(param)
    while next_arg <= #args do
      local arg = args[next_arg]
      next_arg = next_arg + 1
      local named = sexp.is_sym(arg) or sexp.is_str(arg)
      if param.type == "filter" and (named or sexp.is_list(arg)) then return arg end
      local choice = lang.is_name_param(param.type)
      if choice and named then return arg end
      if not choice and is_expression(arg) then return arg end
    end
  end
  for i = 1, #spec.params do new[#new + 1] = take(spec.params[i]) or default_for(spec.params[i]) end
  local limit = max_args(spec)
  while next_arg <= #args and #new - 1 < limit do
    local arg = take(param_of(spec, #new))
    if arg then new[#new + 1] = arg end
  end
  set_node(def, path, new)
end

local UNITS = {{1e9, "G"}, {1e6, "M"}, {1e3, "k"}}

-- Counts as typed in the game: 5k for 5000, 1.5M for 1500000, plain otherwise.
local function format_count(count)
  for _, unit in ipairs(UNITS) do
    local scaled = count / unit[1]
    if math.abs(scaled) >= 1 then
      if scaled == math.floor(scaled) then return string.format("%d%s", scaled, unit[2]) end
      if scaled * 10 == math.floor(scaled * 10) then return string.format("%.1f%s", scaled, unit[2]) end
      break
    end
  end
  if count == math.floor(count) then return string.format("%d", count) end
  return string.format("%.2f", count)
end

local SIGNAL_SPRITE = {
  item = "item", fluid = "fluid", virtual = "virtual-signal", entity = "entity", recipe = "recipe",
  ["space-location"] = "space-location", ["asteroid-chunk"] = "asteroid-chunk", quality = "quality",
}

local rich = docs.rich

local PROTOTYPES = {
  item = "item", fluid = "fluid", virtual = "virtual_signal", entity = "entity", recipe = "recipe",
  ["space-location"] = "space_location", ["asteroid-chunk"] = "asteroid_chunk", quality = "quality",
}

-- Filters in the game's own order: by item group, subgroup and order, then by quality.
local function sorted(filters)
  local keys = {}
  for _, filter in ipairs(filters) do
    local v = filter.value
    local signal_type = v.type or "item"
    local list = prototypes[PROTOTYPES[signal_type] or "item"]
    local proto = list and list[v.name]
    local quality = prototypes.quality[v.quality or "normal"]
    if proto then
      keys[filter] = string.format("%s|%s|%s|%s|%03d", proto.group and proto.group.order or "",
        proto.subgroup and proto.subgroup.order or "", proto.order, v.name, quality and quality.level or 0)
    else
      keys[filter] = "~" .. v.name
    end
  end
  table.sort(filters, function(a, b) return keys[a] < keys[b] end)
  return filters
end

-- " max 200, from [space-location=vulcanus] ..." for a filter's request settings.
local function settings_text(filter)
  local parts = {}
  if filter.max then parts[#parts + 1] = "max " .. filter.max end
  if filter.import_from then parts[#parts + 1] = "from [space-location=" .. filter.import_from .. "]" end
  if filter.request_from and filter.request_from ~= "planet" then parts[#parts + 1] = "request from " .. filter.request_from end
  if filter.minimum_delivery_count then parts[#parts + 1] = "min delivery " .. filter.minimum_delivery_count end
  if #parts == 0 then return "" end
  return "  [color=0.7,0.7,0.7](" .. table.concat(parts, ", ") .. ")[/color]"
end

-- Button caption and tooltip describing a node's value: its signal count, its number or
-- an error mark.
local function describe(value, err)
  if err then return "[color=red]![/color]", "[color=red]" .. err .. "[/color]" end
  if type(value) == "number" then return "=" .. format_count(value), "= " .. format_count(value) end
  local filters = sorted(lang.filters_from_bag(value))
  local lines = {#filters == 1 and "1 signal" or (#filters .. " signals")}
  for i, filter in ipairs(filters) do
    if i > TOOLTIP_LINES then
      lines[#lines + 1] = string.format("… %d more", #filters - TOOLTIP_LINES)
      break
    end
    local v = filter.value
    lines[#lines + 1] = rich(v.type, v.name, v.quality) .. " " .. filter.min .. settings_text(filter)
  end
  return tostring(#filters), table.concat(lines, "\n")
end

local function tags(action, def_index, path, extra)
  local t = {logf = action, def = def_index, path = path}
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

local function mini(parent, action, def_index, path, caption, tooltip, extra)
  local button = parent.add{type = "button", style = "mini_button", caption = caption, tooltip = tooltip,
    tags = tags(action, def_index, path, extra)}
  button.style.width = 24
  button.style.height = 24
  button.style.padding = 0
  return button
end

local SELECT_HINT = "\n[font=default-semibold]Click to inspect this expression[/font]"
local REMOVE_HINT = "\n[font=default-semibold]Right-click to remove it[/font]"

local function hint(removable) return SELECT_HINT .. (removable and REMOVE_HINT or "") end

-- Row-end controls for a node in the tree: signal count badge, wrap button, and unwrap/remove button.
local function row_end_controls(row, force, def_index, path, form, removable)
  local filler = row.add{type = "empty-widget"}
  filler.style.horizontally_stretchable = true
  filler.style.minimal_width = 8
  if #path > 0 then
    local caption, tooltip = describe(program.preview(force, rendering, form))
    local number = type(form) == "number"
    if number then caption = "#" end
    local button = row.add{type = "button", style = "mini_button", caption = caption, tooltip = tooltip .. hint(removable),
      tags = tags("result", def_index, path, {removable = removable, number = number or nil})}
    button.style.height = 24
    button.style.minimal_width = 24
    button.style.maximal_width = 80
    button.style.padding = {0, 4}
    button.mouse_button_filter = {"left", "right"}
  end
  local wrap_btn = row.add{type = "sprite-button", style = "mini_button_aligned_to_text_vertically_when_centered",
    sprite = "logf-wrap", tooltip = "Wrap this expression in a new function",
    tags = tags("wrap", def_index, path)}
  wrap_btn.style.width = 24
  wrap_btn.style.height = 24
  local unwrappable = can_unwrap_node(form)
  if unwrappable then
    local unw = row.add{type = "sprite-button", style = "mini_tool_button_red", sprite = "utility/trash",
      tooltip = "Unwrap this function (replace it with its input)", tags = tags("unwrap", def_index, path)}
    unw.style.width = 24
    unw.style.height = 24
  elseif removable then
    local rem = row.add{type = "sprite-button", style = "mini_tool_button_red", sprite = "utility/trash",
      tooltip = "Remove this argument", tags = tags("remove", def_index, path)}
    rem.style.width = 24
    rem.style.height = 24
  end
end

local NODE_WIDTH = 176

-- A node's row: stretched to the formula's width, so the counts and controls line up at the right.
local function node_row(column, depth, is_last, label)
  local row = column.add{type = "flow", direction = "horizontal"}
  row.style.vertical_align = "center"
  row.style.horizontally_stretchable = true
  row.style.horizontal_spacing = 6
  if depth > 0 then
    row.style.left_margin = (depth - 1) * INDENT
    local branch = row.add{type = "label", caption = is_last and "└─" or "├─"}
    branch.style.font_color = {0.48, 0.5, 0.55}
    branch.style.width = 20
  end
  if label and label ~= "" then
    local lbl = row.add{type = "label", caption = label .. ":"}
    lbl.style.font_color = {0.75, 0.75, 0.75}
  end
  return row
end

local function group_names(force)
  local names, seen = {}, {}
  for _, name in pairs(force.get_logistic_groups()) do
    -- Formula groups are left out: this sheet's are listed by definition name, and other
    -- sheets' cannot be read.
    if not seen[name] and not program.owner_of_group(force, name) then seen[name] = true; names[#names + 1] = name end
  end
  for _, def in ipairs(rendering.defs) do
    if not seen[def.name] then seen[def.name] = true; names[#names + 1] = def.name end
  end
  table.sort(names)
  return names
end

-- Dropdown caption of a name chosen for a parameter.
local function choice_caption(param_type, name)
  if param_type == "quality" then return "[quality=" .. name .. "] " .. name end
  if param_type == "space-location" and name ~= lang.ANYWHERE then return "[space-location=" .. name .. "] " .. name end
  return name
end

local render_tree

-- A network form's selector arguments and its member.
function network_parts(form)
  if type(form[3]) == "number" then
    return {form[2], form[3], form[4]}, form[5] and (form[5].sym or form[5].str) or "all"
  end
  return {form[2]}, form[3] and (form[3].sym or form[3].str) or "all"
end

local function function_item(fn) return "[img=logf-fn-" .. fn .. "] " .. fn end

local function function_dropdown(row, def_index, path, name)
  local index = 0
  local items = {}
  for i, fn in ipairs(lang.order) do
    items[i] = function_item(fn)
    if fn == name then index = i end
  end
  local dropdown = row.add{type = "drop-down", items = items, selected_index = index,
    tooltip = docs.tooltip(name),
    tags = tags("function", def_index, path)}
  dropdown.style.width = NODE_WIDTH
  return dropdown
end

-- Group name parameter picker for `(group "name")`.
local function group_picker(row, force, def_index, path, form)
  local current = form[2] and (form[2].str or form[2].sym) or ""
  local names, selected = group_names(force), 0
  for i, n in ipairs(names) do if n == current then selected = i end end
  if selected == 0 and current ~= "" then
    names[#names + 1] = current
    selected = #names
  end
  local dropdown = row.add{type = "drop-down", items = names, selected_index = selected,
    tooltip = "Logistic group to read",
    tags = tags("group-name", def_index, path, {names = names})}
  dropdown.style.width = NODE_WIDTH
end

-- The constant signal being edited in the tree: {sheet = id, def = name, path = node path,
-- pair = index of its signal in the form}, from the player's UI state. `focus_item` is set
-- when the editor has just opened; `item_row` is the row drawn for it.
local editing_item, focus_item, item_row

local SLOT_COLUMNS = 8

-- The row under a constant's slots that edits one signal: its signal and its count.
local function render_item_editor(column, def_index, path, form, i, left_margin)
  local row = column.add{type = "flow", direction = "horizontal", tags = {logf = "item-editor"}}
  item_row = row
  row.style.vertical_align = "center"
  if left_margin and left_margin > 0 then row.style.left_margin = left_margin end
  row.style.top_margin = 2
  local token = form[i] and (form[i].str or form[i].sym)
  local ok, type_, name, quality = pcall(lang.parse_signal, token or "")
  local signal = row.add{type = "choose-elem-button", elem_type = "signal", tooltip = "Change the signal; clear it to remove",
    tags = tags("item-signal", def_index, path, {pair = i})}
  if ok then signal.elem_value = {type = type_, name = name, quality = quality} end
  local count = form[i + 1]
  if type(count) == "number" then
    local field = row.add{type = "textfield", text = format_count(count), tooltip = NUMBER_TOOLTIP .. "\nEnter applies.",
      tags = tags("item-count", def_index, path, {pair = i})}
    field.style.width = 90
    -- Only when the editor opens; later redraws leave the cursor where the player put it.
    if focus_item then
      field.focus()
      field.select_all()
    end
  else
    row.add{type = "label", caption = sexp.print(count), tooltip = "Edit in the text view"}
  end
  row.add{type = "sprite-button", style = "tool_button", sprite = "utility/check_mark",
    tooltip = "Done", tags = tags("item-done", def_index, path)}
  row.add{type = "sprite-button", style = "tool_button_red", sprite = "utility/trash",
    tooltip = "Remove the signal", tags = tags("item-remove", def_index, path, {pair = i})}
end

-- A constant's signals as slots with their counts, as on a constant combinator. Clicking a
-- slot edits it below; right-clicking removes it.
local function render_items(parent_slot_container, editor_column, def_index, path, form, columns, editor_margin)
  local grid = parent_slot_container.add{type = "table", style = "filter_slot_table", column_count = columns or SLOT_COLUMNS}
  local def = rendering.defs[def_index]
  local edited = editing_item and editing_item.sheet == rendering.id and def and editing_item.def == def.name
    and same_path(editing_item.path, path) and editing_item.pair or nil
  for i = 2, #form, 2 do
    local token = form[i] and (form[i].str or form[i].sym)
    local ok, type_, name, quality = pcall(lang.parse_signal, token or "")
    local count = form[i + 1]
    local known = ok and prototypes[PROTOTYPES[type_] or "item"][name]
    local slot = grid.add{type = "sprite-button", style = "slot_button",
      sprite = known and ((SIGNAL_SPRITE[type_] or "item") .. "/" .. name) or "utility/questionmark",
      number = type(count) == "number" and count or nil, toggled = edited == i,
      tooltip = (known and rich(type_, name, quality) or ("Unknown signal " .. tostring(token)))
        .. " " .. (type(count) == "number" and format_count(count) or sexp.print(count))
        .. "\nClick to edit, right-click to remove",
      tags = tags("item-slot", def_index, path, {pair = i})}
    -- Buttons report left clicks only unless told otherwise.
    slot.mouse_button_filter = {"left", "right"}
    if known and quality and quality ~= "normal" then slot.quality = quality end
  end
  grid.add{type = "choose-elem-button", style = "slot_button", elem_type = "signal", tooltip = "Add a signal",
    tags = tags("item-add", def_index, path)}
  if edited and form[edited] ~= nil then
    render_item_editor(editor_column, def_index, path, form, edited, editor_margin or 0)
  end
  return grid
end

-- Recipes, choices and plain numbers sit on their function's row, after its name, so a
-- step reads as one line: "quality-up  steps: [2]".
local function inline_param(param, arg)
  return param.type == "recipe" or lang.choices[param.type] ~= nil
    or (param.type == "filter" and (arg == nil or sexp.is_sym(arg) or sexp.is_str(arg)))
    or (param.type == "number" and (arg == nil or type(arg) == "number"))
end

-- An argument on its function's row. An optional number not given shows its default.
local function render_inline(row, def_index, path, form, param)
  local name = sexp.is_sym(form) and form.sym or (sexp.is_str(form) and form.str) or nil
  if param.type == "filter" then
    local token = name or ""
    local ok, signal_type, signal_name, quality = pcall(lang.parse_signal, token)
    local picker = row.add{type = "choose-elem-button", elem_type = "signal", tags = tags("filter-pick", def_index, path),
      tooltip = (ok and rich(signal_type, signal_name, token:find(":") and quality or nil) .. " " .. token
        or "Unknown signal " .. token) .. "\nAny quality unless one is chosen. Clear it to remove."}
    if ok then picker.elem_value = {type = signal_type, name = signal_name, quality = token:find(":") and quality or nil} end
  elseif param.type == "recipe" then
    local picker = row.add{type = "choose-elem-button", elem_type = "recipe", tags = tags("recipe-pick", def_index, path)}
    if name and prototypes.recipe[name] then picker.elem_value = name
    else row.add{type = "label", caption = "[color=red]unknown recipe " .. tostring(name) .. "[/color]"} end
  elseif lang.choices[param.type] then
    local names, selected = lang.choices[param.type](), 0
    for i, n in ipairs(names) do if n == (name or "") then selected = i end end
    local items = {}
    for i, n in ipairs(names) do items[i] = choice_caption(param.type, n) end
    row.add{type = "drop-down", items = items, selected_index = selected, tags = tags("choice", def_index, path, {names = names})}
  else
    local label = row.add{type = "label", caption = param.name .. ":"}
    label.style.left_margin = 4
    label.style.font_color = {0.75, 0.75, 0.75}
    local tooltip = NUMBER_TOOLTIP
    if form == nil then tooltip = tooltip .. "\nOptional; " .. format_count(param.default) .. " when not given." end
    local field = row.add{type = "textfield", text = format_count(form or param.default), tooltip = tooltip,
      tags = tags("number", def_index, path)}
    field.style.width = 64
  end
end

local function render_network_controls(row, force, def_index, path, form)
  local args, member = network_parts(form)
  local current = sexp.print({sexp.sym("network"), table.unpack(args)})
  local labels, selected = {}, 0
  for i, choice in ipairs(program.network_choices(force)) do
    labels[i] = choice.label
    if sexp.print({sexp.sym("network"), table.unpack(choice.args)}) == current then selected = i end
  end
  if selected == 0 then
    labels[#labels + 1] = "[color=red]" .. current .. "[/color]"
    selected = #labels
  end
  local pick = row.add{type = "drop-down", items = labels, selected_index = selected, tags = tags("network-pick", def_index, path)}
  pick.style.width = 200
  local members, which = {}, 1
  for i, m in ipairs(lang.members) do
    members[i] = m
    if m == member then which = i end
  end
  row.add{type = "drop-down", items = members, selected_index = which, tags = tags("network-member", def_index, path)}
end

-- Renders an S-expression node and its indented children in `column`.
function render_tree(column, force, def_index, path, form, depth, label, is_last, removable)
  if type(form) == "number" then
    local row = node_row(column, depth, is_last, label)
    local field = row.add{type = "textfield", text = format_count(form), tooltip = NUMBER_TOOLTIP,
      tags = tags("number", def_index, path)}
    field.style.width = 80
    row_end_controls(row, force, def_index, path, form, removable)
    return
  end
  if not sexp.is_list(form) then
    local row = node_row(column, depth, is_last, label)
    row.add{type = "label", caption = "[color=red]" .. sexp.print(form) .. "[/color]", tooltip = "Edit in the S-expression box"}
    row_end_controls(row, force, def_index, path, form, true)
    return
  end

  local head = form[1]
  local name = sexp.is_sym(head) and head.sym or "?"
  local spec = lang.functions[name]
  local row = node_row(column, depth, is_last, label)
  function_dropdown(row, def_index, path, name)
  if spec then mini(row, "fn-help", def_index, path, "?", "Open the reference for " .. name .. " in Factoriopedia", {fn = name}) end

  if name == "group" then
    group_picker(row, force, def_index, path, form)
    row_end_controls(row, force, def_index, path, form, removable)
    return
  elseif name == "network" then
    render_network_controls(row, force, def_index, path, form)
    row_end_controls(row, force, def_index, path, form, removable)
    return
  elseif name == "constant" then
    render_items(row, column, def_index, path, form, SLOT_COLUMNS, depth * INDENT)
    row_end_controls(row, force, def_index, path, form, removable)
    return
  end

  local given = #form - 1
  local nested = {}

  if spec and not spec.special then
    for i = 1, math.max(given, #spec.params + (spec.optional and #spec.optional or 0)) do
      local param = param_of(spec, i) or {name = "extra", type = "value"}
      if inline_param(param, form[i + 1]) then
        render_inline(row, def_index, child(path, i + 1), form[i + 1], param)
      elseif i <= given then
        local name_shown = i > 1 and param ~= param_of(spec, 1) and param.name or nil
        nested[#nested + 1] = {child_idx = i + 1, param = param, label = name_shown}
      end
    end
    if spec.rest and spec.rest.type == "filter" then
      row.add{type = "choose-elem-button", elem_type = "signal", tooltip = "Add a signal",
        tags = tags("filter-add", def_index, path)}
    end
  end

  row_end_controls(row, force, def_index, path, form, removable)

  if not spec or spec.special then return end
  local next_param = given < max_args(spec) and param_of(spec, given + 1)
  if next_param and inline_param(next_param, nil) then next_param = nil end
  if #nested == 0 and not next_param then return end

  local def = rendering.defs[def_index]
  for idx, arg in ipairs(nested) do
    local at = child(path, arg.child_idx)
    local _, can_remove = arg_rules(def, at)
    local last_child = idx == #nested and not next_param
    render_tree(column, force, def_index, at, form[arg.child_idx], depth + 1, arg.label, last_child, can_remove)
  end
  if next_param then
    local add_row = node_row(column, depth + 1, true, nil)
    local add = add_row.add{type = "button", caption = "+ " .. next_param.name,
      tooltip = given < #spec.params and "Required argument" or "Optional argument", tags = tags("add-arg", def_index, path)}
    add.style.height = 24
    add.style.padding = {0, 8}
  end
end

-- A definition's formula as highlighted text, or the text box editing it.
local function render_sexp_panel(column, player, def_index, def)
  local state = ui(player)
  local open = state.sexp_edit and state.sexp_edit.sheet == rendering.id and state.sexp_edit.def == def.name
  local box_frame = column.add{type = "frame", style = "deep_frame_in_shallow_frame", direction = "vertical"}
  box_frame.style.horizontally_stretchable = true
  box_frame.style.top_margin = 4
  box_frame.style.padding = 6
  if open then
    local text = pretty_sexp(def.expr)
    local lines = 1
    for _ in text:gmatch("\n") do lines = lines + 1 end
    local box = box_frame.add{type = "text-box", name = "sexp_box", text = text,
      tags = tags("def-sexp", def_index, {})}
    box.word_wrap = false
    box.style.horizontally_stretchable = true
    box.style.minimal_width = 420
    box.style.height = math.max(72, math.min(220, (lines + 1) * 22))
    if state.sexp_focus then
      box.focus()
      state.sexp_focus = nil
    end
    local bar = box_frame.add{type = "flow", name = "sexp_bar", direction = "horizontal"}
    bar.style.vertical_align = "center"
    bar.style.top_margin = 4
    bar.style.horizontal_spacing = 6
    local apply = bar.add{type = "button", style = "confirm_button_without_tooltip", caption = "Apply",
      tags = tags("sexp-apply", def_index, {})}
    apply.style.height = 26
    local cancel = bar.add{type = "button", caption = "Cancel", tags = tags("sexp-cancel", def_index, {})}
    cancel.style.height = 26
    local err = bar.add{type = "label", name = "message"}
    err.style.font_color = {1, 0.4, 0.4}
  else
    local row = box_frame.add{type = "flow", direction = "horizontal"}
    row.style.vertical_align = "top"
    row.style.horizontally_stretchable = true
    local code = row.add{type = "label", caption = highlight_sexp(def.expr),
      tooltip = "S-expression for this formula. Click Edit to modify as multi-line text.",
      tags = tags("sexp-open", def_index, {})}
    code.style.single_line = false
    local filler = row.add{type = "empty-widget"}
    filler.style.horizontally_stretchable = true
    local edit_btn = row.add{type = "sprite-button", style = "mini_button_aligned_to_text_vertically_when_centered",
      sprite = "utility/rename_icon", tooltip = "Edit S-expression",
      tags = tags("sexp-open", def_index, {})}
    edit_btn.style.width = 24
    edit_btn.style.height = 24
  end
end

local function render_def(list, force, player, i, def)
  local status = rendering.status[i] or {signals = 0}
  local collapsed = ui(player).collapsed[collapse_key(rendering, def.name)]
  local frame = list.add{type = "frame", style = "deep_frame_in_shallow_frame", direction = "vertical",
    tags = {logf = "def-frame", name = def.name}}
  frame.style.horizontally_stretchable = true
  frame.style.padding = 6
  local head = frame.add{type = "flow", name = "head", direction = "horizontal"}
  head.style.vertical_align = "center"
  head.add{type = "sprite-button", style = "frame_action_button",
    sprite = collapsed and "utility/expand" or "utility/collapse", tags = tags("toggle", i, {})}
  local editing = ui(player).editing
  editable_label(head, editing and editing.sheet == rendering.id and editing.def == def.name, def.name, def.name,
    "rename", "Group name", {def = i, sheet = rendering.id}, 220)
  local caption, tooltip
  if status.error then caption, tooltip = "[color=red]error[/color]", status.error
  elseif status.signals == 0 then caption = "[color=0.6,0.6,0.6]empty[/color]"
  else caption, tooltip = status.signals == 1 and "1 signal" or (status.signals .. " signals"), nil end
  -- The definition's count selects the whole formula, as a step's count selects that step.
  local count = head.add{type = "button", style = "mini_button", caption = caption,
    tooltip = (tooltip and tooltip .. "\n" or "") .. SELECT_HINT:sub(2), tags = tags("result", i, {}, {root = true})}
  count.style.height = 24
  count.style.minimal_width = 56
  count.style.maximal_width = 120
  count.style.padding = {0, 6}
  count.style.left_margin = 8
  if status.error then
    local err = head.add{type = "label", caption = status.error}
    err.style.font_color = {1, 0.4, 0.4}
    err.style.maximal_width = 360
  end
  local state = ui(player)
  -- A collapsed definition is its header alone, with its contents in one row of slots.
  if collapsed then
    local value = head.add{type = "flow", direction = "horizontal", tags = {logf = "def-value", name = def.name, inline = true}}
    value.style.left_margin = 12
    value.style.vertical_align = "center"
    value.visible = not state.hide_preview
  end
  local filler = head.add{type = "empty-widget"}
  filler.style.horizontally_stretchable = true
  local dup = head.add{type = "sprite-button", style = "mini_button_aligned_to_text_vertically_when_centered",
    sprite = "utility/copy", tooltip = "Duplicate definition", tags = tags("def-duplicate", i, {})}
  dup.style.width = 24
  dup.style.height = 24
  dup.style.right_margin = 4
  mini(head, "def-up", i, {}, "↑", "Move definition up")
  mini(head, "def-down", i, {}, "↓", "Move definition down")
  local remove = head.add{type = "sprite-button", name = "delete", style = "mini_tool_button_red", sprite = "utility/trash",
    tooltip = DEF_DELETE_TOOLTIP, tags = tags("def-delete", i, {})}
  remove.style.width = 24
  remove.style.height = 24
  remove.style.left_margin = 8
  if collapsed then return end

  -- The contents column has a fixed width, so the formulas of all definitions line up.
  local row = frame.add{type = "flow", direction = state.narrow and "vertical" or "horizontal"}
  row.style.top_margin = 4
  row.style.horizontally_stretchable = true
  if state.narrow then row.style.vertical_spacing = 6 else row.style.horizontal_spacing = 16 end

  if not state.narrow then
    local value = row.add{type = "flow", direction = "vertical", tags = {logf = "def-value", name = def.name}}
    value.style.width = VALUE_WIDTH
    value.style.left_margin = 8
    value.visible = not state.hide_preview
  end

  local body = row.add{type = "flow", direction = "vertical"}
  body.style.left_margin = 8
  body.style.vertical_spacing = 4
  body.style.horizontally_stretchable = true
  render_tree(body, force, i, {}, def.expr, 0, nil, true, false)
  render_sexp_panel(body, player, i, def)

  if state.narrow then
    local value = row.add{type = "flow", direction = "vertical", tags = {logf = "def-value", name = def.name}}
    value.style.width = VALUE_WIDTH
    value.style.left_margin = 8
    value.visible = not state.hide_preview
  end
end

local function build_tree(pane, player)
  pane.clear()
  local force = player.force
  rendering = sheet_of(player)
  local state = ui(player)
  editing_item, focus_item, item_row = state.item_edit, state.item_focus, nil
  state.item_focus = nil
  for i, def in ipairs(rendering.defs) do render_def(pane, force, player, i, def) end
  local add = pane.add{type = "button", caption = "+ New group", tags = tags("def-new", 0, {})}
  add.style.top_margin = 4
  -- Groups no formula computes, filled by refresh_preview.
  local others = pane.add{type = "flow", name = "others", direction = "vertical"}
  others.style.top_margin = 12
  others.style.vertical_spacing = 8
  others.visible = not state.hide_preview
  sync_opened(player, item_row)
end

local function window(player)
  return player.gui.screen[WINDOW]
end

-- The editor of the selected sheet tab.
local function editor_of(player)
  local w = window(player)
  if not w then return nil end
  local pane = w.children[2].pane
  local tab = pane.tabs[pane.selected_tab_index]
  return tab and tab.content.editor
end

local TEXT_WINDOW = "logf_text"

local function text_window(player)
  return player.gui.screen[TEXT_WINDOW]
end

-- Sizes of the size setting, one Larger click apart. A maximized window restores to large.
local SIZES = {
  small = {width = 1040, height = 620},
  medium = {width = 1196, height = 713},
  large = {width = 1375, height = 819},
}
local MIN_SIZE = {width = 560, height = 360}
-- Below this width, a definition's contents go under its formula instead of beside it.
local NARROW = 900
-- Room the window takes around its content: borders, title bar and tabs. A maximized
-- window's content is the screen less this.
local CHROME = {width = 28, height = 104}

-- Sizes the window's content from the player's chosen size, kept inside the screen, or
-- to the whole screen when maximized.
local function size_setting(player)
  return player.mod_settings["logf-window-size"].value
end

local function chosen_size(player)
  return ui(player).size or SIZES[size_setting(player)] or SIZES.large
end

function apply_size(player)
  local w = window(player)
  if not w then return end
  local state = ui(player)
  local size = chosen_size(player)
  local scale = player.display_scale
  local screen_w = math.floor(player.display_resolution.width / scale)
  local screen_h = math.floor(player.display_resolution.height / scale)
  local width = math.max(MIN_SIZE.width, math.min(size.width, screen_w - 60))
  local height = math.max(MIN_SIZE.height, math.min(size.height, screen_h - 140))
  if state.maximized then
    width, height = screen_w - CHROME.width, screen_h - CHROME.height
    w.location = {0, 0}
  end
  local editor = editor_of(player)
  editor.style.width = width
  editor.style.height = height
  local narrow = width < NARROW
  if narrow ~= (state.narrow or false) then
    state.narrow = narrow
    build_tree(editor.scroll.tree, player)
  end
  fgui.refresh_preview(player)
end

function fgui.toggle(player)
  if window(player) then fgui.close(player) else fgui.open(player) end
end

local function destroy_window(player)
  local w = window(player)
  if w then
    if not ui(player).maximized then ui(player).location = w.location end
    w.destroy()
  end
end

function fgui.close(player)
  ui(player).editing = nil
  ui(player).sexp_edit = nil
  destroy_window(player)
  if text_window(player) then text_window(player).destroy() end
  player.set_shortcut_toggled("logf-formulas", false)
end

-- The button in the top-left corner button row, shared with other mods.
function fgui.ensure_button(player)
  local flow = mod_gui.get_button_flow(player)
  if flow.logf_toggle then return end
  flow.add{type = "sprite-button", name = "logf_toggle", style = mod_gui.button_style, sprite = "logf-formulas",
    tooltip = {"logf-ui.toggle-tooltip"}, tags = {logf = "toggle-window"}}
end

-- A sheet's tab caption: its prefix, which may be an icon.
function sheet_caption(sheet)
  if sheet.prefix:match("^%s*$") then return "(no prefix)" end
  return sheet.prefix
end

-- Actions on the selected step, in the order shown.
local ACTIONS = {
  {name = "wrap", sprite = "logf-wrap", tooltip = "Wrap in a new function, with this as its first argument"},
  {name = "unwrap", caption = "Unwrap", tooltip = "Replace this function with its first argument"},
  {name = "up", caption = "↑", tooltip = "Move argument up", gap = true},
  {name = "down", caption = "↓", tooltip = "Move argument down"},
  {name = "cut", caption = "Cut", tooltip = "Copy this node and remove it", gap = true},
  {name = "copy", caption = "Copy", tooltip = "Copy this node, to paste over another"},
  {name = "paste", caption = "Paste", tooltip = "Replace this node with the copied one"},
  {name = "remove", sprite = "utility/trash", style = "tool_button_red", tooltip = "Remove (right-click on the count)", gap = true},
}

-- Points the actions at the selected step, each enabled when it applies there.
local function update_actions(actions, state, def_index, def, path)
  local form = node_at(def, path)
  local movable, removable = arg_rules(def, path)
  local parent, index = nil, nil
  if #path > 0 then parent, index = parent_of(def, path) end
  local enabled = {
    wrap = true,
    unwrap = can_unwrap_node(form),
    up = movable and index > 2,
    down = movable and index < #parent,
    cut = removable,
    copy = true,
    paste = state.clipboard ~= nil,
    remove = removable,
  }
  for _, button in pairs(actions.children) do
    local name = button.tags.logf
    button.tags = tags(name, def_index, path)
    button.enabled = enabled[name] and true or false
  end
end

-- Fills a sheet tab: the bar, the step section and the tree.
function build_editor(content, player, sheet)
  local state = ui(player)
  local editor = content.add{type = "flow", name = "editor", direction = "vertical"}
  editor.style.vertical_spacing = 0
  local bar = editor.add{type = "frame", name = "bar", style = "subheader_frame"}
  bar.style.horizontally_stretchable = true
  bar.add{type = "checkbox", name = "show_preview", state = not state.hide_preview, caption = "Contents",
    tooltip = "Show what each group holds right now: beside its definition, and below them the groups no formula computes.\nClick a node's signal count in the tree to see that expression alone.",
    tags = {logf = "show-preview"}}
  bar.add{type = "sprite-button", style = "tool_button", sprite = "utility/collapse", tooltip = "Collapse all",
    tags = {logf = "collapse-all"}}
  bar.add{type = "sprite-button", style = "tool_button", sprite = "utility/expand", tooltip = "Expand all",
    tags = {logf = "expand-all"}}
  bar.add{type = "sprite", sprite = "utility/search", tooltip = "Search group names"}
  local search = bar.add{type = "textfield", name = "search", text = state.search or "",
    tooltip = {"logf-ui.search-tooltip"},
    tags = {logf = "search"}}
  search.style.width = 110
  local gap = bar.add{type = "empty-widget"}
  gap.style.horizontally_stretchable = true
  local prefix_tooltip = "Put in front of the name of every group this sheet computes.\n"
    .. "Rich text such as [virtual-signal=signal-F] shows as an icon. Groups still in use under the old prefix keep their last contents."
  bar.add{type = "label", caption = "Prefix", tooltip = prefix_tooltip}
  local editing = state.editing
  editable_label(bar, editing and editing.sheet == sheet.id and editing.prefix, sheet.prefix, sheet_caption(sheet),
    "prefix", prefix_tooltip, {sheet = sheet.id}, 140)
  bar.add{type = "label", name = "prefix_example", caption = "→ " .. sheet.prefix .. "mall",
    tooltip = "How a group named \"mall\" is called in the game"}
  bar.add{type = "button", caption = "Edit as text", tooltip = "Edit this sheet as S-expressions, for bulk edits and sharing",
    tags = {logf = "text-open"}}
  bar.add{type = "button", caption = "?",
    tooltip = "Open the Logistic formulas guide in Factoriopedia",
    tags = {logf = "factoriopedia"}}
  local only = #program.sheets(player.force) == 1
  -- Kept apart from the buttons used often.
  local delete = bar.add{type = "sprite-button", name = "delete", style = "tool_button_red", sprite = "utility/trash",
    tooltip = sheet_delete_tooltip(only),
    enabled = not only, tags = {logf = "sheet-delete"}}
  delete.style.left_margin = 12
  -- The selected step: its contents and the actions on it. Their tags name the step.
  local step = editor.add{type = "frame", name = "step", style = "subheader_frame", direction = "vertical",
    tags = {logf = "selection"}}
  step.style.horizontally_stretchable = true
  step.style.padding = 6
  step.visible = false
  local head = step.add{type = "flow", name = "head", direction = "horizontal"}
  head.style.vertical_align = "center"
  head.add{type = "label", name = "title", style = "caption_label"}
  local actions = head.add{type = "flow", name = "actions", direction = "horizontal"}
  actions.style.left_margin = 16
  actions.style.horizontal_spacing = 4
  for _, action in ipairs(ACTIONS) do
    local button
    if action.sprite then
      button = actions.add{type = "sprite-button", style = action.style or "tool_button", sprite = action.sprite,
        tooltip = action.tooltip, tags = {logf = action.name}}
    else
      button = actions.add{type = "button", caption = action.caption, tooltip = action.tooltip, tags = {logf = action.name}}
      button.style.height = 28
      button.style.minimal_width = 0
      button.style.padding = {0, 8}
    end
    if action.gap then button.style.left_margin = 12 end
  end
  local filler = head.add{type = "empty-widget"}
  filler.style.horizontally_stretchable = true
  head.add{type = "sprite-button", style = "mini_tool_button_red", sprite = "utility/close", tooltip = "Clear the selection (Escape)",
    tags = {logf = "step-close"}}
  local info = step.add{type = "label", name = "info"}
  info.style.single_line = false
  step.add{type = "flow", name = "slots", direction = "vertical"}
  local scroll = editor.add{type = "scroll-pane", name = "scroll", direction = "vertical"}
  scroll.style.padding = 8
  scroll.style.horizontally_stretchable = true
  scroll.style.vertically_stretchable = true
  local tree = scroll.add{type = "flow", name = "tree", direction = "vertical"}
  tree.style.vertical_spacing = 6
  tree.style.horizontally_stretchable = true
  build_tree(tree, player)
end

-- The text editor for a sheet, as a separate window.
function fgui.open_text(player)
  if text_window(player) then text_window(player).destroy() end
  local sheet = sheet_of(player)
  local w = player.gui.screen.add{type = "frame", name = TEXT_WINDOW, direction = "vertical", tags = {sheet = sheet.id}}
  w.auto_center = true
  local titlebar = w.add{type = "flow", direction = "horizontal"}
  titlebar.drag_target = w
  titlebar.add{type = "label", style = "frame_title", caption = "Sheet " .. sheet_caption(sheet) .. " as text",
    ignored_by_interaction = true}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  titlebar.add{type = "sprite-button", style = "close_button", sprite = "utility/close", tags = {logf = "text-close"}}
  local text = w.add{type = "frame", name = "text_view", style = "inside_shallow_frame_with_padding", direction = "vertical"}
  local box = text.add{type = "text-box", name = "box", text = program.text(sheet)}
  box.word_wrap = false
  box.style.width = 720
  box.style.height = 480
  local actions = text.add{type = "flow", name = "bar", direction = "horizontal"}
  actions.style.vertical_align = "center"
  actions.add{type = "button", name = "apply", style = "confirm_button_without_tooltip", caption = "Apply", tags = {logf = "apply"}}
  actions.add{type = "button", caption = "Revert", tooltip = "Discard edits and show the current sheet", tags = {logf = "revert"}}
  local message = actions.add{type = "label", name = "message"}
  message.style.maximal_width = 520
  message.style.single_line = false
  -- The text window becomes the opened GUI, so Escape closes it and not the main window.
  local state = ui(player)
  state.switching = true
  player.opened = w
  state.switching = nil
end

-- Elements of this mod that can be the opened GUI.
local function is_ours(element)
  return element.name == WINDOW or element.name == TEXT_WINDOW or element.tags.logf == "item-editor"
    or element.tags.logf == "selection"
end

-- Whether the player's opened GUI is one of this mod's, or none.
local function opened_is_ours(player)
  local opened = player.opened
  if player.opened_gui_type == defines.gui_type.none or opened == nil then return true end
  if player.opened_gui_type ~= defines.gui_type.custom then return false end
  -- A destroyed element of ours, such as the text window just closed.
  if not opened.valid then return true end
  return is_ours(opened)
end

-- Hands the opened GUI to a constant's signal editor or the selection, so Escape closes
-- them first, or back to an unpinned main window. The text window and other mods' or the
-- game's windows keep it.
function sync_opened(player, row)
  if text_window(player) or not opened_is_ours(player) then return end
  local state, main = ui(player), window(player)
  local editor = main and editor_of(player)
  local selection = editor and editor.step.visible and editor.step or nil
  local target = row or selection or (main and not state.pinned and main) or nil
  if target and player.opened ~= target then
    state.switching = true
    player.opened = target
    state.switching = nil
  end
end

-- The open signal editor row in a player's tree, if any.
local function item_row_of(player)
  local main = window(player)
  local editor = main and editor_of(player)
  local function walk(element)
    if element.tags.logf == "item-editor" then return element end
    for _, c in pairs(element.children) do
      local found = walk(c)
      if found then return found end
    end
  end
  return editor and walk(editor.scroll.tree)
end

-- Closes the text window and hands the opened GUI back to the editor.
local function close_text(player)
  local w = text_window(player)
  if w then w.destroy() end
  sync_opened(player, item_row_of(player))
end

-- A name shown as text with an edit button, as the game shows platform and station names.
-- While editing, a text field with the game's icon picker takes its place; Enter or the
-- edit button applies it. `action` tags the text field, `extra` goes on both widgets.
function editable_label(parent, editing, text, display, action, tooltip, extra, width)
  editing = editing and true or false
  local row = parent.add{type = "flow", name = action .. "_row", direction = "horizontal"}
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 4
  if editing then
    local field = row.add{type = "textfield", name = "field", text = text, icon_selector = true, tooltip = tooltip,
      tags = tags(action, extra.def, {}, extra)}
    field.style.width = width
    field.focus()
    field.select_all()
  else
    local label = row.add{type = "label", name = "label", caption = display, tooltip = tooltip, style = "caption_label"}
    label.style.maximal_width = width
  end
  local edit = row.add{type = "sprite-button", name = "edit", style = "mini_button_aligned_to_text_vertically_when_centered",
    sprite = "utility/rename_icon", tooltip = editing and "Apply" or "Edit label",
    tags = tags("label-edit", extra.def, {}, {field = action, sheet = extra.sheet})}
  edit.toggled = editing
  return row
end

local function pin_sprite(pinned)
  return pinned and "logf-pin-black" or "logf-pin-white"
end

function fgui.open(player)
  destroy_window(player)
  local state = ui(player)
  state.item_edit = nil
  if state.maximized == nil then state.maximized = size_setting(player) == "maximized" end
  local w = player.gui.screen.add{type = "frame", name = WINDOW, direction = "vertical"}
  if state.location then w.location = state.location else w.auto_center = true end
  local titlebar = w.add{type = "flow", direction = "horizontal"}
  -- A maximized window stays in place.
  if not state.maximized then titlebar.drag_target = w end
  titlebar.add{type = "label", style = "frame_title", caption = "Logistic formulas", ignored_by_interaction = true}
  local drag = titlebar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  titlebar.add{type = "sprite-button", style = "frame_action_button", sprite = "logf-smaller-white",
    hovered_sprite = "logf-smaller-black", clicked_sprite = "logf-smaller-black", tooltip = "Smaller", tags = {logf = "smaller"},
    enabled = not state.maximized}
  titlebar.add{type = "sprite-button", style = "frame_action_button", sprite = "logf-larger-white",
    hovered_sprite = "logf-larger-black", clicked_sprite = "logf-larger-black", tooltip = "Larger", tags = {logf = "larger"},
    enabled = not state.maximized}
  titlebar.add{type = "sprite-button", name = "maximize", style = "frame_action_button",
    sprite = state.maximized and "logf-maximize-black" or "logf-maximize-white", hovered_sprite = "logf-maximize-black",
    clicked_sprite = "logf-maximize-black", toggled = state.maximized or false,
    tooltip = state.maximized and "Restore the window's size" or "Fill the screen", tags = {logf = "maximize"}}
  titlebar.add{type = "sprite-button", name = "pin", style = "frame_action_button", sprite = pin_sprite(state.pinned),
    hovered_sprite = "logf-pin-black", clicked_sprite = "logf-pin-black", toggled = state.pinned or false,
    tooltip = "Keep open while using other windows", tags = {logf = "pin"}}
  titlebar.add{type = "sprite-button", style = "close_button", sprite = "utility/close", tags = {logf = "close"}}

  local inner = w.add{type = "frame", style = "inside_deep_frame", direction = "vertical"}
  local tabs = inner.add{type = "tabbed-pane", name = "pane", tags = {logf = "tabs"}}
  -- One tab per sheet, captioned by its prefix, and a last tab that adds a sheet.
  local current, selected = sheet_of(player), 1
  for i, sheet in ipairs(program.sheets(player.force)) do
    local tab = tabs.add{type = "tab", caption = sheet_caption(sheet), tooltip = "Sheet with the prefix \"" .. sheet.prefix .. "\""}
    tabs.add_tab(tab, tabs.add{type = "flow", direction = "vertical", tags = {sheet = sheet.id}})
    if sheet == current then selected = i end
  end
  local add = tabs.add{type = "tab", caption = "+", tooltip = "New sheet: a separate set of groups, with its own prefix"}
  tabs.add_tab(add, tabs.add{type = "flow", direction = "vertical", tags = {add_sheet = true}})
  tabs.selected_tab_index = selected
  -- A pinned window is not the player's opened GUI, so Escape and other windows leave it be.
  if not state.pinned then player.opened = w end
  build_editor(tabs.tabs[selected].content, player, current)
  apply_size(player)
  player.set_shortcut_toggled("logf-formulas", true)
end

-- Slots for filters, in the game's order. `limit` cuts them to one row of that many.
local function add_slots(parent, filters, limit)
  filters = sorted(filters)
  local slots = parent.add{type = "table", name = "slots", style = "filter_slot_table", column_count = limit or PREVIEW_COLUMNS}
  for i, filter in ipairs(filters) do
    if limit and i > limit then break end
    local v = filter.value
    local signal_type = v.type or "item"
    local import_from = filter.import_from
    if import_from and type(import_from) ~= "string" then import_from = import_from.name end
    local shown = {max = filter.max, import_from = import_from, request_from = filter.request_from,
      minimum_delivery_count = filter.minimum_delivery_count}
    -- The limit shows above the count, as in the game's own request slots.
    local button = slots.add{type = "sprite-button", style = "slot_button",
      sprite = (SIGNAL_SPRITE[signal_type] or "item") .. "/" .. v.name, number = filter.min, secondary_number = filter.max,
      tooltip = rich(signal_type, v.name, v.quality) .. " " .. (filter.min or 0) .. settings_text(shown)}
    if v.quality and v.quality ~= "normal" then button.quality = v.quality end
  end
  return slots
end

local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

-- Hides definitions and other groups whose name does not contain the search text.
local function apply_search(player, tree)
  local text = (ui(player).search or ""):lower()
  local function matches(name) return text == "" or name:lower():find(text, 1, true) ~= nil end
  for _, child in pairs(tree.children) do
    if child.tags.logf == "def-frame" then child.visible = matches(child.tags.name) end
  end
  local any = false
  for _, block in pairs(tree.others.children) do
    if block.tags.logf == "preview-group" then
      block.visible = matches(block.tags.name)
      any = any or block.visible
    end
  end
  if tree.others.children[1] and tree.others.children[1].tags.logf == nil then tree.others.children[1].visible = any end
end

-- A group's filters with a name, and how many entities use it apart from the mod's own.
local function group_contents(force, name)
  local group = force.get_logistic_group(name)
  local filters, users = {}, 0
  if group then
    for _, filter in pairs(group.filters) do
      if filter.value and filter.value.name then filters[#filters + 1] = filter end
    end
    for _, member in pairs(group.members) do
      if member.valid and member.owner.name ~= program.OWNER then users = users + 1 end
    end
  end
  return filters, users
end

local function find_tagged(parent, action)
  for _, child in pairs(parent.children) do
    if child.tags.logf == action then return child end
  end
end

-- Slots on a collapsed definition's line.
local INLINE_SLOTS = 12

local function fill_value(container, force, name)
  container.clear()
  local filters, users = group_contents(force, name)
  if #filters == 0 then
    -- A collapsed definition's header already says it is empty.
    if container.tags.inline then return end
    local empty = container.add{type = "label", caption = "empty"}
    empty.style.font_color = {0.6, 0.6, 0.6}
  elseif container.tags.inline then
    add_slots(container, filters, INLINE_SLOTS).tooltip = "Used in " .. plural(users, "place")
    if #filters > INLINE_SLOTS then
      local more = container.add{type = "label", caption = "+" .. (#filters - INLINE_SLOTS)}
      more.style.font_color = {0.7, 0.7, 0.7}
      more.style.left_margin = 4
    end
  else
    add_slots(container, filters).tooltip = "Used in " .. plural(users, "place")
  end
end

local function fill_other(block, force, name)
  block.clear()
  local filters, users = group_contents(force, name)
  block.add{type = "label", name = "header",
    caption = "[font=default-bold]" .. name .. "[/font]  [color=0.7,0.7,0.7]" .. plural(#filters, "signal") .. "[/color]",
    tooltip = "Set by hand or by a combinator, used in " .. plural(users, "place")}
  if #filters > 0 then add_slots(block, filters) end
end

-- Fills group contents beside each definition and below them, and the step section above
-- the tree. Contents are refilled in place, so the tree keeps its scroll position.
function fgui.refresh_preview(player)
  local w = window(player)
  if not w then return end
  local editor = editor_of(player)
  if not editor then return end
  local tree = editor.scroll.tree
  local state, force = ui(player), player.force
  local p = sheet_of(player)

  local step_index, step_def
  if state.step and state.step.sheet ~= p.id then state.step = nil end
  if state.step then
    for i, def in ipairs(p.defs) do
      if def.name == state.step.name and node_at(def, state.step.path) ~= nil then step_index, step_def = i, def end
    end
    if not step_def then state.step = nil end
  end
  local values = {}
  local function walk(element)
    local t = element.tags
    if t and t.logf == "result" then
      element.toggled = step_def ~= nil and t.def == step_index and same_path(t.path, state.step.path)
    elseif t and t.logf == "def-value" then
      values[#values + 1] = element
    end
    for _, c in pairs(element.children) do walk(c) end
  end
  walk(tree)

  local step = editor.step
  step.visible = step_def ~= nil
  if step_def then
    local form = node_at(step_def, state.step.path)
    local title = step_def.name
    if sexp.is_list(form) and sexp.is_sym(form[1]) then title = title .. "  [img=logf-fn-" .. form[1].sym .. "] " .. form[1].sym end
    step.head.title.caption = title
    update_actions(step.head.actions, state, step_index, step_def, state.step.path)
    step.slots.clear()
    local value, err = program.preview(force, p, form)
    if err then step.info.caption = "[color=1,0.4,0.4]" .. err .. "[/color]"
    elseif type(value) == "number" then step.info.caption = "= " .. format_count(value)
    else
      local filters = lang.filters_from_bag(value)
      step.info.caption = plural(#filters, "signal")
      add_slots(step.slots, filters)
    end
  end
  sync_opened(player, item_row_of(player))
  if state.hide_preview then
    apply_search(player, tree)
    return
  end

  for _, value in ipairs(values) do fill_value(value, force, program.group_name(p, value.tags.name)) end

  local others = tree.others
  local names = {}
  for _, name in pairs(force.get_logistic_groups()) do
    -- Other sheets' groups are left out too: this sheet cannot read them.
    if not program.owner_of_group(force, name) then names[#names + 1] = name end
  end
  table.sort(names)
  -- Rebuild the blocks only when the set of groups changes.
  local layout = table.concat(names, "\n")
  if others.tags.layout ~= layout then
    others.clear()
    if names[1] then others.add{type = "label", style = "caption_label", caption = "Other groups"} end
    for _, name in ipairs(names) do
      others.add{type = "flow", direction = "vertical", tags = {logf = "preview-group", name = name}}
    end
    others.tags = {layout = layout}
  end
  for _, block in pairs(others.children) do
    if block.tags.logf == "preview-group" then fill_other(block, force, block.tags.name) end
  end
  -- Collapsed definitions list their contents in the count's tooltip.
  for _, child in pairs(tree.children) do
    if child.tags.logf == "def-frame" and ui(player).collapsed[collapse_key(p, child.tags.name)] then
      local count = child.children[1] and find_tagged(child.children[1], "result")
      if count then
        local filters = sorted((group_contents(force, program.group_name(p, child.tags.name))))
        local lines = {}
        for i, filter in ipairs(filters) do
          if i > 40 then lines[#lines + 1] = "…"; break end
          lines[#lines + 1] = rich(filter.value.type or "item", filter.value.name, filter.value.quality) .. " " .. filter.min
        end
        if not count.caption:find("error") then count.tooltip = (#lines > 0 and table.concat(lines, "\n") or "empty") .. SELECT_HINT end
      end
    end
  end
  apply_search(player, tree)
end

local function tree_of(player)
  local w = window(player)
  local editor = w and editor_of(player)
  return editor and editor.scroll.tree
end

local function text_of(player)
  local w = text_window(player)
  return w and w.text_view
end

-- Rebuilds the tree for every player of the force with the window open.
local function rebuild(force)
  for _, player in pairs(force.connected_players) do
    local tree = tree_of(player)
    if tree then
      build_tree(tree, player)
      fgui.refresh_preview(player)
    end
  end
end

-- Updates result captions and syntax-highlighted S-expression labels in place, so fields
-- being typed in keep focus.
local function refresh_results(force)
  for _, player in pairs(force.connected_players) do
    local tree = tree_of(player)
    if tree then
      local sheet = sheet_of(player)
      local function walk(element)
        local t = element.tags
        -- A definition's own count is its status, set when the tree is drawn.
        if t and t.logf == "result" and not t.root then
          local def = sheet.defs[t.def]
          local form = def and node_at(def, t.path)
          if form ~= nil then
            local caption, tooltip = describe(program.preview(force, sheet, form))
            if t.number then caption = "#" end
            element.caption, element.tooltip = caption, tooltip .. hint(t.removable)
          end
        elseif t and t.logf == "sexp-open" and element.type == "label" then
          local def = sheet.defs[t.def]
          if def then element.caption = highlight_sexp(def.expr) end
        end
        for _, c in pairs(element.children) do walk(c) end
      end
      walk(tree)
      fgui.refresh_preview(player)
    end
  end
end

-- Structural edit: run the program and redraw.
local function changed(force)
  program.run(force)
  rebuild(force)
end

-- An edit that moves nodes: open signal editors and selections may point at another node
-- now, so they close; `keep` is a player whose selection the edit moved along.
local function reshaped(force, keep)
  for _, player in pairs(force.players) do
    local state = storage.formula_ui and storage.formula_ui[player.index]
    if state then
      state.item_edit = nil
      if player ~= keep then state.step = nil end
    end
  end
  changed(force)
end

program.on_run = refresh_results

local function move(list, index, delta, low)
  local to = index + delta
  if to < low or to > #list then return false end
  list[index], list[to] = list[to], list[index]
  return true
end

local function unique_name(p, base)
  local taken = {}
  for _, def in ipairs(p.defs) do taken[def.name] = true end
  if not taken[base] then return base end
  local n = 2
  while taken[base .. " " .. n] do n = n + 1 end
  return base .. " " .. n
end

local CLICK = {}

function CLICK.close(player) fgui.close(player) end

CLICK["toggle-window"] = function(player) fgui.toggle(player) end

-- A step's count selects it, or clears the selection when it is selected already; a
-- right-click removes the step.
function CLICK.result(player, t, def, element, event)
  if event and event.button == defines.mouse_button_type.right then
    if t.removable then CLICK.remove(player, t, def) end
    return
  end
  local state, sheet = ui(player), sheet_of(player)
  local current = state.step
  if current and current.sheet == sheet.id and current.name == def.name and same_path(current.path, t.path) then
    state.step = nil
  else
    state.step = {sheet = sheet.id, name = def.name, path = t.path}
  end
  fgui.refresh_preview(player)
end

CLICK["step-close"] = function(player)
  ui(player).step = nil
  fgui.refresh_preview(player)
end

local function resize(player, factor)
  local state = ui(player)
  local size = chosen_size(player)
  state.size = {width = math.floor(size.width * factor), height = math.floor(size.height * factor)}
  apply_size(player)
  -- Store what was actually applied, so a clamped size does not keep growing out of view.
  local editor = editor_of(player)
  state.size = {width = editor.style.maximal_width, height = editor.style.maximal_height}
end

-- Maximizing keeps the window's place and size, to restore them later.
function CLICK.maximize(player)
  local state, w = ui(player), window(player)
  if not state.maximized then state.location = w.location end
  state.maximized = not state.maximized
  w.destroy()
  fgui.open(player)
end

-- A maximized window follows the screen; others stay inside it.
function fgui.on_display_changed(event)
  apply_size(game.get_player(event.player_index))
end

-- A new size setting replaces the size, place and maximized state the player left.
function fgui.on_setting_changed(event)
  if event.setting ~= "logf-window-size" or not event.player_index then return end
  local player = game.get_player(event.player_index)
  local w = window(player)
  if w then w.destroy() end
  local state = ui(player)
  state.size, state.location, state.maximized = nil, nil, nil
  if w then fgui.open(player) end
end

function CLICK.larger(player) resize(player, 1.15) end
function CLICK.smaller(player) resize(player, 1 / 1.15) end

function CLICK.pin(player, t, def, element)
  local state, w = ui(player), window(player)
  state.pinned = not state.pinned
  element.toggled = state.pinned
  element.sprite = pin_sprite(state.pinned)
  if state.pinned then
    if player.opened == w then player.opened = nil end
  else
    sync_opened(player, item_row_of(player))
  end
end

function CLICK.apply(player)
  local win, text = text_window(player), text_of(player)
  local wt = win.tags
  local sheet = program.sheet(player.force, wt.sheet)
  if not sheet then return fgui.open_text(player) end
  local defs, err = program.parse_text(text.box.text)
  if not defs then
    wt.confirm_empty = nil
    win.tags = wt
    text.bar.message.caption = "[color=red]" .. err .. "[/color]"
    return
  end
  if #defs == 0 and #sheet.defs > 0 and wt.confirm_empty ~= text.box.text then
    wt.confirm_empty = text.box.text
    win.tags = wt
    text.bar.message.caption = "[color=yellow]This removes all " .. #sheet.defs .. " definitions. Click Apply again to confirm.[/color]"
    return
  end
  wt.confirm_empty = nil
  win.tags = wt
  program.set_text(player.force, sheet, text.box.text)
  text.bar.message.caption = "Applied."
  text.box.text = program.text(sheet)
  reshaped(player.force)
end

function CLICK.revert(player)
  local win, text = text_window(player), text_of(player)
  local wt = win.tags
  local sheet = program.sheet(player.force, wt.sheet)
  if not sheet then return end
  wt.confirm_empty = nil
  win.tags = wt
  text.box.text = program.text(sheet)
  text.bar.message.caption = ""
end

CLICK["factoriopedia"] = function(player)
  player.open_factoriopedia_gui(prototypes.virtual_signal["logf-doc-overview"])
end

CLICK["fn-help"] = function(player, t)
  player.open_factoriopedia_gui(prototypes.virtual_signal["logf-fn-" .. t.fn])
end

-- The text box editing one definition.
CLICK["sexp-open"] = function(player, t, def)
  local state = ui(player)
  state.sexp_edit = {sheet = sheet_of(player).id, def = def.name}
  state.sexp_focus = true
  build_tree(tree_of(player), player)
  fgui.refresh_preview(player)
end

CLICK["sexp-cancel"] = function(player)
  ui(player).sexp_edit = nil
  build_tree(tree_of(player), player)
  fgui.refresh_preview(player)
end

CLICK["sexp-apply"] = function(player, t, def, element)
  local frame = element.parent.parent
  local box = frame.sexp_box
  if not box then return end
  local forms, err = sexp.parse(box.text)
  if not forms then
    frame.sexp_bar.message.caption = err
    return
  end
  if #forms ~= 1 then
    frame.sexp_bar.message.caption = "expected a single formula expression"
    return
  end
  def.expr = forms[1]
  ui(player).sexp_edit = nil
  reshaped(player.force)
end

local function set_all_collapsed(player, collapsed)
  local state = ui(player)
  local sheet = sheet_of(player)
  for _, def in ipairs(sheet.defs) do state.collapsed[collapse_key(sheet, def.name)] = collapsed or nil end
  build_tree(tree_of(player), player)
  fgui.refresh_preview(player)
end

CLICK["collapse-all"] = function(player) set_all_collapsed(player, true) end
CLICK["expand-all"] = function(player) set_all_collapsed(player, false) end

function CLICK.toggle(player, t)
  local sheet = sheet_of(player)
  local def = sheet.defs[t.def]
  if not def then return end
  local collapsed = ui(player).collapsed
  local key = collapse_key(sheet, def.name)
  collapsed[key] = not collapsed[key] or nil
  build_tree(tree_of(player), player)
  fgui.refresh_preview(player)
end

-- The selection stays on the same place: the new function, the argument that took the
-- function's place, the pasted step.
function CLICK.wrap(player, t, def)
  set_node(def, t.path, {sexp.sym("sum"), node_at(def, t.path)})
  reshaped(player.force, player)
end

function CLICK.unwrap(player, t, def)
  local form = node_at(def, t.path)
  if not can_unwrap_node(form) then return end
  set_node(def, t.path, form[primary_arg_index(form)])
  reshaped(player.force, player)
end

function CLICK.remove(player, t, def)
  if #t.path == 0 then return end
  local parent, index = parent_of(def, t.path)
  table.remove(parent, index)
  reshaped(player.force)
end

function CLICK.copy(player, t, def)
  ui(player).clipboard = deep_copy(node_at(def, t.path))
  fgui.refresh_preview(player)
end

function CLICK.cut(player, t, def)
  ui(player).clipboard = deep_copy(node_at(def, t.path))
  CLICK.remove(player, t, def)
end

function CLICK.paste(player, t, def)
  local clipboard = ui(player).clipboard
  if clipboard == nil then return end
  set_node(def, t.path, deep_copy(clipboard))
  reshaped(player.force, player)
end

-- Moves an argument and the selection with it.
local function shift(player, t, def, delta)
  local parent, index = parent_of(def, t.path)
  if not move(parent, index, delta, 2) then return end
  local state = ui(player)
  if state.step then
    local path = copy(t.path)
    path[#path] = index + delta
    state.step.path = path
  end
  reshaped(player.force, player)
end

function CLICK.up(player, t, def) shift(player, t, def, -1) end
function CLICK.down(player, t, def) shift(player, t, def, 1) end

function CLICK.add_arg(player, t, def)
  local form = node_at(def, t.path)
  local spec = lang.functions[form[1].sym]
  form[#form + 1] = default_for(param_of(spec, #form))
  changed(player.force)
end
CLICK["add-arg"] = CLICK.add_arg

local function edit_item(player, def, path, pair)
  local state = ui(player)
  state.item_edit = pair and {sheet = sheet_of(player).id, def = def.name, path = path, pair = pair} or nil
  state.item_focus = pair ~= nil
end

local function remove_item(player, t, def)
  local form = node_at(def, t.path)
  table.remove(form, t.pair + 1)
  table.remove(form, t.pair)
  edit_item(player, def, t.path, nil)
  changed(player.force)
end

-- A constant's slot: a click edits it (or stops editing it), a right-click removes it.
CLICK["item-slot"] = function(player, t, def, element, event)
  if event.button == defines.mouse_button_type.right then return remove_item(player, t, def) end
  local current = ui(player).item_edit
  local open = current and current.def == def.name and same_path(current.path, t.path) and current.pair == t.pair
  edit_item(player, def, t.path, not open and t.pair or nil)
  build_tree(tree_of(player), player)
  fgui.refresh_preview(player)
end

CLICK["item-remove"] = remove_item

CLICK["item-done"] = function(player)
  ui(player).item_edit = nil
  build_tree(tree_of(player), player)
  fgui.refresh_preview(player)
end

CLICK["def-up"] = function(player, t)
  if move(sheet_of(player).defs, t.def, -1, 1) then changed(player.force) end
end

CLICK["def-down"] = function(player, t)
  if move(sheet_of(player).defs, t.def, 1, 1) then changed(player.force) end
end

-- Deleting a definition takes a second click.
CLICK["def-delete"] = function(player, t, def, element)
  if not t.confirm then
    t.confirm = true
    element.tags = t
    element.sprite = "utility/trash_white"
    element.tooltip = "Click again to delete '" .. def.name .. "'"
    return
  end
  table.remove(sheet_of(player).defs, t.def)
  changed(player.force)
end

CLICK["def-duplicate"] = function(player, t, def)
  local p = sheet_of(player)
  local name = unique_name(p, def.name .. " copy")
  table.insert(p.defs, t.def + 1, {name = name, expr = deep_copy(def.expr)})
  changed(player.force)
end

CLICK["def-new"] = function(player)
  local p = sheet_of(player)
  local name = unique_name(p, "new group")
  p.defs[#p.defs + 1] = {name = name, expr = {sexp.sym("group"), sexp.str("")}}
  changed(player.force)
end

local NEEDS_DEF = {wrap = true, unwrap = true, remove = true, up = true, down = true, cut = true, copy = true, paste = true,
  add_arg = true, ["add-arg"] = true, result = true,
  ["sexp-open"] = true, ["sexp-apply"] = true, ["def-delete"] = true, ["def-duplicate"] = true,
  ["item-slot"] = true, ["item-remove"] = true}

local function disarm_delete_button(button, tooltip, keep_element)
  if not (button and button.valid) or button == keep_element then return end
  local bt = button.tags
  if bt and bt.confirm then
    bt.confirm = nil
    button.tags = bt
    button.sprite = "utility/trash"
    button.tooltip = tooltip
  end
end

-- Clicking or interacting with anything else cancels any pending two-click delete.
local function disarm_deletes(player, keep_element)
  if not player then return end
  local editor = editor_of(player)
  if editor then
    disarm_delete_button(editor.bar and editor.bar.delete, sheet_delete_tooltip(#program.sheets(player.force) == 1), keep_element)
    local tree = editor.scroll and editor.scroll.tree
    if tree then
      for _, child in ipairs(tree.children) do
        local head = child.tags and child.tags.logf == "def-frame" and child.head
        disarm_delete_button(head and head.delete, DEF_DELETE_TOOLTIP, keep_element)
      end
    end
  end
  local win = text_window(player)
  if win then
    local wt, apply_btn = win.tags, win.text_view and win.text_view.bar and win.text_view.bar.apply
    if wt and wt.confirm_empty and keep_element ~= apply_btn then
      wt.confirm_empty = nil
      win.tags = wt
      local msg = win.text_view.bar.message
      if msg and msg.caption:find("Click Apply again", 1, true) then msg.caption = "" end
    end
  end
end

local function context(event)
  local element = event.element
  if not (element and element.valid) then return end
  local t = element.tags
  if not (t and t.logf) then return end
  local player = game.get_player(event.player_index)
  local def = t.def and sheet_of(player).defs[t.def]
  return player, t, def, element
end

function fgui.on_click(event)
  local element = event.element and event.element.valid and event.element or nil
  disarm_deletes(game.get_player(event.player_index), element)
  local player, t, def = context(event)
  if not player then return end
  local handler = CLICK[t.logf]
  if not handler then return end
  if NEEDS_DEF[t.logf] and not def then return end
  handler(player, t, def, element, event)
end

function fgui.on_selection(event)
  disarm_deletes(game.get_player(event.player_index))
  local player, t, def, element = context(event)
  if not (player and def) then return end
  if t.logf == "network-pick" then
    local choice = program.network_choices(player.force)[element.selected_index]
    if not choice then return end
    local _, member = network_parts(node_at(def, t.path))
    local new = {sexp.sym("network"), table.unpack(choice.args)}
    if member ~= "all" then new[#new + 1] = sexp.sym(member) end
    set_node(def, t.path, new)
    changed(player.force)
  elseif t.logf == "network-member" then
    local args = network_parts(node_at(def, t.path))
    local member = lang.members[element.selected_index]
    local new = {sexp.sym("network"), table.unpack(args)}
    if member ~= "all" then new[#new + 1] = sexp.sym(member) end
    set_node(def, t.path, new)
    changed(player.force)
  elseif t.logf == "function" then
    local name = lang.order[element.selected_index]
    if name then set_function(def, t.path, name, player.force); reshaped(player.force) end
  elseif t.logf == "group-name" then
    local name = t.names and t.names[element.selected_index]
    if name then
      node_at(def, t.path)[2] = sexp.str(name)
      changed(player.force)
    end
  elseif t.logf == "choice" then
    set_node(def, t.path, sexp.sym(t.names[element.selected_index]))
    changed(player.force)
  end
end

local function signal_token(signal)
  local signal_type = signal.type or "item"
  return lang.signal_token(signal_type, signal.name, signal.quality or "normal")
end

function fgui.on_elem_changed(event)
  disarm_deletes(game.get_player(event.player_index))
  local player, t, def, element = context(event)
  if not (player and def) then return end
  local form = node_at(def, t.path)
  local value = element.elem_value
  if t.logf == "item-signal" then
    if not value then return remove_item(player, t, def) end
    form[t.pair] = sexp.sym(signal_token(value))
    changed(player.force)
  elseif t.logf == "recipe-pick" then
    -- Clearing the picker keeps the recipe; a recipe parameter is never empty.
    if value then set_node(def, t.path, sexp.sym(value)) end
    changed(player.force)
  elseif t.logf == "filter-pick" then
    local parent, index = parent_of(def, t.path)
    local spec = lang.functions[parent[1].sym]
    if value then set_node(def, t.path, sexp.sym(signal_token(value)))
    elseif #parent - 1 > #spec.params then table.remove(parent, index) end
    changed(player.force)
  elseif t.logf == "filter-add" and value then
    form[#form + 1] = sexp.sym(signal_token(value))
    changed(player.force)
  elseif t.logf == "item-add" and value then
    form[#form + 1] = sexp.sym(signal_token(value))
    form[#form + 1] = 1
    -- The new signal opens for its count.
    edit_item(player, def, t.path, #form - 1)
    changed(player.force)
  end
end

-- Marks a number field whose text is not a number.
local function mark_invalid(element, invalid)
  local width, t = element.style.minimal_width, element.tags
  if invalid and element.style.name ~= "invalid_value_textfield" then
    t.normal_style = element.style.name
    element.tags = t
    element.style = "invalid_value_textfield"
  elseif not invalid and t.normal_style then
    element.style = t.normal_style
  else
    return
  end
  if width and width > 0 then element.style.width = width end
end

function fgui.on_text_changed(event)
  disarm_deletes(game.get_player(event.player_index))
  local player, t, def, element = context(event)
  if player and t.logf == "search" then
    ui(player).search = element.text
    apply_search(player, tree_of(player))
    return
  end
  if not (player and def) then return end
  if t.logf ~= "number" and t.logf ~= "item-count" then return end
  local n = sexp.parse_number(element.text)
  mark_invalid(element, n == nil)
  if not n then return end
  if t.logf == "number" then set_node(def, t.path, n)
  elseif t.logf == "item-count" then node_at(def, t.path)[t.pair + 1] = n
  else return end
  program.run(player.force)
end

local function rename_def(player, def, name)
  ui(player).editing = nil
  if name == "" or name == def.name then return rebuild(player.force) end
  local collapsed, sheet = ui(player).collapsed, sheet_of(player)
  collapsed[collapse_key(sheet, name)], collapsed[collapse_key(sheet, def.name)] = collapsed[collapse_key(sheet, def.name)], nil
  local state = ui(player)
  if state.step and state.step.name == def.name then state.step.name = name end
  if state.sexp_edit and state.sexp_edit.def == def.name then state.sexp_edit.def = name end
  def.name = name
  changed(player.force)
end

local function set_prefix(player, prefix)
  ui(player).editing = nil
  local ok, problem = program.set_prefix(player.force, sheet_of(player), prefix)
  if not ok then
    player.print("[color=yellow]Logistic formulas:[/color] that prefix cannot be used: " .. problem .. ".")
  end
  -- Tab captions show prefixes, so every window of the force is redrawn.
  fgui.reopen_all(player.force)
end

-- The edit button of a name: starts editing it, or applies the edit in progress.
CLICK["label-edit"] = function(player, t, def, element)
  local state = ui(player)
  local field = element.parent.field
  if field then
    if t.field == "rename" and def then rename_def(player, def, field.text)
    elseif t.field == "prefix" then set_prefix(player, field.text) end
    return
  end
  if t.field == "rename" and def then
    state.editing = {sheet = t.sheet, def = def.name}
    build_tree(tree_of(player), player)
    fgui.refresh_preview(player)
  elseif t.field == "prefix" then
    state.editing = {sheet = t.sheet, prefix = true}
    fgui.open(player)
  end
end

function fgui.on_confirmed(event)
  disarm_deletes(game.get_player(event.player_index))
  local player, t, def, element = context(event)
  if not player then return end
  if t.logf == "rename" and def then
    rename_def(player, def, element.text)
  elseif t.logf == "number" then
    rebuild(player.force)
  elseif t.logf == "item-count" then
    -- Enter applies the count and closes the signal's editor.
    ui(player).item_edit = nil
    rebuild(player.force)
  elseif t.logf == "prefix" then
    set_prefix(player, element.text)
  end
end

function fgui.on_tab_changed(event)
  disarm_deletes(game.get_player(event.player_index))
  local player, t, _, element = context(event)
  if not (player and t.logf == "tabs") then return end
  local content = element.tabs[element.selected_tab_index].content
  if content.tags.add_sheet then
    local sheet, problem = program.add_sheet(player.force)
    if not sheet then
      player.print("[color=yellow]Logistic formulas:[/color] no new sheet: " .. problem .. "; give that sheet a prefix first.")
      return fgui.open(player)
    end
    ui(player).sheet = sheet.id
    fgui.reopen_all(player.force)
  else
    ui(player).sheet = content.tags.sheet
    fgui.open(player)
  end
end

-- Puts the cursor in the search field of an open window.
function fgui.focus_search(player)
  local editor = editor_of(player)
  if not editor then return end
  editor.bar.search.focus()
  editor.bar.search.select_all()
end

-- Reopens every open window of a force, after its sheets changed.
function fgui.reopen_all(force)
  for _, player in pairs(force.connected_players) do
    if window(player) then fgui.open(player) end
  end
end

CLICK["text-open"] = function(player) fgui.open_text(player) end
CLICK["text-close"] = function(player) close_text(player) end

-- Deleting a sheet takes a second click.
CLICK["sheet-delete"] = function(player, t, def, element)
  if not t.confirm then
    t.confirm = true
    element.tags = t
    element.tooltip = "Click again to delete this sheet"
    element.sprite = "utility/trash_white"
    return
  end
  program.remove_sheet(player.force, sheet_of(player))
  ui(player).sheet = nil
  fgui.reopen_all(player.force)
end

function fgui.on_closed(event)
  local element = event.element
  if not (element and element.valid) then return end
  local player = game.get_player(event.player_index)
  local state = ui(player)
  -- Handing the opened GUI between the windows closes none of them.
  if state.switching then return end
  if element.tags.logf == "item-editor" then
    -- Escape closes a constant's signal editor and leaves the window open.
    state.item_edit = nil
    build_tree(tree_of(player), player)
    fgui.refresh_preview(player)
  elseif element.tags.logf == "selection" then
    state.step = nil
    fgui.refresh_preview(player)
  elseif element.name == TEXT_WINDOW then close_text(player)
  elseif element.name == WINDOW and not state.pinned then fgui.close(player) end
end

-- Another window opening closes an unpinned editor, also while its signal editor or
-- selection holds the opened GUI.
function fgui.on_opened(event)
  local player = game.get_player(event.player_index)
  disarm_deletes(player)
  if not window(player) or ui(player).pinned then return end
  local element = event.element
  if event.gui_type == defines.gui_type.custom and element and element.valid and is_ours(element) then return end
  fgui.close(player)
end

function fgui.on_checked(event)
  disarm_deletes(game.get_player(event.player_index))
  local player, t, _, element = context(event)
  if not (player and t.logf == "show-preview") then return end
  ui(player).hide_preview = not element.state
  build_tree(tree_of(player), player)
  fgui.refresh_preview(player)
end

-- Keeps open previews current; groups outside the program change without an event.
function fgui.tick()
  for _, player in pairs(game.connected_players) do
    if window(player) and not ui(player).hide_preview then fgui.refresh_preview(player) end
  end
end

return fgui
