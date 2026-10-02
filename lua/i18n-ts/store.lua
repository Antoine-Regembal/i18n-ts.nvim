local root_mod = require("i18n-ts.root")

local M = {}

local parsers = {}

function M.register_parser(ext, fn)
  parsers[ext] = fn
end

local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

local function flatten(tbl, prefix, out)
  for k, v in pairs(tbl) do
    local key = prefix and (prefix .. "." .. tostring(k)) or tostring(k)
    if type(v) == "table" then
      flatten(v, key, out)
    elseif v ~= nil then
      out[key] = tostring(v)
    end
  end
  return out
end

--- Maps every dotted path of pretty-printed JSON (one key per line) to its position, in one pass.
--- Objects also get their open/close lines, used to insert keys.
local function index_json(lines)
  local positions, objects = {}, {}
  local stack = {}
  local root = { open = 1, close = #lines, path = nil }
  for lnum, line in ipairs(lines) do
    local col, key, rest = line:match('^%s*()"([^"]*)"%s*:%s*(.*)$')
    if key then
      local path = #stack > 0 and (stack[#stack].path .. "." .. key) or key
      positions[path] = { lnum, col }
      local opener = rest:sub(1, 1)
      if opener == "{" or opener == "[" then
        local entry = { open = lnum, path = path }
        objects[path] = entry
        if rest:match("^[{%[]%s*[}%]]") then
          entry.close = lnum
        else
          table.insert(stack, entry)
        end
      end
    elseif line:match("^%s*[}%]]") and #stack > 0 then
      local entry = table.remove(stack)
      entry.close = lnum
    end
  end
  for i = #lines, 1, -1 do
    if lines[i]:match("^%s*}") then
      root.close = i
      break
    end
  end
  objects[""] = root
  return positions, objects
end

M.index_json = index_json

parsers.json = function(content)
  local ok, decoded = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" then
    return nil, "invalid JSON"
  end
  local lines = vim.split(content, "\n", { plain = true })
  local positions = index_json(lines)
  return flatten(decoded, nil, {}), positions
end

local function placeholder_pattern(source)
  local names = {}
  local pat = vim.pesc(source):gsub("{(%a+)}", function(name)
    table.insert(names, name)
    return "([^/]+)"
  end)
  return "^" .. pat .. "$", names
end

--- Lists files matching `sources` under root, with their locale and namespace.
function M.resolve_sources(root, sources)
  local files, seen = {}, {}
  for _, source in ipairs(sources) do
    local glob = source:gsub("{%a+}", "*")
    local pat, names = placeholder_pattern(source)
    for _, abs in ipairs(vim.fn.glob(root .. "/" .. glob, false, true)) do
      local rel = abs:sub(#root + 2)
      local caps = { rel:match(pat) }
      if #caps == #names and not seen[abs] then
        local file = { path = root_mod.real(abs), source = source }
        for i, name in ipairs(names) do
          file[name] = caps[i]
        end
        if file.locale then
          seen[abs] = true
          table.insert(files, file)
        end
      end
    end
  end
  return files
end

local function looks_like_locale(name)
  return name:match("^%a%a%a?$") ~= nil or name:match("^%a%a%a?[-_]%w%w+$") ~= nil
end

--- Finds locale directories without reading node_modules and friends.
function M.detect_sources(root, opts)
  local wanted, skip = {}, {}
  for _, n in ipairs(opts.dir_names) do
    wanted[n] = true
  end
  for _, n in ipairs(opts.skip) do
    skip[n] = true
  end
  local sources = {}
  local ok, iter = pcall(vim.fs.dir, root, {
    depth = opts.depth,
    skip = function(name)
      return not skip[name] and name:sub(1, 1) ~= "."
    end,
  })
  if not ok then
    return sources
  end
  for rel, kind in iter do
    if kind == "directory" and wanted[vim.fs.basename(rel)] then
      local files, dirs = 0, 0
      for name, k in vim.fs.dir(root .. "/" .. rel) do
        if k == "file" and name:match("%.json$") and looks_like_locale(name:gsub("%.json$", "")) then
          files = files + 1
        elseif k == "directory" and looks_like_locale(name) then
          if #vim.fn.glob(root .. "/" .. rel .. "/" .. name .. "/*.json", false, true) > 0 then
            dirs = dirs + 1
          end
        end
      end
      if files >= 1 and files >= dirs then
        table.insert(sources, rel .. "/{locale}.json")
      elseif dirs >= 1 then
        table.insert(sources, rel .. "/{locale}/{namespace}.json")
      end
    end
  end
  table.sort(sources)
  return sources
end

local function normalize_locale(locale)
  return locale:lower():gsub("_", "-")
end

--- Best locale in `locales` for `wanted`: exact (case and `_`/`-` insensitive), base language, same language, first.
function M.match_locale(wanted, locales)
  local target = normalize_locale(wanted or "")
  local base = target:match("^([^-]+)")
  local same_language
  for _, l in ipairs(locales) do
    local n = normalize_locale(l)
    if n == target then
      return l
    end
  end
  for _, l in ipairs(locales) do
    local n = normalize_locale(l)
    if n == base then
      return l
    elseif not same_language and n:match("^([^-]+)") == base then
      same_language = l
    end
  end
  return same_language or locales[1]
end

local Store = {}
Store.__index = Store

function M.new(root, cfg)
  local self = setmetatable({ root = root, cfg = cfg, errors = {} }, Store)
  self.sources = #cfg.sources > 0 and cfg.sources or M.detect_sources(root, cfg.auto_detect)
  self.detected = #cfg.sources == 0
  self:scan_files()
  return self
end

function Store:scan_files()
  self.files = M.resolve_sources(self.root, self.sources)
  self.by_path = {}
  local found = {}
  for _, f in ipairs(self.files) do
    self.by_path[f.path] = f
    found[f.locale] = true
  end
  local locales = {}
  if #self.cfg.locales > 0 then
    for _, l in ipairs(self.cfg.locales) do
      if found[l] then
        table.insert(locales, l)
      end
    end
  else
    for l in pairs(found) do
      table.insert(locales, l)
    end
    table.sort(locales)
  end
  self.default_locale = M.match_locale(self.cfg.default_locale, locales)
  for i, l in ipairs(locales) do
    if l == self.default_locale then
      table.insert(locales, 1, table.remove(locales, i))
      break
    end
  end
  self.locales = locales
  self.data, self.pos, self.mtime, self.loaded = {}, {}, {}, {}
end

function Store:has_files()
  return #self.files > 0
end

function Store:owns(path)
  return self.by_path[root_mod.real(path)] ~= nil
end

local function mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and (stat.mtime.sec * 1e9 + stat.mtime.nsec) or 0
end

function Store:key_for(file, key)
  if file.namespace then
    return file.namespace .. self.cfg.namespace_separator .. key
  end
  return key
end

function Store:load_file(file)
  local content = read_file(file.path)
  local ext = file.path:match("%.([^.]+)$")
  local parse = parsers[ext]
  self.errors[file.path] = nil
  if not content or not parse then
    self.errors[file.path] = content and ("no parser for ." .. tostring(ext)) or "unreadable"
    return
  end
  local values, positions = parse(content)
  if not values then
    self.errors[file.path] = positions
    return
  end
  local data = self.data[file.locale] or {}
  local pos = self.pos[file.locale] or {}
  for key, value in pairs(values) do
    local full = self:key_for(file, key)
    data[full] = value
    local p, parent = positions and positions[key], key
    while positions and not p and parent:find(".", 1, true) do
      parent = parent:match("^(.*)%.[^.]*$")
      p = positions[parent]
    end
    pos[full] = { path = file.path, line = p and p[1] or 1, col = p and p[2] or 1 }
  end
  self.data[file.locale], self.pos[file.locale] = data, pos
  self.mtime[file.path] = mtime(file.path)
end

function Store:load_locale(locale)
  self.data[locale], self.pos[locale] = {}, {}
  for _, f in ipairs(self.files) do
    if f.locale == locale then
      self:load_file(f)
    end
  end
  self.loaded[locale] = true
end

function Store:ensure(locale)
  if locale and not self.loaded[locale] then
    self:load_locale(locale)
  end
end

--- Loads the default locale now and the others one per event-loop tick.
function Store:load_async(on_done)
  self:ensure(self.default_locale)
  local pending = {}
  for _, l in ipairs(self.locales) do
    if not self.loaded[l] then
      table.insert(pending, l)
    end
  end
  local function step()
    local l = table.remove(pending, 1)
    if not l then
      if on_done then
        on_done()
      end
      return
    end
    self:ensure(l)
    vim.schedule(step)
  end
  vim.schedule(step)
end

function Store:reload_path(path)
  local file = self.by_path[root_mod.real(path)]
  if file and self.loaded[file.locale] then
    self:load_locale(file.locale)
  end
end

--- Reloads the locales whose files changed on disk; returns true when something changed.
function Store:refresh()
  local changed = false
  for _, f in ipairs(self.files) do
    if self.loaded[f.locale] and self.mtime[f.path] ~= mtime(f.path) then
      self:load_locale(f.locale)
      changed = true
    end
  end
  return changed
end

function Store:resolve(key, locale)
  locale = locale or self.default_locale
  self:ensure(locale)
  local data = self.data[locale] or {}
  if data[key] then
    return key
  end
  local ns = self.cfg.default_namespace
  if ns then
    local prefixed = ns .. self.cfg.namespace_separator .. key
    if data[prefixed] then
      return prefixed
    end
  end
end

function Store:get(key, locale)
  locale = locale or self.default_locale
  local resolved = self:resolve(key, locale)
  return resolved and self.data[locale][resolved]
end

function Store:position(key, locale)
  locale = locale or self.default_locale
  local resolved = self:resolve(key, locale)
  return resolved and self.pos[locale][resolved]
end

function Store:keys(locale)
  locale = locale or self.default_locale
  self:ensure(locale)
  local keys = vim.tbl_keys(self.data[locale] or {})
  table.sort(keys)
  return keys
end

--- File that should receive `key` for `locale`, plus the key relative to that file.
function Store:target(key, locale)
  local sep = self.cfg.namespace_separator
  local fallback
  for _, f in ipairs(self.files) do
    if f.locale == locale then
      if f.namespace then
        local prefix = f.namespace .. sep
        if key:sub(1, #prefix) == prefix then
          return f, key:sub(#prefix + 1)
        elseif self.cfg.default_namespace == f.namespace then
          fallback = f
        end
      else
        return f, key
      end
    end
  end
  if fallback then
    return fallback, key
  end
end

return M
