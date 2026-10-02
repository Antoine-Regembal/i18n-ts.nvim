# i18n-ts.nvim

See your translations where you use them. A fast, dependency-free Neovim plugin for TypeScript / JavaScript projects using JSON translation files: vue-i18n, i18next / react-i18next, next-intl, nuxt-i18n, or your own `t()`.

## Features

- Translation shown next to every `t('key')`, `$t("key")`, `i18n.global.t(...)` call, for the visible lines only
- Diagnostics for keys missing in the default locale (optionally in every locale)
- Go to definition: jump from a key to its exact line in the translation file
- Float with the key in every locale, and a command to switch the displayed locale
- Completion of keys inside `t('…')` with [blink.cmp](https://github.com/Saghen/blink.cmp), all locales in the documentation
- Picker over every key and translation ([snacks.nvim](https://github.com/folke/snacks.nvim), `vim.ui.select` without it)
- Add a key to every locale file at once, keeping key order and indentation
- Find the usages of a key with ripgrep
- Zero config for the usual layouts: the project root and the translation files are detected

Large projects stay fast: loading 13 locales of ~2,900 keys takes under 100 ms, and rendering a buffer under 1 ms. Translation files are indexed in a single pass, and locales other than the default one load in the background.

## Requirements

- Neovim >= 0.10
- Optional: [ripgrep](https://github.com/BurntSushi/ripgrep) for `:I18n usages`
- Optional: snacks.nvim (pickers), blink.cmp (completion)

## Installation

<details open>
<summary><b>LazyVim / lazy.nvim</b></summary>

`lua/plugins/i18n-ts.lua`:

```lua
return {
  {
    "Antoine-Regembal/i18n-ts.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {},
    keys = {
      { "<leader>Ik", "<cmd>I18n keys<cr>", desc = "i18n: keys" },
      { "<leader>Is", "<cmd>I18n show<cr>", desc = "i18n: all locales" },
      { "<leader>In", "<cmd>I18n next<cr>", desc = "i18n: next locale" },
      { "<leader>Ia", "<cmd>I18n add<cr>", desc = "i18n: add key" },
      { "<leader>Iu", "<cmd>I18n usages<cr>", desc = "i18n: usages" },
      { "<leader>It", "<cmd>I18n toggle<cr>", desc = "i18n: toggle" },
      {
        "gd",
        function()
          if not require("i18n-ts").definition() then
            vim.lsp.buf.definition()
          end
        end,
        ft = { "vue", "typescript", "javascript", "typescriptreact", "javascriptreact", "svelte" },
        desc = "Goto definition (i18n key or LSP)",
      },
    },
  },
  {
    "saghen/blink.cmp",
    optional = true,
    opts = {
      sources = {
        default = { "i18n" },
        providers = { i18n = { name = "i18n", module = "i18n-ts.blink" } },
      },
    },
  },
}
```

</details>

<details>
<summary><b>Any other plugin manager</b></summary>

Add `Antoine-Regembal/i18n-ts.nvim` to your runtime path and call:

```lua
require("i18n-ts").setup({})
```

</details>

Run `:checkhealth i18n-ts` from a source file to see the detected root, translation files, locales and key count.

## How the project is found

1. **Root.** The first of `root_markers` found upwards from the buffer: `.i18n-ts.json`, then `.git`, then `package.json`. In a monorepo the git root wins, so the translation files of every package are found from any file.
2. **Translation files.** Use `sources` when set. Otherwise the plugin looks for directories named `locales`, `locale`, `i18n`, `lang`, `langs`, `messages` or `translations`, up to 4 levels deep, skipping `node_modules`, `dist`, `build` and hidden directories:
   - `<dir>/en.json`, `<dir>/fr.json`, … gives `<dir>/{locale}.json`;
   - `<dir>/en/common.json`, … gives `<dir>/{locale}/{namespace}.json`.
3. **Locales.** Use `locales` when set. Otherwise every locale found, sorted, with `default_locale` first.

## Configuration

Defaults:

```lua
require("i18n-ts").setup({
  root_markers = { ".i18n-ts.json", ".git", "package.json" },
  -- Relative to the root. `{locale}` is required, `{namespace}` optional. Empty: auto-detected.
  sources = {},
  -- Empty: every locale found, `default_locale` first.
  locales = {},
  default_locale = "en",
  -- Keys of `{namespace}` files become `<namespace><separator><key>`.
  namespace_separator = ".",
  -- Namespace tried for keys written without one (i18next `defaultNS`).
  default_namespace = nil,
  -- Call names, matched after any non-identifier character: `i18n.global.t(` and `this.$t(` work.
  functions = { "t", "$t", "tc", "te", "tm" },
  -- Extra Lua patterns capturing the key, e.g. { 'i18nKey="([^"]+)"' }.
  patterns = {},
  filetypes = { "vue", "typescript", "javascript", "typescriptreact", "javascriptreact", "svelte" },
  display = {
    mode = "eol", -- "eol", "inline" (right after the call) or "off"
    max_len = 60,
    prefix = " ",
  },
  diagnostics = {
    enabled = true,
    severity = vim.diagnostic.severity.WARN,
    all_locales = false, -- also hint keys missing in the other locales
  },
  auto_detect = {
    depth = 4,
    dir_names = { "locales", "locale", "i18n", "lang", "langs", "messages", "translations" },
    skip = { "node_modules", "dist", "build", "coverage", "vendor" },
  },
  add = {
    prompt = "all", -- "all": ask a value per locale; "default": reuse the default locale's value
    format_cmd = nil, -- e.g. { "npx", "prettier", "--write" }, run on the written files
  },
  -- Overrides per project root, from your own config.
  projects = {},
  debounce_ms = 80,
})
```

Configuration is merged in this order: defaults, then `setup()`, then the project's `.i18n-ts.json`, then `setup().projects[root]`. Lists replace lists instead of merging.

### Per-project configuration

Commit a `.i18n-ts.json` at the project root so everyone on the team gets the same setup:

```json
{
  "sources": ["packages/i18n/messages/{locale}.json"],
  "functions": ["t", "$t", "te"]
}
```

It may set `sources`, `locales`, `default_locale`, `namespace_separator`, `default_namespace`, `functions` and `patterns`. The file is read as plain JSON, never executed. Settings that run commands (`add.format_cmd`) are ignored there: set them in your own config, globally or under `projects`.

To keep a configuration to yourself:

```lua
opts = {
  projects = {
    ["~/Code/my-app"] = { locales = { "en", "fr" }, add = { format_cmd = { "pnpm", "exec", "prettier", "--write" } } },
  },
}
```

### Examples

**vue-i18n** with `src/locales/en.json`: no configuration needed.

**i18next / react-i18next** with `public/locales/en/common.json`, keys written `t('common:title')` or `t('title')`:

```json
{ "namespace_separator": ":", "default_namespace": "common" }
```

**next-intl** with `messages/en.json`: no configuration needed. `useTranslations('Home')` scopes are not resolved yet, so write the full key or rely on diagnostics only for full keys.

**Monorepo** with the translations in a shared package:

```json
{ "sources": ["packages/i18n/messages/{locale}.json"] }
```

## Commands

| Command | Action |
| --- | --- |
| `:I18n` / `:I18n info` | Root, sources, locales, key count, load errors |
| `:I18n def` | Jump to the key under the cursor in the displayed locale |
| `:I18n show` | Float with the key in every locale |
| `:I18n next` | Display the next locale |
| `:I18n keys` | Picker: `<CR>` jumps, `<C-y>` yanks the key, `<A-i>` inserts it |
| `:I18n add [key]` | Add the key (argument, or the one under the cursor) to every locale |
| `:I18n usages [key]` | Usages of the key, translation files excluded |
| `:I18n toggle` | Hide / show translations and diagnostics |
| `:I18n reload` | Forget every project and re-read the configuration and files |

Lua API: `require("i18n-ts").definition()` returns `false` when there is no key under the cursor, so it can sit in front of `vim.lsp.buf.definition()` (see the `gd` mapping above).

## Highlights

| Group | Default |
| --- | --- |
| `I18nTsTranslation` | links to `Comment` |
| `I18nTsMissing` | links to `DiagnosticWarn` |

## Limitations

- Translation files must be JSON, one key per line (what every formatter produces). Other files load, but definitions point to line 1. Parsers for other formats can be registered with `require("i18n-ts").register_parser(ext, fn)`, where `fn(content)` returns `values, positions`.
- A call is recognised when the key is a string literal on the same line as the function name. Template literals (dynamic keys) are skipped on purpose.
- Namespace scoping from `useTranslation('ns')` / `useTranslations('ns')` is not resolved yet.

## Development

```sh
nvim --headless -l tests/run.lua
I18N_TS_PERF_ROOT=~/Code/my-app I18N_TS_PERF_FILE=src/App.vue nvim --headless -l tests/perf.lua
stylua lua plugin tests
```

## License

MIT
