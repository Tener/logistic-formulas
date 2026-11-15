-- Evaluator for group formulas. A value is a number or a bag: signals with counts, keyed by
-- "type/name/quality", each entry {type, name, quality, count} plus the logistic request
-- settings a group filter carries: max (nil for no limit), import_from, request_from and
-- min_delivery. Counts stay fractional until a bag is written out.
local sexp = require("scripts.sexp")

local lang = {}

local SIGNAL_TYPES = {
  item = "item", fluid = "fluid", virtual = "virtual_signal", entity = "entity", recipe = "recipe",
  ["space-location"] = "space_location", ["asteroid-chunk"] = "asteroid_chunk", quality = "quality",
}
-- Types tried, in order, for a signal written without a type prefix.
local GUESS = {"item", "fluid", "virtual"}

-- Average amount of a recipe product per craft, before productivity.
local function expected_amount(product)
  local amount = product.amount or (product.amount_min + product.amount_max) / 2
  local shared = product.shared_probability
  local probability = (product.independent_probability or 1) * (shared and (shared.max - shared.min) or 1)
  return amount * probability + (product.extra_count_fraction or 0)
end

local function fail(message, ...) error({formula_error = string.format(message, ...)}, 0) end

local function key(type, name, quality) return type .. "/" .. name .. "/" .. quality end

local function is_bag(value) return type(value) == "table" end

-- Request settings copied along with a signal; the first one set wins when signals merge.
local SETTINGS = {"import_from", "request_from", "min_delivery"}

local function plus(a, b) return a + b end

-- Adds count to a signal. `from` is the entry the count comes from, whose settings carry
-- over; `merge_max(a, b)` combines limits when the signal is already present, and leaves
-- the existing limit alone when omitted.
local function add(bag, type, name, quality, count, from, merge_max)
  if type ~= "item" and type ~= "entity" and type ~= "recipe" then quality = "normal" end
  local k = key(type, name, quality)
  local entry = bag[k]
  if entry then
    entry.count = entry.count + count
    if from then
      for _, setting in ipairs(SETTINGS) do
        if entry[setting] == nil then entry[setting] = from[setting] end
      end
      -- No limit on either side means no limit.
      if merge_max then entry.max = entry.max and from.max and merge_max(entry.max, from.max) or nil end
    end
  else
    entry = {type = type, name = name, quality = quality, count = count}
    if from then
      for _, setting in ipairs(SETTINGS) do entry[setting] = from[setting] end
      entry.max = from.max
    end
    bag[k] = entry
  end
  return entry
end

-- A bag with fn applied to each entry; fn returns type, name, quality, count, or nothing
-- to drop the entry. Settings carry over; signals that land on the same key add up.
local function map(bag, fn)
  local out = {}
  for _, e in pairs(bag) do
    local type, name, quality, count = fn(e)
    if type then add(out, type, name, quality, count, e, plus) end
  end
  return out
end

-- Copy of a bag with each entry changed in place by fn(entry).
local function each(bag, fn)
  local out = {}
  for _, e in pairs(bag) do
    local copy = {}
    for k, v in pairs(e) do copy[k] = v end
    fn(copy)
    out[key(copy.type, copy.name, copy.quality)] = copy
  end
  return out
end

local function scale(bag, factor)
  return each(bag, function(e)
    e.count = e.count * factor
    -- Limits scale with the counts; a negative factor leaves no sensible limit.
    if e.max then e.max = factor > 0 and e.max * factor or nil end
  end)
end

-- "[type/]name[:quality]" -> type, name, quality.
function lang.parse_signal(token)
  local rest, quality = token:match("^(.-):([^:/]+)$")
  if not rest then rest, quality = token, "normal" end
  if not prototypes.quality[quality] then fail("unknown quality '%s' in %s", quality, token) end
  local type, name = rest:match("^([^/]+)/(.+)$")
  if type then
    local collection = SIGNAL_TYPES[type]
    if not collection then fail("unknown signal type '%s' in %s", type, token) end
    if not prototypes[collection][name] then fail("unknown %s '%s'", type, name) end
    return type, name, quality
  end
  for _, guess in ipairs(GUESS) do
    if prototypes[SIGNAL_TYPES[guess]][rest] then return guess, rest, quality end
  end
  fail("unknown item, fluid or signal '%s'", rest)
