-- S-expression reader and printer for group formulas.
--
-- Forms: a number is a Lua number, a string is {str = "..."}, a symbol is {sym = "..."},
-- and a list is an array of forms. `{iron-plate 100 water 5}` reads as the list
-- `(constant iron-plate 100 water 5)` and prints back with braces.
local sexp = {}

function sexp.sym(name) return {sym = name} end
function sexp.str(text) return {str = text} end
function sexp.is_sym(form, name) return type(form) == "table" and form.sym ~= nil and (name == nil or form.sym == name) end
function sexp.is_str(form) return type(form) == "table" and form.str ~= nil end
function sexp.is_list(form) return type(form) == "table" and form.sym == nil and form.str == nil end

local DELIMITER = "[%s%(%){}\";]"

local UNITS = {k = 1e3, m = 1e6, g = 1e9}

-- A number, also with a k, M or G suffix ("5k", "1.5M"); nil when the text is not one.
function sexp.parse_number(text)
  text = text:match("^%s*(.-)%s*$")
  local n = tonumber(text)
  if n then return n end
  local digits, unit = text:match("^([+-]?[%d.]+)%s*([kKmMgG])$")
  n = digits and tonumber(digits)
  if n then return n * UNITS[unit:lower()] end
end

-- Returns the array of top-level forms, or nil and "line N: message".
function sexp.parse(text)
  local pos, line = 1, 1
  local function fail(message) error({parse_error = "line " .. line .. ": " .. message}, 0) end

  local function skip()
    while pos <= #text do
      local c = text:sub(pos, pos)
      if c == "\n" then line = line + 1; pos = pos + 1
      elseif c:match("%s") then pos = pos + 1
      elseif c == ";" then
        while pos <= #text and text:sub(pos, pos) ~= "\n" do pos = pos + 1 end
      else break end
    end
  end

  local read
  local function read_until(close, list)
    while true do
      skip()
      if pos > #text then fail("missing " .. close) end
      if text:sub(pos, pos) == close then pos = pos + 1; return list end
      list[#list + 1] = read()
    end
  end

  function read()
    skip()
    local c = text:sub(pos, pos)
    if c == "(" then pos = pos + 1; return read_until(")", {})
    elseif c == "{" then pos = pos + 1; return read_until("}", {sexp.sym("constant")})
    elseif c == ")" or c == "}" then fail("unexpected " .. c)
    elseif c == '"' then
      local out = {}
      pos = pos + 1
      while true do
        if pos > #text then fail("unterminated string") end
        c = text:sub(pos, pos)
        if c == '"' then pos = pos + 1; break end
        if c == "\\" then pos = pos + 1; c = text:sub(pos, pos) end
        if c == "\n" then line = line + 1 end
        out[#out + 1] = c
        pos = pos + 1
      end
      return sexp.str(table.concat(out))
    end
    local start = pos
    while pos <= #text and not text:sub(pos, pos):match(DELIMITER) do pos = pos + 1 end
    local token = text:sub(start, pos - 1)
    return sexp.parse_number(token) or sexp.sym(token)
  end

  local forms = {}
  local ok, err = pcall(function()
    while true do
      skip()
      if pos > #text then break end
      forms[#forms + 1] = read()
    end
  end)
  if ok then return forms end
  if type(err) == "table" and err.parse_error then return nil, err.parse_error end
  error(err, 0)
end

local function number_text(n)
  if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
  return string.format("%.10g", n)
end

local function flat(form)
  if type(form) == "number" then return number_text(form) end
  if form.sym then return form.sym end
  if form.str then return '"' .. form.str:gsub('[\\"]', "\\%0") .. '"' end
  local parts = {}
  local braces = sexp.is_sym(form[1], "constant")
  for i = braces and 2 or 1, #form do parts[#parts + 1] = flat(form[i]) end
  local body = table.concat(parts, " ")
  return braces and "{" .. body .. "}" or "(" .. body .. ")"
end

local WIDTH = 80

-- One line when it fits, otherwise the head on the first line and one argument per line.
local function pretty(form, indent)
  local line = flat(form)
  if not sexp.is_list(form) or #line + #indent <= WIDTH or sexp.is_sym(form[1], "constant") or #form < 2 then return line end
  local inner = indent .. "  "
  local parts = {"(" .. flat(form[1])}
  local first = 2
  -- Keep a def's name beside the keyword.
  if sexp.is_sym(form[1], "def") and form[2] then parts[1] = parts[1] .. " " .. flat(form[2]); first = 3 end
  for i = first, #form do parts[#parts + 1] = inner .. pretty(form[i], inner) end
  return table.concat(parts, "\n") .. ")"
end

function sexp.print(form) return flat(form) end

-- Prints top-level forms one per paragraph.
function sexp.print_program(forms)
  local out = {}
  for _, form in ipairs(forms) do out[#out + 1] = pretty(form, "") end
  return table.concat(out, "\n")
end

return sexp
