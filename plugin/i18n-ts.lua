if vim.g.loaded_i18n_ts then
  return
end
vim.g.loaded_i18n_ts = true

vim.api.nvim_create_user_command("I18n", function(cmd)
  local sub = cmd.fargs[1] or "info"
  local fn = require("i18n-ts").subcommands[sub]
  if not fn then
    vim.notify("i18n-ts: unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
    return
  end
  fn(cmd.fargs[2])
end, {
  nargs = "*",
  desc = "i18n-ts",
  complete = function(arg, line)
    local words = vim.split(line, "%s+", { trimempty = true })
    local position = #words + (arg == "" and 1 or 0)
    local candidates
    if position == 2 then
      candidates = vim.tbl_keys(require("i18n-ts").subcommands)
      table.sort(candidates)
    elseif position == 3 and words[2] == "locale" then
      candidates = require("i18n-ts").locales()
    else
      return {}
    end
    return vim.tbl_filter(function(s)
      return s:find(arg, 1, true) == 1
    end, candidates)
  end,
})