end

function lang.signal_token(type, name, quality)
  local token = name
  if type ~= "item" then token = type .. "/" .. name end
  if quality and quality ~= "normal" then token = token .. ":" .. quality end
  return token
end

local function shift_quality(force, name, steps)
  local quality = prototypes.quality[name]
  while steps ~= 0 do
    local to
    if steps > 0 then to = quality.next else to = quality.previous end
    if not to or (steps > 0 and not force.is_quality_unlocked(to)) then break end
    quality = to
    steps = steps + (steps > 0 and -1 or 1)
  end
  return quality.name
end

-- Compares groups signal by signal with op (math.max or math.min), a signal missing from a
-- group counting as 0, or compares numbers. Groups and numbers cannot mix.
-- merge_max(a, b) combines limits, each possibly nil for no limit.
local function compare(name, args, op, merge_max)
  local bags = is_bag(args[1])
  for _, arg in ipairs(args) do
    if is_bag(arg) ~= bags then fail("%s cannot mix groups and numbers", name) end
  end
  if not bags then return op(table.unpack(args)) end
  local out = {}
  for _, bag in ipairs(args) do
    for k, e in pairs(bag) do
      local current = out[k]
      if current then
        current.max = merge_max(current.max, e.max)
        for _, setting in ipairs(SETTINGS) do
          if current[setting] == nil then current[setting] = e[setting] end
        end
      else
        local copy = {}
        for field, v in pairs(e) do copy[field] = v end
        out[k] = copy
      end
    end
  end
  for k, e in pairs(out) do
    local count = nil
    for _, bag in ipairs(args) do
      local c = bag[k] and bag[k].count or 0
      count = count and op(count, c) or c
    end
    e.count = count
  end
  return out
end

-- A group with each count clamped by op against a number, or a number clamped.
local function clamp(value, bound, op)
  if not is_bag(value) then return op(value, bound) end
  return each(value, function(e) e.count = op(e.count, bound) end)
end

