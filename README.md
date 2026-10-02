# i18n-ts.nvim

See your translations where you use them. A fast, dependency-free Neovim plugin for TypeScript / JavaScript projects using JSON translation files: vue-i18n, i18next / react-i18next, next-intl, nuxt-i18n, or your own `t()`.

## Features

- Translation shown next to every `t('key')`, `$t("key")`, `i18n.global.t(...)` call, for the visible lines only
- Diagnostics for keys missing in the default locale (optionally in every locale)
- Go to definition: jump from a key to its exact line in the translation file
- Float with the key in every locale, and a command to switch the displayed locale
- Completion of keys inside `t('…')` with [blink.cmp](https://github.com/Saghen/blink.cmp), all locales in the documentation
- Picker over every key and translation ([snacks.nvim](https://github.com/folke/snacks.nvim), `vim.ui.select` without it)
- Edit a key in every locale from one float: one line per locale, the default locale first, `:w` to save
- Machine-translate the empty locales from the default one (Claude Code with no API key, the Claude API, DeepL, your own command or Lua function)
- Add a key to every locale file at once, keeping key order and indentation
- Remove a key from every locale file, with a warning when the code still uses it
- Find the usages of a key with ripgrep
- Zero config for the usual layouts: the project root and the translation files are detected

Large projects stay fast: loading 13 locales of ~2,900 keys takes under 100 ms, and rendering a buffer under 1 ms. Translation files are indexed in a single pass, and locales other than the default one load in the background.

## Requirements

- Neovim >= 0.10
- Optional: [ripgrep](https://github.com/BurntSushi/ripgrep) for `:I18n usages`
- Optional: `curl` (7.84+ for `retry-after` handling) for the Claude and DeepL translation providers
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
      { "<leader>Ie", "<cmd>I18n edit<cr>", desc = "i18n: edit key" },
      { "<leader>IT", "<cmd>I18n translate<cr>", desc = "i18n: translate missing locales" },
      { "<leader>Ia", "<cmd>I18n add<cr>", desc = "i18n: add key" },
      { "<leader>Ix", "<cmd>I18n remove<cr>", desc = "i18n: remove key" },
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
3. **Locales.** Use `locales` when set. Otherwise every locale found, sorted. The default locale is always listed first.
4. **Default locale.** `default_locale` (default `"en-US"`) is matched leniently: case and `_`/`-` are ignored (`en_US.json` matches), then the base language (`en`), then any locale of that language (`en-GB`), then the first locale. A project with only `en.json` still gets `en`.

## Configuration

Defaults:

```lua
require("i18n-ts").setup({
  root_markers = { ".i18n-ts.json", ".git", "package.json" },
  -- Relative to the root. `{locale}` is required, `{namespace}` optional. Empty: auto-detected.
  sources = {},
  -- Empty: every locale found. The default locale always comes first.
  locales = {},
  -- Source of machine translations; matched leniently (see above).
  default_locale = "en-US",
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
  remove = {
    prune_empty = true, -- also delete parent objects left empty
  },
  translate = {
    provider = nil, -- nil (off), "claude_code", "anthropic", "deepl", "command", or function(request, callback)
    auto = true, -- translate the empty locales when the editor float is closed
    context = nil, -- extra hint for the model, e.g. "Medical software used by doctors."
    claude_code = { cmd = "claude", model = "claude-haiku-4-5", max_budget_usd = 0.05, extra_args = {} },
    anthropic = {
      model = "claude-haiku-4-5",
      api_key_env = "ANTHROPIC_API_KEY",
      base_url = "https://api.anthropic.com",
      max_tokens = 2048,
    },
    deepl = { api_key_env = "DEEPL_API_KEY" },
    command = nil, -- argv, see "Machine translation"
    retry_delay_ms = 2000,
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

It may set `sources`, `locales`, `default_locale`, `namespace_separator`, `default_namespace`, `functions` and `patterns`. The file is read as plain JSON, never executed. Settings that run commands or send data out (`add.format_cmd`, `translate`) are ignored there: set them in your own config, globally or under `projects`.

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
| `:I18n keys` | Picker: `<CR>` jumps, `<C-e>` edits, `<C-x>` removes, `<C-y>` yanks the key, `<A-i>` inserts it |
| `:I18n edit [key]` | Edit the key in every locale (see below); also works on a key line inside a translation file |
| `:I18n translate [key]` | Machine-translate the key's missing locales from the default locale (inside the editor float: save, then translate now) |
| `:I18n add [key]` | Add the key (argument, or the one under the cursor) to every locale |
| `:I18n remove [key]` | Delete the key (or a whole object) from every locale, after confirmation; warns when the code still uses it |
| `:I18n usages [key]` | Usages of the key, translation files excluded |
| `:I18n toggle` | Hide / show translations and diagnostics |
| `:I18n reload` | Forget every project and re-read the configuration and files |

### Editing translations

`:I18n edit` opens a float with one line per locale, the default locale first:

```
╭──────────── common.actions.save ────────────╮
│ en-US │ Save                                │
│ fr    │ Enregistrer                         │
│ de    │                             missing │
╰─ :w save · <CR> save & close · q cancel ────╯
```

Each line holds only the value: the locale label isn't text you can edit. The float keeps exactly one line per locale. Anything that would add or remove a line (`dd`, `ggdG`, `J`, a multi-line paste…) is rolled back at once, without losing your other edits, and `u` still undoes your earlier changes. Inside the float:

| Key | Action |
| --- | --- |
| `dd` | Clear the value (yanked to the register) |
| `<Tab>` / `<S-Tab>` | Next / previous locale (normal and insert mode) |
| `<CR>` in insert mode | Next locale |
| `o`, `O`, `J` | Disabled |
| `:w` | Save (no translation) |
| `<C-t>` | Save, then translate the empty locales now (normal and insert mode) |
| `<CR>` in normal mode | Save and close |
| `q` / `<Esc>` | Close without saving |

`:w` saves the changed lines and adds the locales you filled in. An emptied line is left unchanged: nothing is ever deleted. Newlines in values show as `\n`.

With a translation provider set, **closing the float** (`<CR>`, `q`, `<Esc>`, `:q`…) fills every locale still empty in the files, translated from the saved default locale value. `:w` alone never translates, so you can save the default locale several times while you refine it. To translate without closing, press `<C-t>` (or run `:I18n translate` from the float). Locales that already have a value are never re-translated, even if you change the default locale's text.

Type the default locale's value, then `<CR>` to save and close. The translation runs in the background and is written to the files when it arrives:

- the key's inline preview shows a live `⠋ translating 12 locales…` indicator in every open buffer, until the result is written;
- if the float is still open, each line being translated shows the same loader, so does the title (`key · ⠋ translating 12 locales`), and the values appear on the empty lines as soon as they arrive;
- a value you typed in the meantime is never overwritten: only locales still empty when the result arrives are filled;
- you can keep editing other keys, and several keys can be translated at once.

### Machine translation

The source text and the key are sent to the provider you choose. Nothing is sent while `translate.provider` is `nil`. API keys are read from environment variables only.

**Claude Code** (no API key: reuses the login of the [Claude Code](https://claude.com/claude-code) CLI, subscription or API key, by running `claude -p` headless):

```lua
translate = { provider = "claude_code" } -- claude-haiku-4-5, capped at $0.05 per call
```

It runs with no tools, no MCP servers, no saved session, and from Neovim's cache directory so your project's `CLAUDE.md` isn't added to the prompt. Your user-level `~/.claude/CLAUDE.md` is still loaded. Each call starts the CLI, so expect a few seconds per key. Options: `translate.claude_code = { cmd = "claude", model = "claude-haiku-4-5", max_budget_usd = 0.05, extra_args = {} }`.

**Claude API** (one HTTPS request per key for every locale, using structured JSON output):

```lua
translate = { provider = "anthropic" } -- reads ANTHROPIC_API_KEY, uses claude-haiku-4-5
```

A key translated into 12 locales is about 500 input and 300 output tokens with Claude Haiku 4.5, around $0.002. Placeholders (`{name}`, `%s`), linked messages (`@:key`), plural separators (`|`) and HTML tags are kept.

**DeepL** (one request per locale; locales DeepL doesn't support are reported and skipped):

```lua
translate = { provider = "deepl" } -- reads DEEPL_API_KEY; keys ending in ":fx" use the free API
```

**Your own command**, which gets the request as JSON on stdin and prints `{ "<locale>": "<text>" }`:

```lua
translate = { provider = "command", command = { "my-translator", "--json" } }
-- stdin: { "key": "common.save", "source_locale": "en-US", "source": "Save", "targets": ["fr", "de"] }
```

**A Lua function**, for anything else:

```lua
translate = {
  provider = function(request, callback)
    callback(nil, { fr = "…", de = "…" }) -- or callback("error message")
  end,
}
```

The Claude and DeepL providers need `curl`. The API key goes to curl on stdin, so it never shows in the process list.

Lua API: `require("i18n-ts").definition()` returns `false` when there is no key under the cursor, so it can sit in front of `vim.lsp.buf.definition()` (see the `gd` mapping above).

## Highlights

| Group | Default |
| --- | --- |
| `I18nTsTranslation` | links to `Comment` |
| `I18nTsMissing` | links to `DiagnosticWarn` |
| `I18nTsLocale` | links to `Label` (locale labels in the editor) |
| `I18nTsPending` | links to `DiagnosticInfo` (translation in progress) |

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
