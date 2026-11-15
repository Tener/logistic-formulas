-- What differs between two states of a sheet, {prefix, defs}, for undo and redo tooltips.
local sexp = require("scripts.sexp")

local changes = {}

-- The smallest formula that holds every difference between a and b, as the pair (a part,
-- b part). Descends while exactly one argument differs, and stops at a constant and above a
-- plain value, so the pair keeps the function it belongs to.
local function narrow(a, b)
  if not (sexp.is_list(a) and sexp.is_list(b)) or #a ~= #b or sexp.print(a[1]) ~= sexp.print(b[1])
    or sexp.is_sym(a[1], "constant") then
    return a, b
  end
  local differing
  for i = 2, #a do
    if sexp.print(a[i]) ~= sexp.print(b[i]) then
      if differing then return a, b end
      differing = i
    end
  end
  if not differing or not (sexp.is_list(a[differing]) and sexp.is_list(b[differing])) then return a, b end
  return narrow(a[differing], b[differing])
end

local function index_by_name(defs)
  local by_name = {}
  for i, def in ipairs(defs) do
    if not by_name[def.name] then by_name[def.name] = i end
  end
  return by_name
end

-- A list of changes, in the order of the definitions after the change:
--   {kind = "prefix", old = string, new = string}
--   {kind = "add", name = string, new = form}
--   {kind = "remove", name = string, old = form}
--   {kind = "rename", old_name = string, name = string, old = form or nil, new = form or nil}
--   {kind = "change", name = string, old = form, new = form}
--   {kind = "move", name = string, from = index, to = index}
-- A renamed definition is one removed and one added with the same formula, or the only one
-- removed and the only one added, at the same place; `old` and `new` are set when its formula
-- changed too.
function changes.describe(before, after)
  local list = {}
  if before.prefix ~= after.prefix then list[1] = {kind = "prefix", old = before.prefix, new = after.prefix} end
  local old_index, new_index = index_by_name(before.defs), index_by_name(after.defs)
  local removed, added = {}, {}
  for i, def in ipairs(before.defs) do
    if old_index[def.name] == i and not new_index[def.name] then removed[#removed + 1] = i end
  end
  for i, def in ipairs(after.defs) do
    if new_index[def.name] == i and not old_index[def.name] then added[#added + 1] = i end
  end

  -- Pairs of (old index, new index) taken to be one definition renamed.
  local renamed = {}
  local function pair_up(match)
    for ai = #added, 1, -1 do
      for ri = #removed, 1, -1 do
        if match(removed[ri], added[ai]) then
          renamed[added[ai]] = removed[ri]
          table.remove(removed, ri)
          table.remove(added, ai)
          break
        end
      end
    end
  end
  pair_up(function(r, a) return sexp.print(before.defs[r].expr) == sexp.print(after.defs[a].expr) end)
  if #removed == 1 and #added == 1 then pair_up(function(r, a) return r == a end) end

  -- The definitions present before and after that moved: those outside the longest run
  -- that kept its order. A swap of neighbours names one of the two.
  local kept = {}
  for i, def in ipairs(after.defs) do
    if new_index[def.name] == i and old_index[def.name] then kept[#kept + 1] = def.name end
  end
  local length, prev = {}, {}
  for i, name in ipairs(kept) do
    length[i] = 1
    for j = 1, i - 1 do
      if old_index[kept[j]] < old_index[name] and length[j] + 1 > length[i] then length[i], prev[i] = length[j] + 1, j end
    end
  end
  local last = nil
  for i in ipairs(kept) do
    if not last or length[i] >= length[last] then last = i end
  end
  local in_order = {}
  while last do
    in_order[kept[last]] = true
    last = prev[last]
  end

  local added_set = {}
  for _, i in ipairs(added) do added_set[i] = true end
  for i, def in ipairs(after.defs) do
    local old = old_index[def.name] and before.defs[old_index[def.name]]
    if new_index[def.name] ~= i then
      -- A second definition of the same name; the first stands for both.
    elseif renamed[i] then
      local from = before.defs[renamed[i]]
      local entry = {kind = "rename", old_name = from.name, name = def.name}
      if sexp.print(from.expr) ~= sexp.print(def.expr) then entry.old, entry.new = narrow(from.expr, def.expr) end
      list[#list + 1] = entry
    elseif added_set[i] then
      list[#list + 1] = {kind = "add", name = def.name, new = def.expr}
    elseif old then
      if sexp.print(old.expr) ~= sexp.print(def.expr) then
        local a, b = narrow(old.expr, def.expr)
        list[#list + 1] = {kind = "change", name = def.name, old = a, new = b}
      end
      if not in_order[def.name] then
        list[#list + 1] = {kind = "move", name = def.name, from = old_index[def.name], to = i}
      end
    end
  end
  for _, i in ipairs(removed) do
    list[#list + 1] = {kind = "remove", name = before.defs[i].name, old = before.defs[i].expr}
  end
  return list
end

return changes