-- Parameter types: "bag", "number", "value" (either), "group" (a group name), "recipe", a name
-- from lang.choices, "items" (signal/count pairs, only in the constant literal), "filter" (a
-- signal written out, or a group). `rest` repeats for extra arguments.
-- The tree editor builds its widgets from these tables.
lang.functions = {}
lang.order = {}
local function define(name, spec)
  spec.name = name
  spec.params = spec.params or {}
  lang.functions[name] = spec
  lang.order[#lang.order + 1] = name
end

define("group", {params = {{name = "name", type = "group"}}, special = true})
define("constant", {rest = {name = "signal", type = "items"}, special = true})
-- Selected by name, or by surface and position: (network "name" [member]) or (network "surface" x y [member]).
define("network", {params = {{name = "network", type = "network"}}, special = true})

-- A recipe's inputs or outputs, for a number of crafts. Products count at their average yield.
define("ingredients", {params = {{name = "recipe", type = "recipe"}}, optional = {{name = "crafts", type = "number", default = 1}},
  fn = function(ctx, recipe, crafts)
    local bag = {}
    for _, ingredient in pairs(prototypes.recipe[recipe].ingredients) do
      add(bag, ingredient.type, ingredient.name, "normal", ingredient.amount * (crafts or 1))
    end
    return bag
  end})

define("products", {params = {{name = "recipe", type = "recipe"}}, optional = {{name = "crafts", type = "number", default = 1}},
  fn = function(ctx, recipe, crafts)
    local bag = {}
    for _, product in pairs(prototypes.recipe[recipe].products) do
      if product.type == "item" or product.type == "fluid" then
        add(bag, product.type, product.name, "normal", expected_amount(product) * (crafts or 1))
      end
    end
    return bag
  end})

define("sum", {rest = {name = "add", type = "value"}, fn = function(ctx, ...)
  local args = {...}
  if #args == 0 then return 0 end
  local bags = is_bag(args[1])
  local sum = bags and {} or 0
  for _, arg in ipairs(args) do
    if is_bag(arg) ~= bags then fail("sum cannot mix groups and numbers") end
    if bags then
      for _, e in pairs(arg) do add(sum, e.type, e.name, e.quality, e.count, e, plus) end
    else sum = sum + arg end
  end
  return sum
end})

define("subtract", {params = {{name = "from", type = "value"}, {name = "minus", type = "value"}},
  rest = {name = "minus", type = "value"}, fn = function(ctx, first, ...)
  local rest = {...}
  local out = is_bag(first) and scale(first, 1) or first
  for _, arg in ipairs(rest) do
    if is_bag(arg) ~= is_bag(first) then fail("subtract cannot mix groups and numbers") end
    if is_bag(arg) then
      -- The result keeps the first group's settings; what is subtracted brings none.
      for _, e in pairs(arg) do add(out, e.type, e.name, e.quality, -e.count) end
    else out = out - arg end
  end
  return out
end})

define("multiply", {params = {{name = "factor", type = "value"}}, rest = {name = "factor", type = "value", default = 1},
  fn = function(ctx, ...)
  local factor, bag = 1, nil
  for _, arg in ipairs{...} do
    if is_bag(arg) then
      if bag then fail("multiply takes at most one group") end
      bag = arg
    else factor = factor * arg end
  end
  return bag and scale(bag, factor) or factor
end})

define("divide", {params = {{name = "of", type = "value"}, {name = "by", type = "number"}}, fn = function(ctx, value, by)
  if by == 0 then fail("division by zero") end
  return is_bag(value) and scale(value, 1 / by) or value / by
end})

define("highest", {params = {{name = "of", type = "value"}}, rest = {name = "and", type = "value"}, fn = function(ctx, ...)
  return compare("highest", {...}, math.max, function(a, b) return a and b and math.max(a, b) or nil end)
end})

define("lowest", {params = {{name = "of", type = "value"}}, rest = {name = "and", type = "value"}, fn = function(ctx, ...)
  return compare("lowest", {...}, math.min, function(a, b)
    if a and b then return math.min(a, b) end
    return a or b
  end)
end})

define("at-least", {params = {{name = "of", type = "value"}, {name = "count", type = "number"}}, fn = function(ctx, value, bound)
  return clamp(value, bound, math.max)
end})

define("at-most", {params = {{name = "of", type = "value"}, {name = "count", type = "number"}}, fn = function(ctx, value, bound)
  return clamp(value, bound, math.min)
end})

define("keep-positive", {params = {{name = "of", type = "bag"}}, fn = function(ctx, bag)
  return map(bag, function(e) if e.count > 0 then return e.type, e.name, e.quality, e.count end end)
end})

define("quality-up", {params = {{name = "of", type = "bag"}}, optional = {{name = "steps", type = "number", default = 1}}, fn = function(ctx, bag, steps)
  return map(bag, function(e) return e.type, e.name, shift_quality(ctx.force, e.quality, steps or 1), e.count end)
end})

define("quality-down", {params = {{name = "of", type = "bag"}}, optional = {{name = "steps", type = "number", default = 1}}, fn = function(ctx, bag, steps)
  return map(bag, function(e) return e.type, e.name, shift_quality(ctx.force, e.quality, -(steps or 1)), e.count end)
end})

define("set-quality", {params = {{name = "of", type = "bag"}, {name = "quality", type = "quality"}}, fn = function(ctx, bag, quality)
  return map(bag, function(e) return e.type, e.name, quality, e.count end)
end})

define("round-to-stacks", {params = {{name = "of", type = "bag"}}, fn = function(ctx, bag)
  return map(bag, function(e)
    local count = e.count
    if e.type == "item" and count > 0 then
      local stack = prototypes.item[e.name].stack_size
      count = math.ceil(count / stack - 1e-9) * stack
    end
    return e.type, e.name, e.quality, count
  end)
end})

define("set-stacks", {params = {{name = "of", type = "bag"}}, optional = {{name = "stacks", type = "number", default = 1}}, fn = function(ctx, bag, stacks)
  return map(bag, function(e)
    if e.type ~= "item" then return e.type, e.name, e.quality, e.count end
    return e.type, e.name, e.quality, prototypes.item[e.name].stack_size * (stacks or 1)
  end)
end})

-- A test for the signals a filter names: a signal written without a quality matches every
-- quality; one written with a quality, or a signal of a group, matches only that quality.
local function matcher(filters)
  local exact, any = {}, {}
  for _, f in ipairs(filters) do
    if f.bag then
      for k in pairs(f.bag) do exact[k] = true end
    elseif f.quality then exact[key(f.type, f.name, f.quality)] = true
    else any[f.type .. "/" .. f.name] = true end
  end
  return function(e) return exact[key(e.type, e.name, e.quality)] or any[e.type .. "/" .. e.name] or false end
end

define("keep", {params = {{name = "of", type = "bag"}, {name = "signals", type = "filter"}},
  rest = {name = "signals", type = "filter"}, fn = function(ctx, bag, ...)
  local matches = matcher({...})
  return map(bag, function(e) if matches(e) then return e.type, e.name, e.quality, e.count end end)
end})

define("drop", {params = {{name = "of", type = "bag"}, {name = "signals", type = "filter"}},
  rest = {name = "signals", type = "filter"}, fn = function(ctx, bag, ...)
  local matches = matcher({...})
  return map(bag, function(e) if not matches(e) then return e.type, e.name, e.quality, e.count end end)
end})

-- A per-signal setting from a number, or from the counts of a group (signals it lacks keep theirs).
local function per_signal(bag, value, field)
  return each(bag, function(e)
    if type(value) == "number" then e[field] = value
    else
      local from = value[key(e.type, e.name, e.quality)]
      if from then e[field] = from.count end
    end
  end)
end

define("set-max", {params = {{name = "of", type = "bag"}, {name = "limit", type = "value"}}, fn = function(ctx, bag, limit)
  return per_signal(bag, limit, "max")
end})

define("no-max", {params = {{name = "of", type = "bag"}}, fn = function(ctx, bag)
  return each(bag, function(e) e.max = nil end)
end})

define("get-max", {params = {{name = "of", type = "bag"}}, fn = function(ctx, bag)
  local out = {}
  for k, e in pairs(bag) do
    if e.max then out[k] = {type = e.type, name = e.name, quality = e.quality, count = e.max} end
  end
  return out
end})

define("import-from", {params = {{name = "of", type = "bag"}, {name = "location", type = "space-location"}}, fn = function(ctx, bag, location)
  return each(bag, function(e) e.import_from = location ~= lang.ANYWHERE and location or nil end)
end})

define("request-from", {params = {{name = "of", type = "bag"}, {name = "source", type = "request-source"}}, fn = function(ctx, bag, source)
  return each(bag, function(e) e.request_from = source end)
end})

define("min-delivery", {params = {{name = "of", type = "bag"}, {name = "count", type = "value"}}, fn = function(ctx, bag, count)
  return per_signal(bag, count, "min_delivery")
end})

-- Parameters given as a name rather than a formula.
function lang.is_name_param(param_type)
  return param_type == "recipe" or lang.choices[param_type] ~= nil
end

-- Parameters chosen from a fixed list of names: type -> function returning the names in order.
lang.ANYWHERE = "anywhere"
lang.choices = {
  quality = function()
    local list = {}
    for name, quality in pairs(prototypes.quality) do
      if not quality.hidden then list[#list + 1] = {name = name, level = quality.level} end
    end
    table.sort(list, function(a, b) return a.level < b.level end)
    for i, q in ipairs(list) do list[i] = q.name end
    return list
  end,
  ["space-location"] = function()
    local list = {}
    for name, location in pairs(prototypes.space_location) do
      if not location.hidden then list[#list + 1] = name end
    end
    table.sort(list)
    table.insert(list, 1, lang.ANYWHERE)
    return list
  end,
  ["request-source"] = function() return {"planet", "platforms", "all"} end,
}

local function name_of(form, what)
  if sexp.is_str(form) then return form.str end
  if sexp.is_sym(form) then return form.sym end
  fail("%s must be a name", what)
end

local function check(value, wanted, fn_name, index)
  if wanted == "bag" and not is_bag(value) then fail("%s: argument %d must be a group, got a number", fn_name, index) end
  if wanted == "number" and is_bag(value) then fail("%s: argument %d must be a number, got a group", fn_name, index) end
end

local evaluate

local function eval_items(form, ctx)
  local bag = {}
  if #form % 2 ~= 1 then fail("a constant needs a count after each signal") end
  for i = 2, #form, 2 do
    local signal_type, name, quality = lang.parse_signal(name_of(form[i], "a signal"))
    local count = evaluate(form[i + 1], ctx)
    if type(count) ~= "number" then fail("the count of %s must be a number", name) end
    add(bag, signal_type, name, quality, count)
  end
  return bag
end

local MEMBERS = {all = true, storage = true, providers = true}
lang.members = {"all", "storage", "providers"}

-- Reads a network form into {name = string} or {surface = string, x = number, y = number},
-- and the member to count. Raises a formula error when malformed.
function lang.network_selector(form)
  local first = form[2]
  if first == nil then fail("network needs a network name, or a surface and a position") end
  local selector, next_arg = nil, 3
  if type(form[3]) == "number" then
    if type(form[4]) ~= "number" then fail("network: a position needs x and y") end
    selector = {surface = name_of(first, "the surface"), x = form[3], y = form[4]}
    next_arg = 5
  else
    selector = {name = name_of(first, "the network")}
  end
  local member = form[next_arg] ~= nil and name_of(form[next_arg], "the member") or "all"
  if not MEMBERS[member] then fail("network: count from all, storage or providers, not '%s'", member) end
  if form[next_arg + 1] ~= nil then fail("network takes at most a name or position and a member") end
  return selector, member
end

-- ctx: {force = LuaForce, group = function(name) -> bag, network = function(selector, member) -> bag}
function evaluate(form, ctx)
  if type(form) == "number" then return form end
  if sexp.is_str(form) then fail('unexpected string "%s"', form.str) end
  if sexp.is_sym(form) then fail("unknown name '%s'", form.sym) end
  local head = form[1]
  if not sexp.is_sym(head) then fail("a formula must start with a function name") end
  local spec = lang.functions[head.sym]
  if not spec then fail("unknown function '%s'", head.sym) end
  if head.sym == "constant" then return eval_items(form, ctx) end
  if head.sym == "network" then return ctx.network(lang.network_selector(form)) end
  if head.sym == "group" then
    if #form ~= 2 then fail("group takes one name") end
    return ctx.group(name_of(form[2], "the group"))
  end

  local required, optional = #spec.params, spec.optional and #spec.optional or 0
  local given = #form - 1
  if given < required or (not spec.rest and given > required + optional) then
    fail("%s takes %s%d argument%s, got %d", spec.name, (spec.rest or optional > 0) and "at least " or "", required,
      required == 1 and "" or "s", given)
  end
  local args = {}
  for i = 1, given do
    local param = spec.params[i] or (spec.optional and spec.optional[i - required]) or spec.rest
    local arg = form[i + 1]
    local choices = lang.choices[param.type]
    if param.type == "filter" then
      if sexp.is_sym(arg) or sexp.is_str(arg) then
        local token = name_of(arg, "a signal")
        local signal_type, name, quality = lang.parse_signal(token)
        args[i] = {type = signal_type, name = name, quality = token:find(":") and quality or nil}
      else
        local bag = evaluate(arg, ctx)
        check(bag, "bag", spec.name, i)
        args[i] = {bag = bag}
      end
    elseif param.type == "recipe" then
      local recipe = name_of(arg, "the recipe")
      if not prototypes.recipe[recipe] then fail("%s: unknown recipe '%s'", spec.name, recipe) end
      args[i] = recipe
    elseif choices then
      local choice = name_of(arg, "the " .. param.name)
      local known = false
      for _, name in ipairs(choices()) do known = known or name == choice end
      if not known then fail("%s: unknown %s '%s'", spec.name, param.name, choice) end
      args[i] = choice
    else
      args[i] = evaluate(arg, ctx)
      check(args[i], param.type, spec.name, i)
    end
  end
  return spec.fn(ctx, table.unpack(args, 1, given))
end

-- Returns the value, or nil and an error message.
function lang.evaluate(form, ctx)
  local ok, result = pcall(evaluate, form, ctx)
  if ok then return result end
  if type(result) == "table" and result.formula_error then return nil, result.formula_error end
  error(result, 0)
end

-- Raises a formula error from a ctx.group callback.
lang.fail = fail

-- Names of the groups a form reads, as a set.
function lang.groups_read(form, into)
  into = into or {}
  if sexp.is_list(form) then
    if sexp.is_sym(form[1], "group") and form[2] and (form[2].str or form[2].sym) then
      into[form[2].str or form[2].sym] = true
    end
    for _, child in ipairs(form) do lang.groups_read(child, into) end
  end
  return into
end

-- Bag from ItemWithQualityCount records, as LuaLogisticNetwork::get_contents returns.
function lang.bag_from_contents(contents)
  local bag = {}
  for _, item in pairs(contents) do add(bag, "item", item.name, item.quality or "normal", item.count) end
  return bag
end

-- Bag from the filters of a logistic section or group.
local function location_name(location)
  if location == nil then return nil end
  if type(location) == "string" then return location end
  return location.name
end

function lang.bag_from_filters(filters)
  local bag = {}
  for _, filter in pairs(filters) do
    local value = filter.value
    if value and value.name and (filter.min or 0) ~= 0 then
      add(bag, value.type or "item", value.name, value.quality or "normal", filter.min, {
        max = filter.max, import_from = location_name(filter.import_from),
        request_from = filter.request_from, min_delivery = filter.minimum_delivery_count,
      })
    end
  end
  return bag
end

-- Filters for a logistic section: counts rounded away from zero, largest first.
function lang.filters_from_bag(bag)
  local entries = {}
  for _, e in pairs(bag) do
    local count = e.count > 0 and math.ceil(e.count - 1e-9) or math.floor(e.count + 1e-9)
    count = math.max(-2147483647, math.min(2147483647, count))
    if count ~= 0 then entries[#entries + 1] = {e = e, count = count} end
  end
  table.sort(entries, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    if a.e.name ~= b.e.name then return a.e.name < b.e.name end
    if a.e.type ~= b.e.type then return a.e.type < b.e.type end
    return a.e.quality < b.e.quality
  end)
  local filters = {}
  for i, entry in ipairs(entries) do
    local e = entry.e
    local filter = {value = {type = e.type, name = e.name, quality = e.quality, comparator = "="}, min = entry.count}
    -- A limit below the request would be rejected; a negative request takes no limit.
    if e.max and entry.count > 0 then filter.max = math.max(entry.count, math.ceil(e.max - 1e-9)) end
    filter.import_from = e.import_from
    if e.request_from and e.request_from ~= "planet" then filter.request_from = e.request_from end
    if e.min_delivery and e.min_delivery > 0 then filter.minimum_delivery_count = math.ceil(e.min_delivery - 1e-9) end
    filters[i] = filter
  end
  return filters
end

-- One line per filter, for comparing what a group holds with what it should hold.
function lang.signature(filters)
  local parts = {}
  for i, filter in ipairs(filters) do
    local v = filter.value
    parts[i] = string.format("%s/%s/%s=%s<%s@%s~%s>%s", v.type, v.name, v.quality, filter.min, tostring(filter.max),
      tostring(location_name(filter.import_from)), tostring(filter.request_from or "planet"),
      tostring(filter.minimum_delivery_count or 0))
  end
  return table.concat(parts, "\n")
end

return lang
