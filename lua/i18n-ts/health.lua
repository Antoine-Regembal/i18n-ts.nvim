local M = {}

function M.check()
  local h = vim.health
  local i18n = require("i18n-ts")
  h.start("i18n-ts")
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim >= 0.10")
  else
    h.error("Neovim >= 0.10 is required")
  end
  if vim.fn.executable("rg") == 1 then
    h.ok("ripgrep found (usages)")
  else
    h.warn("ripgrep not found: :I18n usages is unavailable")
  end
  h.info(pcall(require, "snacks") and "snacks.nvim found (pickers)" or "snacks.nvim not found: vim.ui.select is used")
  h.info(pcall(require, "blink.cmp") and "blink.cmp found (completion source: i18n-ts.blink)" or "blink.cmp not found")

  h.start("i18n-ts: current buffer")
  local project = i18n.project(0)
  if not project then
    h.warn("no translation files found from this buffer's root; set `sources` or add a .i18n-ts.json")
    return
  end
  local store = project.store
  h.ok("root: " .. project.root)
  h.info("sources: " .. table.concat(store.sources, ", ") .. (store.detected and " (auto-detected)" or ""))
  h.info(("%d file(s), locales: %s"):format(#store.files, table.concat(store.locales, ", ")))
  local count = #store:keys(store.default_locale)
  if count > 0 then
    h.ok(("%d keys in %s"):format(count, store.default_locale))
  else
    h.warn("no keys loaded for " .. tostring(store.default_locale))
  end
  for path, err in pairs(store.errors) do
    h.error(vim.fn.fnamemodify(path, ":~:.") .. ": " .. err)
  end

  h.start("i18n-ts: machine translation")
  local t = project.cfg.translate
  if not t.provider then
    h.info("off (set translate.provider to enable it)")
    return
  end
  h.info(
    ("provider: %s, source locale: %s, auto: %s"):format(
      require("i18n-ts.translate").label(t),
      tostring(store.default_locale),
      tostring(t.auto)
    )
  )
  local env = (t.provider == "anthropic" and t.anthropic.api_key_env) or (t.provider == "deepl" and t.deepl.api_key_env)
  if env then
    if vim.env[env] and vim.env[env] ~= "" then
      h.ok(env .. " is set")
    else
      h.error(env .. " is not set")
    end
    if vim.fn.executable("curl") == 1 then
      h.ok("curl found")
    else
      h.error("curl is required for the " .. t.provider .. " provider")
    end
  end
end

return M
