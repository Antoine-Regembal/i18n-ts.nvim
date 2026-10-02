local i18n = require("i18n-ts")
local scanner = require("i18n-ts.scanner")
local display = require("i18n-ts.display")

--- blink.cmp source: keys inside a translation call, e.g. t('common.|').
local source = {}

function source.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = source })
end

function source:enabled()
  return i18n.is_attached(0)
end

function source:get_trigger_characters()
  return { "'", '"', "." }
end

function source:get_completions(ctx, callback)
  local project = i18n.project(ctx.bufnr)
  local row, col = ctx.cursor[1], ctx.cursor[2]
  local context = project and scanner.context(ctx.line:sub(1, col), project.cfg.functions)
  if not context then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end
  local store = project.store
  local kind = require("blink.cmp.types").CompletionItemKind.Text
  local range = {
    start = { line = row - 1, character = context.start },
    ["end"] = { line = row - 1, character = col },
  }
  local items = {}
  for _, key in ipairs(store:keys(project.locale)) do
    table.insert(items, {
      label = key,
      kind = kind,
      filterText = key,
      labelDetails = { description = display.format(store:get(key, project.locale), 40) },
      textEdit = { newText = key, range = range },
      data = { key = key, root = project.root },
    })
  end
  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

function source:resolve(item, callback)
  local project = item.data and i18n.projects[item.data.root]
  if project then
    local lines = {}
    for _, l in ipairs(project.store.locales) do
      local value = project.store:get(item.data.key, l)
      table.insert(lines, ("`%s` %s"):format(l, value and display.format(value, 200) or "_missing_"))
    end
    item = vim.tbl_extend("force", item, { documentation = { kind = "markdown", value = table.concat(lines, "  \n") } })
  end
  callback(item)
end

return source
