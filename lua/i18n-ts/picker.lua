local i18n = require("i18n-ts")
local display = require("i18n-ts.display")

local M = {}

local function items(project)
  local store = project.store
  local list = {}
  for _, key in ipairs(store:keys(project.locale)) do
    local pos = store:position(key, project.locale)
    table.insert(list, {
      text = key .. " " .. store:get(key, project.locale),
      key = key,
      value = display.format(store:get(key, project.locale), 80),
      file = pos and pos.path,
      pos = pos and { pos.line, pos.col - 1 },
    })
  end
  return list
end

local function insert_key(key)
  vim.api.nvim_put({ key }, "c", true, true)
end

--- Searches keys and translations of the displayed locale. <CR> jumps, <C-e> edits, <C-y> yanks, <A-i> inserts the key.
function M.keys()
  local project = i18n.require_project()
  if not project then
    return
  end
  local list = items(project)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    snacks.picker.pick({
      title = ("i18n keys (%s)"):format(project.locale),
      items = list,
      format = function(item)
        return { { item.key, "Identifier" }, { "  " }, { item.value, "I18nTsTranslation" } }
      end,
      confirm = function(picker, item)
        picker:close()
        if item and item.file then
          require("i18n-ts.navigation").jump({ path = item.file, line = item.pos[1], col = item.pos[2] + 1 })
        end
      end,
      actions = {
        i18n_yank = function(picker, item)
          picker:close()
          vim.fn.setreg(vim.v.register, item.key)
        end,
        i18n_edit = function(picker, item)
          picker:close()
          vim.schedule(function()
            require("i18n-ts.editor").open(project, item.key)
          end)
        end,
        i18n_insert = function(picker, item)
          picker:close()
          vim.schedule(function()
            insert_key(item.key)
          end)
        end,
      },
      win = {
        input = {
          keys = {
            ["<c-y>"] = { "i18n_yank", mode = { "n", "i" } },
            ["<a-i>"] = { "i18n_insert", mode = { "n", "i" } },
            ["<c-e>"] = { "i18n_edit", mode = { "n", "i" } },
          },
        },
      },
    })
    return
  end
  vim.ui.select(list, {
    prompt = "i18n keys",
    format_item = function(item)
      return item.key .. "  " .. item.value
    end,
  }, function(item)
    if item and item.file then
      require("i18n-ts.navigation").jump({ path = item.file, line = item.pos[1], col = item.pos[2] + 1 })
    end
  end)
end

--- Shows file locations; snacks picker when available, quickfix otherwise.
function M.locations(title, locations)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    local list = {}
    for _, l in ipairs(locations) do
      table.insert(list, { text = l.file .. " " .. l.text, file = l.file, pos = { l.line, l.col - 1 }, line = l.text })
    end
    snacks.picker.pick({ title = title, items = list, format = "file" })
    return
  end
  local qf = {}
  for _, l in ipairs(locations) do
    table.insert(qf, { filename = l.file, lnum = l.line, col = l.col, text = l.text })
  end
  vim.fn.setqflist({}, " ", { title = title, items = qf })
  vim.cmd.copen()
end

return M
