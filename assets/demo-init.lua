-- Minimal config used by the assets/*.tape recordings:
--   NVIM_APPNAME=i18n-ts-demo DEMO=<name> nvim -u <repo>/assets/demo-init.lua <file>
-- Translations come from a canned demo provider: no API call is made.
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    "https://github.com/folke/lazy.nvim.git",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "
vim.o.termguicolors = true
vim.o.laststatus = 3
vim.o.statusline = " "
vim.o.cmdheight = 1
vim.o.showmode = false
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.fillchars = "eob: "
vim.o.swapfile = false
vim.diagnostic.config({ virtual_text = { prefix = "●" }, signs = true })

local canned = {
  ["Free shipping over $50"] = {
    de = "Kostenloser Versand ab 50 $",
    es = "Envío gratis a partir de 50 $",
    fr = "Livraison gratuite dès 50 $",
    it = "Spedizione gratuita oltre 50 $",
    ja = "50ドル以上で送料無料",
  },
  ["Free shipping on orders over $50"] = {
    de = "Kostenloser Versand für Bestellungen über 50 $",
    es = "Envío gratis en pedidos de más de 50 $",
    fr = "Livraison gratuite pour toute commande de plus de 50 $",
    it = "Spedizione gratuita per ordini oltre 50 $",
    ja = "50ドル以上のご注文で送料無料",
  },
  ["Continue shopping"] = { ja = "買い物を続ける" },
}

local function demo_provider(request, callback)
  vim.defer_fn(function()
    local known = canned[request.source] or {}
    local result = {}
    for _, locale in ipairs(request.targets) do
      result[locale] = known[locale] or ("[" .. locale .. "] " .. request.source)
    end
    callback(nil, result)
  end, 2500)
end

require("lazy").setup({
  {
    "folke/tokyonight.nvim",
    priority = 1000,
    config = function()
      vim.cmd.colorscheme("tokyonight-night")
    end,
  },
  {
    "folke/snacks.nvim",
    opts = { picker = { enabled = true }, input = { enabled = true }, notifier = { enabled = true } },
  },
  {
    "saghen/blink.cmp",
    version = "1.*",
    opts = {
      keymap = { preset = "enter" },
      sources = {
        default = { "i18n", "buffer" },
        providers = { i18n = { name = "i18n", module = "i18n-ts.blink" } },
      },
      completion = { documentation = { auto_show = true, auto_show_delay_ms = 0 } },
    },
  },
  {
    dir = repo,
    name = "i18n-ts.nvim",
    lazy = false,
    opts = { translate = { provider = demo_provider } },
    keys = {
      { "<leader>Ik", "<cmd>I18n keys<cr>" },
      { "<leader>Ie", "<cmd>I18n edit<cr>" },
      { "<leader>Is", "<cmd>I18n show<cr>" },
      { "<leader>In", "<cmd>I18n next<cr>" },
      {
        "gd",
        function()
          require("i18n-ts").definition()
        end,
      },
    },
  },
}, { install = { colorscheme = { "tokyonight" } }, change_detection = { enabled = false } })

-- Recording overlays: a caption bar explaining each step, and the keys being pressed.

local demos = {
  inline = {
    {
      title = "i18n-ts.nvim: translations right where you use them",
      sub = "Every t('key') shows its value; missing keys are diagnostics",
    },
    { keys = "<Space>In", title = "Switch the displayed locale", sub = ":I18n next cycles through every locale" },
    { keys = "<Space>Is", title = "The key in every locale", sub = ":I18n show opens a float with all translations" },
    { keys = "gd", title = "Go to definition", sub = "Jumps to the exact line in the locale file" },
    { keys = "<C-O>", title = "And back", sub = "Root and locale files are detected, no configuration" },
  },
  edit = {
    { title = "Edit a key in every locale from one float", sub = "Cursor on t('cart.checkout')" },
    { keys = "<Space>Ie", title = ":I18n edit", sub = "One line per locale, the default one first, keys listed below" },
    {
      keys = "cc",
      title = "Edit the value like any text",
      sub = "Lines can't be deleted or added, only the values change",
    },
    { keys = "<Tab>", title = "<Tab> moves to the next locale", sub = "Unsaved lines are marked ● modified" },
    { keys = ":w", title = ":w writes every changed locale file", sub = "Key order and indentation are kept" },
    { keys = "q", title = "The inline preview follows", sub = "Locale files are reloaded on save" },
  },
  translate = {
    {
      title = "Machine-translate from the default locale",
      sub = "cart.free_shipping is missing everywhere (demo provider, canned answers)",
    },
    { keys = "<Space>Ie", title = "Open the key", sub = "Every locale is missing" },
    { keys = "A", title = "Type the en-US value", sub = "Only the default locale is needed" },
    {
      keys = "<CR>",
      title = "Save and close: translation runs in the background",
      sub = "Live indicator on the key while the empty locales are translated",
    },
    {
      keys = "<Space>Is",
      title = "Every locale is filled",
      sub = "Claude Code, Claude API, DeepL or your own command",
    },
    { keys = "<Space>Ie", title = "Changed the source text?", sub = "gT re-translates every locale from en-US" },
    {
      keys = "gT",
      title = "Re-translate all, after confirmation",
      sub = "gT or :I18n retranslate. Loaders on every line until the result lands",
    },
  },
  picker = {
    { title = "Search every key and translation", sub = "snacks.nvim picker, vim.ui.select without it" },
    { keys = "<Space>Ik", title = ":I18n keys", sub = "Fuzzy search on keys and values, file preview" },
    { keys = "<CR>", title = "Jump to the definition", sub = "<C-e> edits, <C-y> yanks, <A-i> inserts the key" },
    { keys = "<C-O>", title = "Remove a key from every locale", sub = "<C-x> in the picker, with a confirmation" },
    { keys = "<C-X>", title = "Confirm", sub = "Warns first when the code still uses the key" },
  },
  completion = {
    { title = "Complete keys inside t('…')", sub = "blink.cmp source, every locale in the documentation" },
    { keys = "o", title = "Start a translation call", sub = "Keys are offered only inside t(), $t(), te()…" },
    {
      keys = "<CR>",
      title = "Accept: the translation shows at once",
      sub = 'Add the source with module = "i18n-ts.blink"',
    },
  },
}

local steps = demos[vim.env.DEMO or "inline"] or demos.inline

local labels = {
  ["<Space>In"] = "Next locale",
  ["<Space>Is"] = "Show all locales",
  ["<Space>Ie"] = "Edit key",
  ["<Space>Ik"] = "Search keys",
  ["gd"] = "Definition",
  ["<C-O>"] = "Back",
  ["<Tab>"] = "Next locale",
  ["gT"] = "Re-translate all",
  ["<C-X>"] = "Remove key",
  [":w"] = "Save",
  ["<CR>"] = "Enter",
  ["q"] = "Close",
}

local pretty = {
  ["<Space>"] = "Space",
  ["<CR>"] = "Enter",
  ["<BS>"] = "Backspace",
  ["<Down>"] = "↓",
  ["<Esc>"] = "Esc",
  ["<Tab>"] = "Tab",
  ["<C-O>"] = "Ctrl-o",
  ["<C-X>"] = "Ctrl-x",
}

local ns = vim.api.nvim_create_namespace("i18n_ts_demo")
vim.api.nvim_set_hl(0, "DemoCaption", { link = "NormalFloat" })
vim.api.nvim_set_hl(0, "DemoTitle", { link = "Title" })
vim.api.nvim_set_hl(0, "DemoSub", { link = "Comment" })
vim.api.nvim_set_hl(0, "DemoKey", { link = "Search" })
vim.api.nvim_set_hl(0, "DemoKeyLabel", { link = "Special" })

-- An empty split reserves the space, a float above everything draws the caption
local main_win = vim.api.nvim_get_current_win()
vim.cmd("topleft 3split")
local caption_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(caption_win, vim.api.nvim_create_buf(false, true))
vim.wo[caption_win].winfixheight = true
vim.wo[caption_win].number = false
vim.wo[caption_win].signcolumn = "no"
vim.wo[caption_win].winhighlight = "Normal:DemoCaption"
vim.api.nvim_set_current_win(main_win)

local caption_buf = vim.api.nvim_create_buf(false, true)
local caption_float = vim.api.nvim_open_win(caption_buf, false, {
  relative = "editor",
  row = 0,
  col = 0,
  width = vim.o.columns,
  height = 3,
  style = "minimal",
  focusable = false,
  zindex = 300,
})
vim.wo[caption_float].winhighlight = "Normal:DemoCaption"
local function leave_caption()
  if vim.api.nvim_get_current_win() == caption_win and vim.api.nvim_win_is_valid(main_win) then
    vim.api.nvim_set_current_win(main_win)
  end
end
vim.api.nvim_create_autocmd("WinEnter", { callback = leave_caption })
-- Files given on the command line are opened after this config, and may leave the focus on the caption split.
vim.api.nvim_create_autocmd("VimEnter", { callback = vim.schedule_wrap(leave_caption) })

local step = 1

local function render_caption()
  local s = steps[step]
  local counter = ("%d/%d"):format(step, #steps)
  local lines = { "  " .. s.title .. "   " .. counter, "  " .. s.sub, "" }
  vim.api.nvim_buf_set_lines(caption_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(caption_buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(caption_buf, ns, 0, 0, { end_col = #s.title + 2, hl_group = "DemoTitle" })
  vim.api.nvim_buf_set_extmark(caption_buf, ns, 0, #s.title + 2, { end_col = #lines[1], hl_group = "DemoSub" })
  vim.api.nvim_buf_set_extmark(caption_buf, ns, 1, 0, { end_col = #lines[2], hl_group = "DemoSub" })
end
render_caption()

local key_buf = vim.api.nvim_create_buf(false, true)
local key_win

local function render_keys(seq, label)
  local shown = {}
  local rest = seq
  while #rest > 0 do
    local token = rest:match("^<[^>]+>") or rest:sub(1, 1)
    shown[#shown + 1] = pretty[token] or token
    rest = rest:sub(#token + 1)
  end
  local keys = " " .. table.concat(shown, " ") .. " "
  if vim.fn.strdisplaywidth(keys) > 30 then
    keys = " …" .. vim.fn.strcharpart(keys, vim.fn.strchars(keys) - 28)
  end
  local text = label and (keys .. "  " .. label .. " ") or keys
  vim.api.nvim_buf_set_lines(key_buf, 0, -1, false, { text })
  vim.api.nvim_buf_clear_namespace(key_buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(key_buf, ns, 0, 0, { end_col = #keys, hl_group = "DemoKey" })
  if label then
    vim.api.nvim_buf_set_extmark(key_buf, ns, 0, #keys, { end_col = #text, hl_group = "DemoKeyLabel" })
  end
  local width = vim.fn.strdisplaywidth(text)
  local config = {
    relative = "editor",
    row = vim.o.lines - 4,
    col = vim.o.columns - width - 3,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 300,
  }
  if key_win and vim.api.nvim_win_is_valid(key_win) then
    vim.api.nvim_win_set_config(key_win, config)
  else
    key_win = vim.api.nvim_open_win(key_buf, false, config)
  end
end

local seq, last = "", 0

vim.on_key(function(_, typed)
  -- Only keys actually typed: commands run by plugins (`normal! m'`…) are not shown.
  if typed == nil or typed == "" then
    return
  end
  local k = vim.fn.keytrans(typed)
  if k == "" or k:match("^<Cmd>") or k:match("^<.*Mouse") or k:match("^<Ignore>") then
    return
  end
  local now = vim.uv.now()
  if now - last > 1000 then
    seq = ""
  end
  last = now
  seq = seq .. k
  vim.schedule(function()
    local label, matched
    for combo, l in pairs(labels) do
      if vim.endswith(seq, combo) and (not matched or #combo > #matched) then
        label, matched = l, combo
      end
    end
    local next_step = steps[step + 1]
    if next_step and next_step.keys and vim.endswith(seq, next_step.keys) then
      step = step + 1
      render_caption()
    end
    render_keys(matched or seq, label)
  end)
end, ns)
