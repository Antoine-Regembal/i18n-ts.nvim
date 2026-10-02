local store_mod = require("i18n-ts.store")

local M = {}

local function detect_indent(lines)
  for _, line in ipairs(lines) do
    local ws = line:match('^(%s+)"')
    if ws then
      return ws
    end
  end
  return "  "
end

local function leading(line)
  return line:match("^(%s*)") or ""
end

--- Returns `lines` with `key` (dotted, relative to the file) set to `value`, keeping order and layout.
---@return string[]|nil lines, string|nil err
function M.insert(lines, key, value)
  local positions, objects = store_mod.index_json(lines)
  if positions[key] then
    return nil, "key already exists"
  end
  local segments = vim.split(key, ".", { plain = true })
  local parent_path, depth = "", 0
  for i = 1, #segments - 1 do
    local candidate = table.concat(segments, ".", 1, i)
    if objects[candidate] then
      parent_path, depth = candidate, i
    elseif positions[candidate] then
      return nil, ("'%s' is a value, not an object"):format(candidate)
    else
      break
    end
  end
  local parent = objects[parent_path]
  if not parent or not parent.close then
    return nil, "cannot locate the parent object"
  end
  local unit = detect_indent(lines)
  local base = parent_path == "" and "" or leading(lines[parent.open])
  local new = {}
  local indent = base .. unit
  for i = depth + 1, #segments - 1 do
    table.insert(new, ("%s%s: {"):format(indent, vim.json.encode(segments[i])))
    indent = indent .. unit
  end
  table.insert(new, ("%s%s: %s"):format(indent, vim.json.encode(segments[#segments]), vim.json.encode(value)))
  for _ = depth + 1, #segments - 1 do
    indent = indent:sub(1, #indent - #unit)
    table.insert(new, indent .. "}")
  end

  local out = vim.list_slice(lines, 1, #lines)
  local close = parent.close
  if parent.open == close then
    -- `"x": {}` on one line: open it up.
    local line = out[close]
    local head, tail = line:match("^(.-){%s*}(.*)$")
    if not head then
      return nil, "unsupported one-line object"
    end
    table.remove(out, close)
    table.insert(out, close, head .. "{")
    for i, l in ipairs(new) do
      table.insert(out, close + i, l)
    end
    table.insert(out, close + #new + 1, leading(line) .. "}" .. tail)
  else
    local prev = close - 1
    while prev > parent.open and out[prev]:match("^%s*$") do
      prev = prev - 1
    end
    if prev > parent.open and not out[prev]:match(",%s*$") then
      out[prev] = out[prev]:gsub("%s*$", "") .. ","
    end
    for i, l in ipairs(new) do
      table.insert(out, prev + i, l)
    end
  end

  local ok = pcall(vim.json.decode, table.concat(out, "\n"))
  if not ok then
    return nil, "result would not be valid JSON"
  end
  return out
end

--- Returns `lines` with the string value of `key` replaced, keeping the line's layout.
---@return string[]|nil lines, string|nil err
function M.replace(lines, key, value)
  local positions, objects = store_mod.index_json(lines)
  local pos = positions[key]
  if not pos then
    return nil, "key not found"
  end
  if objects[key] then
    return nil, ("'%s' is not a string"):format(key)
  end
  local line = lines[pos[1]]
  local head, literal, tail = line:match('^(%s*"[^"]*"%s*:%s*)(".*")(%s*,?%s*)$')
  local ok, old = pcall(vim.json.decode, literal or "")
  if not head or not ok or type(old) ~= "string" then
    return nil, ("'%s' is not a one-line string"):format(key)
  end
  local out = vim.list_slice(lines, 1, #lines)
  out[pos[1]] = head .. vim.json.encode(value) .. tail
  if not pcall(vim.json.decode, table.concat(out, "\n")) then
    return nil, "result would not be valid JSON"
  end
  return out
end

local function read_lines(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    if vim.bo[bufnr].modified then
      return nil, "has unsaved changes"
    end
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
  end
  local fd = io.open(path, "r")
  if not fd then
    return nil, "unreadable"
  end
  local content = fd:read("*a")
  fd:close()
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function write_lines(path, lines, bufnr)
  if type(bufnr) == "number" then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent noautocmd write")
    end)
    return true
  end
  local fd = io.open(path, "w")
  if not fd then
    return false
  end
  fd:write(table.concat(lines, "\n") .. "\n")
  fd:close()
  return true
end

local function apply(store, key, values, opts)
  local written, errors = {}, {}
  for _, locale in ipairs(store.locales) do
    local value = values[locale]
    if value ~= nil and value ~= "" and value ~= store:get(key, locale) then
      local file, rel = store:target(key, locale)
      if not file then
        errors[locale] = "no file for this key"
      else
        local lines, bufnr = read_lines(file.path)
        if not lines then
          errors[locale] = vim.fn.fnamemodify(file.path, ":~:.") .. " " .. bufnr
        else
          local exists = opts.update and store_mod.index_json(lines)[rel]
          local out, err
          if exists then
            out, err = M.replace(lines, rel, value)
          else
            out, err = M.insert(lines, rel, value)
          end
          if not out then
            errors[locale] = err
          elseif write_lines(file.path, out, bufnr) then
            table.insert(written, file.path)
          else
            errors[locale] = "write failed"
          end
        end
      end
    end
  end
  for _, path in ipairs(written) do
    store:reload_path(path)
  end
  return written, errors
end

--- Adds `key` to every locale given in `values`; existing keys are reported as errors.
function M.add(store, key, values)
  return apply(store, key, values, { update = false })
end

--- Sets `key` to `values[locale]`: replaces existing values, adds missing ones, skips empty or unchanged ones.
function M.set(store, key, values)
  return apply(store, key, values, { update = true })
end

return M
