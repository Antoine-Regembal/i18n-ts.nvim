local i18n = require("i18n-ts")
local display = require("i18n-ts.display")

local M = {}

local function notify(msg, level)
  vim.notify("i18n-ts: " .. msg, level or vim.log.levels.INFO)
end

function M.jump(pos)
  vim.cmd("normal! m'")
  vim.cmd.edit(vim.fn.fnameescape(pos.path))
  vim.api.nvim_win_set_cursor(0, { pos.line, math.max(pos.col - 1, 0) })
end

--- Jumps to the key under the cursor in the displayed locale, falling back to the default one.
---@return boolean found
function M.definition()
  local key, project = i18n.key_at_cursor()
  if not key then
    return false
  end
  local store = project.store
  local pos = store:position(key, project.locale) or store:position(key, store.default_locale)
  if not pos then
    notify(("'%s' is missing, :I18n add to create it"):format(key), vim.log.levels.WARN)
    return true
  end
  M.jump(pos)
  return true
end

function M.show()
  local key, project = i18n.key_at_cursor()
  if not key then
    notify("no translation key under the cursor", vim.log.levels.WARN)
    return
  end
  local store = project.store
  local width = 0
  for _, l in ipairs(store.locales) do
    width = math.max(width, #l)
  end
  local lines = { "**" .. key .. "**", "" }
  for _, l in ipairs(store.locales) do
    local value = store:get(key, l)
    table.insert(
      lines,
      ("`%s`  %s"):format(l .. string.rep(" ", width - #l), value and display.format(value, 120) or "_missing_")
    )
  end
  vim.lsp.util.open_floating_preview(lines, "markdown", { border = "rounded", focus_id = "i18n-ts" })
end

local function prompt_values(store, key, cb)
  local cfg = store.cfg.add
  local values, i = {}, 0
  local locales = store.locales
  local function ask()
    i = i + 1
    local locale = locales[i]
    if not locale then
      return cb(values)
    end
    if store:get(key, locale) then
      return ask()
    end
    local default = values[store.default_locale] or ""
    if cfg.prompt == "default" and locale ~= store.default_locale then
      values[locale] = values[store.default_locale]
      return ask()
    end
    vim.ui.input({ prompt = ("%s [%s]: "):format(key, locale), default = default }, function(input)
      if input == nil then
        return notify("cancelled, nothing written")
      end
      if input ~= "" then
        values[locale] = input
      end
      ask()
    end)
  end
  ask()
end

--- Adds a key (argument, or the missing key under the cursor) to every locale.
function M.add(key)
  local project = i18n.require_project()
  if not project then
    return
  end
  if not key or key == "" then
    key = i18n.key_at_cursor()
  end
  local function run(k)
    if not k or k == "" then
      return
    end
    prompt_values(project.store, k, function(values)
      if vim.tbl_isempty(values) then
        return notify("no value given, nothing written")
      end
      local written, errors = require("i18n-ts.edit").add(project.store, k, values)
      local fmt = project.cfg.add.format_cmd
      if fmt and #written > 0 then
        vim.system(vim.list_extend(vim.deepcopy(fmt), written), { cwd = project.root }):wait()
        for _, path in ipairs(written) do
          project.store:reload_path(path)
        end
      end
      i18n.refresh_project(project)
      local msg = ("added '%s' to %d file(s)"):format(k, #written)
      for locale, err in pairs(errors) do
        msg = msg .. ("\n%s: %s"):format(locale, err)
      end
      notify(msg, next(errors) and vim.log.levels.WARN or vim.log.levels.INFO)
    end)
  end
  if key then
    run(key)
  else
    vim.ui.input({ prompt = "New key: " }, run)
  end
end

return M
