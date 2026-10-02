local i18n = require("i18n-ts")

local M = {}

local function notify(msg, level)
  vim.notify("i18n-ts: " .. msg, level or vim.log.levels.INFO)
end

--- Parses `rg --json` output into locations.
function M.parse(output)
  local locations = {}
  for line in output:gmatch("[^\n]+") do
    local ok, item = pcall(vim.json.decode, line)
    if ok and type(item) == "table" and item.type == "match" then
      local data = item.data
      local sub = data.submatches and data.submatches[1]
      table.insert(locations, {
        file = data.path.text,
        line = data.line_number,
        col = sub and sub.start + 1 or 1,
        text = vim.trim((data.lines.text or ""):gsub("\n$", "")),
      })
    end
  end
  return locations
end

--- Quoted occurrences of `key` under the project root, translation files excluded.
--- `cb(err, locations)` runs on the main loop.
function M.search(project, key, cb)
  if vim.fn.executable("rg") ~= 1 then
    return cb("ripgrep (rg) is required for usages")
  end
  local cmd = { "rg", "--json", "--fixed-strings" }
  for _, q in ipairs({ "'", '"', "`" }) do
    vim.list_extend(cmd, { "-e", q .. key .. q })
  end
  for _, source in ipairs(project.store.sources) do
    vim.list_extend(cmd, { "-g", "!" .. source:gsub("{%a+}", "*") })
  end
  table.insert(cmd, ".")
  vim.system(cmd, { cwd = project.root, text = true }, function(res)
    vim.schedule(function()
      if res.code > 1 then
        return cb("rg failed: " .. (res.stderr or ""))
      end
      local locations = M.parse(res.stdout or "")
      for _, l in ipairs(locations) do
        l.file = vim.fs.normalize(project.root .. "/" .. l.file:gsub("^%./", ""))
      end
      cb(nil, locations)
    end)
  end)
end

function M.find(key)
  local project = i18n.require_project()
  if not project then
    return
  end
  key = (key and key ~= "") and key or i18n.key_at_cursor()
  if not key then
    return notify("no translation key under the cursor", vim.log.levels.WARN)
  end
  M.search(project, key, function(err, locations)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    if #locations == 0 then
      return notify(("no usage of '%s'"):format(key))
    end
    require("i18n-ts.picker").locations(("usages of %s"):format(key), locations)
  end)
end

return M
