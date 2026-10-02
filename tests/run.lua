-- Run with: nvim --headless -l tests/run.lua
vim.opt.rtp:prepend(vim.fn.getcwd())

local config = require("i18n-ts.config")
local store_mod = require("i18n-ts.store")
local scanner = require("i18n-ts.scanner")
local edit = require("i18n-ts.edit")
local usages = require("i18n-ts.usages")

local fixtures = vim.fs.normalize(vim.fn.getcwd() .. "/tests/fixtures")
local failures, count = 0, 0

local function test(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if ok then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end

local function eq(a, b)
  assert(vim.deep_equal(a, b), ("expected %s, got %s"):format(vim.inspect(b), vim.inspect(a)))
end

local function store_for(name, opts)
  config.setup(vim.tbl_extend("force", { root_markers = { ".i18n-ts.json", "package.json" } }, opts or {}))
  local root = fixtures .. "/" .. name
  return store_mod.new(root, (config.for_root(root)))
end

local function read(path)
  local fd = assert(io.open(path, "r"))
  local content = fd:read("*a")
  fd:close()
  return vim.split(content, "\n", { plain = true })
end

-- store

test("auto-detects src/locales/{locale}.json and orders the default locale first", function()
  local store = store_for("vue")
  eq(store.sources, { "src/locales/{locale}.json" })
  eq(store.locales, { "en", "fr" })
  eq(store.default_locale, "en")
end)

test("flattens nested keys and keeps multiline values", function()
  local store = store_for("vue")
  eq(store:get("common.actions.save"), "Save")
  eq(store:get("common.actions.save", "fr"), "Enregistrer")
  eq(store:get("multiline"), "Line one\nLine two")
  eq(store:get("list.2"), "second")
  eq(store:get("common.actions.cancel", "fr"), nil)
end)

test("positions are exact for duplicate leaf names", function()
  local store = store_for("vue")
  eq(store:position("common.title").line, 3)
  eq(store:position("home.title").line, 10)
  eq(store:position("common.actions.cancel").line, 6)
  eq(store:position("common.title").col, 5)
end)

test("array items fall back to the array's line", function()
  local store = store_for("vue")
  eq(store:position("list.1").line, 14)
end)

test("i18next layout: {locale}/{namespace}.json prefixes keys with the namespace", function()
  local store = store_for("i18next", { namespace_separator = ":" })
  eq(store.sources, { "public/locales/{locale}/{namespace}.json" })
  eq(store:get("common:hello", "fr"), "Bonjour")
  eq(store:get("common:nested.deep"), "Deep")
  eq(store:position("common:nested.deep").line, 4)
end)

test("default_namespace resolves keys written without a namespace", function()
  local store = store_for("i18next", { namespace_separator = ":", default_namespace = "common" })
  eq(store:get("hello"), "Hello")
end)

test("flat JSON keys are indexed as-is", function()
  local store = store_for("flat")
  eq(store:get("a.b"), "Flat AB")
  eq(store:position("a.b").line, 2)
end)

test(".i18n-ts.json sets sources and functions, but never format_cmd", function()
  local store = store_for("custom")
  eq(store.sources, { "i18n/messages/{locale}.json" })
  eq(store.cfg.functions, { "translate" })
  eq(store.cfg.add.format_cmd, nil)
  eq(store.locales, { "en", "de" })
end)

test("setup().projects overrides the project file", function()
  local root = fixtures .. "/custom"
  local store = store_for("custom", { projects = { [root] = { locales = { "de" } } } })
  eq(store.locales, { "de" })
  eq(store.default_locale, "de")
end)

test("roots and translation files resolve symlinks, like buffer names do", function()
  local real = vim.fn.tempname()
  vim.fn.mkdir(real .. "/locales", "p")
  vim.fn.writefile({ "{}" }, real .. "/package.json")
  vim.fn.writefile({ "{", '  "k": "v"', "}" }, real .. "/locales/en.json")
  local link = vim.fn.tempname()
  vim.uv.fs_symlink(real, link)
  config.setup({ root_markers = { "package.json" } })
  local root = require("i18n-ts.root").find(link .. "/locales", { "package.json" })
  eq(root, require("i18n-ts.root").real(real))
  local store = store_mod.new(link, (config.for_root(link)))
  eq(store:owns(link .. "/locales/en.json"), true)
  eq(store:owns(real .. "/locales/en.json"), true)
  vim.fn.delete(link)
  vim.fn.delete(real, "rf")
end)

test("auto-detect never enters node_modules", function()
  local root = fixtures .. "/custom"
  local sources = store_mod.detect_sources(root, config.defaults.auto_detect)
  eq(sources, { "i18n/messages/{locale}.json" })
end)

test("refresh reloads a locale whose file changed on disk", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/locales", "p")
  vim.fn.writefile({ "{}" }, tmp .. "/package.json")
  vim.fn.writefile({ "{", '  "k": "v1"', "}" }, tmp .. "/locales/en.json")
  config.setup({ root_markers = { "package.json" } })
  local store = store_mod.new(tmp, (config.for_root(tmp)))
  eq(store:get("k"), "v1")
  vim.uv.sleep(20)
  vim.fn.writefile({ "{", '  "k": "v2"', "}" }, tmp .. "/locales/en.json")
  eq(store:refresh(), true)
  eq(store:get("k"), "v2")
  vim.fn.delete(tmp, "rf")
end)

-- scanner

test("scanner finds t, $t, te and member calls, skips template literals and other identifiers", function()
  local compiled = scanner.compile(config.defaults.functions)
  local hits = scanner.scan(read(fixtures .. "/vue/src/App.vue"), compiled, 0)
  local keys = vim.tbl_map(function(h)
    return h.key
  end, hits)
  eq(keys, {
    "common.title",
    "common.actions.save",
    "home.title",
    "missing.key",
    "common.actions.cancel",
    "common.title",
  })
end)

test("scanner reports 0-based key columns and the call end", function()
  local compiled = scanner.compile({ "t" })
  local hit = scanner.scan({ "x = t('a.b') + 1" }, compiled, 4)[1]
  eq({ hit.lnum, hit.col, hit.end_col, hit.call_end }, { 4, 7, 10, 11 })
end)

test("scanner accepts custom Lua patterns", function()
  local compiled = scanner.compile({}, { 'i18nKey="([^"]+)"' })
  local hit = scanner.scan({ '<Trans i18nKey="welcome.title" />' }, compiled, 0)[1]
  eq({ hit.key, hit.col }, { "welcome.title", 16 })
end)

test("completion context only inside a translation call", function()
  local fns = config.defaults.functions
  eq(scanner.context("const a = t('common.ac", fns), { start = 13, prefix = "common.ac" })
  eq(scanner.context('const a = $t("', fns), { start = 14, prefix = "" })
  eq(scanner.context("const a = test('x", fns), nil)
  eq(scanner.context("const a = t('done') + 1", fns), nil)
end)

-- edit

local base = {
  "{",
  '  "common": {',
  '    "title": "Title"',
  "  },",
  '  "empty": {},',
  '  "last": "Last"',
  "}",
}

test("insert adds a sibling and fixes the previous comma", function()
  local out = assert(edit.insert(base, "common.subtitle", "Sub"))
  eq(vim.list_slice(out, 2, 5), { '  "common": {', '    "title": "Title",', '    "subtitle": "Sub"', "  }," })
end)

test("insert creates missing nested objects at the root", function()
  local out = assert(edit.insert(base, "new.deep.key", 'Say "hi"'))
  eq(vim.list_slice(out, 6, 12), {
    '  "last": "Last",',
    '  "new": {',
    '    "deep": {',
    '      "key": "Say \\"hi\\""',
    "    }",
    "  }",
    "}",
  })
end)

test("insert opens a one-line empty object", function()
  local out = assert(edit.insert(base, "empty.child", "C"))
  eq(vim.list_slice(out, 5, 7), { '  "empty": {', '    "child": "C"', "  }," })
end)

test("insert refuses existing keys and keys under a value", function()
  eq(select(2, edit.insert(base, "common.title", "x")), "key already exists")
  eq(select(2, edit.insert(base, "last.child", "x")), "'last' is a value, not an object")
end)

test("insert detects tab indentation", function()
  local out = assert(edit.insert({ "{", '\t"a": "A"', "}" }, "b", "B"))
  eq(out, { "{", '\t"a": "A",', '\t"b": "B"', "}" })
end)

test("add writes every locale file and reloads the store", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/locales", "p")
  vim.fn.writefile({ "{}" }, tmp .. "/package.json")
  vim.fn.writefile({ "{", '  "a": "A"', "}" }, tmp .. "/locales/en.json")
  vim.fn.writefile({ "{", '  "a": "A fr"', "}" }, tmp .. "/locales/fr.json")
  config.setup({ root_markers = { "package.json" } })
  local store = store_mod.new(tmp, (config.for_root(tmp)))
  store:ensure("fr")
  local written, errors = edit.add(store, "b.c", { en = "BC", fr = "BC fr" })
  eq(#written, 2)
  eq(errors, {})
  eq(store:get("b.c", "fr"), "BC fr")
  eq(read(tmp .. "/locales/en.json"), { "{", '  "a": "A",', '  "b": {', '    "c": "BC"', "  }", "}", "" })
  vim.fn.delete(tmp, "rf")
end)

-- usages

test("usages parses rg --json matches", function()
  local line = vim.json.encode({
    type = "match",
    data = {
      path = { text = "./src/App.vue" },
      lines = { text = "  t('a.b')\n" },
      line_number = 7,
      submatches = { { start = 4 } },
    },
  })
  eq(usages.parse(line .. "\n" .. '{"type":"begin"}'), {
    { file = "./src/App.vue", line = 7, col = 5, text = "t('a.b')" },
  })
end)

-- default locale

test("default_locale defaults to en-US and falls back to the base language", function()
  eq(config.defaults.default_locale, "en-US")
  eq(store_for("vue").default_locale, "en")
end)

test("en-US is picked and listed first when present", function()
  local store = store_for("enus")
  eq(store.default_locale, "en-US")
  eq(store.locales, { "en-US", "cmn", "fr" })
end)

test("locale matching ignores case and underscores", function()
  local store = store_for("underscore")
  eq(store.default_locale, "en_US")
  eq(store.locales[1], "en_US")
end)

test("an explicit locales list still puts the default first", function()
  local store = store_for("vue", { locales = { "fr", "en" } })
  eq(store.locales, { "en", "fr" })
end)

-- replace / set

local function tmp_project(files, opts)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/locales", "p")
  root = require("i18n-ts.root").real(root)
  vim.fn.writefile({ "{}" }, root .. "/package.json")
  for locale, lines in pairs(files) do
    vim.fn.writefile(lines, root .. "/locales/" .. locale .. ".json")
  end
  config.setup(vim.tbl_deep_extend("force", { root_markers = { "package.json" } }, opts or {}))
  local cfg = config.for_root(root)
  local store = store_mod.new(root, cfg)
  for _, l in ipairs(store.locales) do
    store:ensure(l)
  end
  return {
    root = root,
    cfg = cfg,
    store = store,
    compiled = scanner.compile(cfg.functions, cfg.patterns),
    locale = store.default_locale,
    enabled = true,
  }
end

local nested = {
  "{",
  '  "a": {',
  '    "b": "Old / é",',
  '    "c": "C"',
  "  },",
  '  "obj": {',
  '    "x": "X"',
  "  }",
  "}",
}

test("replace swaps the value and keeps comma, indentation, UTF-8 and slashes", function()
  local out = assert(edit.replace(nested, "a.b", 'New "quoted" / ü'))
  eq(out[3], '    "b": "New \\"quoted\\" / ü",')
  eq(out[4], '    "c": "C"')
  out = assert(edit.replace(nested, "a.c", "C2"))
  eq(out[4], '    "c": "C2"')
end)

test("replace refuses objects and missing keys", function()
  eq(select(2, edit.replace(nested, "obj", "x")), "'obj' is not a string")
  eq(select(2, edit.replace(nested, "a.zzz", "x")), "key not found")
end)

test("set updates existing values, adds missing locales and skips empty ones", function()
  local p = tmp_project({
    en = { "{", '  "k": "Key"', "}" },
    fr = { "{", '  "other": "Autre"', "}" },
    de = { "{", '  "k": "Schlüssel"', "}" },
  })
  local written, errors = edit.set(p.store, "k", { en = "Key 2", fr = "Clé", de = "" })
  eq(#written, 2)
  eq(errors, {})
  eq(read(p.root .. "/locales/en.json"), { "{", '  "k": "Key 2"', "}", "" })
  eq(read(p.root .. "/locales/fr.json"), { "{", '  "other": "Autre",', '  "k": "Clé"', "}", "" })
  eq(p.store:get("k", "de"), "Schlüssel")
  eq(p.store:get("k", "fr"), "Clé")
  vim.fn.delete(p.root, "rf")
end)

test("key_in_json finds the dotted key on the cursor line, with the namespace", function()
  local navigation = require("i18n-ts.navigation")
  local store = store_for("vue")
  vim.cmd.edit(fixtures .. "/vue/src/locales/en.json")
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  eq(navigation.key_in_json(0, store), "common.actions.cancel")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  eq(navigation.key_in_json(0, store), "common")
  store = store_for("i18next", { namespace_separator = ":" })
  vim.cmd.edit(fixtures .. "/i18next/public/locales/en/common.json")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  eq(navigation.key_in_json(0, store), "common:nested.deep")
  vim.cmd("silent! %bwipeout!")
end)

-- remove

local tree = {
  "{",
  '  "a": {',
  '    "b": "B",',
  '    "c": "C"',
  "  },",
  '  "solo": {',
  '    "only": "Only"',
  "  },",
  '  "last": "Last"',
  "}",
}

test("delete removes a middle key and keeps the commas", function()
  local out = assert(edit.delete(tree, "a.b"))
  eq(vim.list_slice(out, 2, 4), { '  "a": {', '    "c": "C"', "  }," })
end)

test("delete removes the last key of an object and strips the previous comma", function()
  local out = assert(edit.delete(tree, "a.c"))
  eq(vim.list_slice(out, 2, 4), { '  "a": {', '    "b": "B"', "  }," })
  out = assert(edit.delete(tree, "last"))
  eq(vim.list_slice(out, #out - 1, #out), { "  }", "}" })
end)

test("delete prunes parents left empty, unless asked not to", function()
  local out = assert(edit.delete(tree, "solo.only"))
  eq(out, { "{", '  "a": {', '    "b": "B",', '    "c": "C"', "  },", '  "last": "Last"', "}" })
  out = assert(edit.delete(tree, "solo.only", { prune = false }))
  eq(vim.list_slice(out, 6, 7), { '  "solo": {', "  }," })
  assert(pcall(vim.json.decode, table.concat(out, "\n")))
end)

test("delete removes a whole object and refuses missing keys", function()
  local out = assert(edit.delete(tree, "a"))
  eq(out[2], '  "solo": {')
  eq(select(2, edit.delete(tree, "nope")), "key not found")
end)

test("remove deletes the key from every locale that has it", function()
  local p = tmp_project({
    en = { "{", '  "k": "K",', '  "keep": "Keep"', "}" },
    fr = { "{", '  "keep": "Garder",', '  "k": "Kf"', "}" },
    de = { "{", '  "keep": "Behalten"', "}" },
  })
  local removed, errors = edit.remove(p.store, "k")
  eq(#removed, 2)
  eq(errors, {})
  eq(read(p.root .. "/locales/fr.json"), { "{", '  "keep": "Garder"', "}", "" })
  eq(p.store:get("k", "en"), nil)
  eq(p.store:get("keep", "en"), "Keep")
  vim.fn.delete(p.root, "rf")
end)

test("remove works with i18next namespaces", function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/locales/en", "p")
  vim.fn.writefile({ "{}" }, root .. "/package.json")
  vim.fn.writefile({ "{", '  "hello": "Hello",', '  "bye": "Bye"', "}" }, root .. "/locales/en/common.json")
  config.setup({ root_markers = { "package.json" }, namespace_separator = ":" })
  local store = store_mod.new(root, (config.for_root(root)))
  local removed = edit.remove(store, "common:hello")
  eq(#removed, 1)
  eq(read(root .. "/locales/en/common.json"), { "{", '  "bye": "Bye"', "}", "" })
  vim.fn.delete(root, "rf")
end)

test(":I18n remove asks for confirmation and does nothing when cancelled", function()
  local navigation = require("i18n-ts.navigation")
  local p = tmp_project({ en = { "{", '  "k": "K"', "}" }, fr = { "{", '  "k": "Kf"', "}" } })
  local prompts = {}
  local original = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    table.insert(prompts, opts.prompt)
    on_choice(items[#items])
  end
  navigation.remove("k", p, { check_usages = false })
  eq(p.store:get("k", "fr"), "Kf")
  vim.ui.select = function(items, opts, on_choice)
    table.insert(prompts, opts.prompt)
    on_choice(items[1])
  end
  navigation.remove("k", p, { check_usages = false })
  vim.ui.select = original
  eq(prompts[1], "Remove 'k' from 2 locale files?")
  eq(p.store:get("k", "fr"), nil)
  eq(read(p.root .. "/locales/en.json"), { "{", "}", "" })
  vim.fn.delete(p.root, "rf")
end)

test(":I18n remove warns when the key is still used in the code", function()
  if vim.fn.executable("rg") ~= 1 then
    print("     skipped: ripgrep is not installed, the usage warning needs it")
    return
  end
  local store = store_for("vue")
  local project = { root = fixtures .. "/vue", cfg = store.cfg, store = store, locale = "en", enabled = true }
  local prompt
  local original = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    prompt = opts.prompt
    on_choice(items[#items])
  end
  require("i18n-ts.navigation").remove("common.title", project)
  assert(vim.wait(5000, function()
    return prompt ~= nil
  end))
  vim.ui.select = original
  eq(prompt, "Remove 'common.title' from 2 locale files? It is still used in 2 places.")
end)

-- editor

local editor = require("i18n-ts.editor")

test("editor lists every locale, default first, and writes the changed lines", function()
  local p = tmp_project({
    en = { "{", '  "k": "Line\\nbreak"', "}" },
    fr = { "{", '  "k": "Ligne"', "}" },
    de = { "{", "}" },
  })
  local buf = editor.open(p, "k")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "Line\\nbreak", "", "Ligne" })
  eq(editor.locales(buf), { "en", "de", "fr" })
  vim.api.nvim_buf_set_lines(buf, 1, 3, false, { "Zeile", "Ligne 2" })
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("write")
  end)
  eq(vim.bo[buf].modified, false)
  eq(p.store:get("k", "de"), "Zeile")
  eq(p.store:get("k", "fr"), "Ligne 2")
  eq(p.store:get("k", "en"), "Line\nbreak")
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

test("editor refuses a write when lines were added or removed", function()
  local p = tmp_project({ en = { "{", '  "k": "K"', "}" }, fr = { "{", '  "k": "Kf"', "}" } })
  local buf = editor.open(p, "k")
  vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "extra" })
  local ok = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("write")
  end)
  eq(vim.bo[buf].modified, true)
  eq(p.store:get("k", "fr"), "Kf")
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
  assert(ok ~= nil)
end)

local function wait_lines(buf, n)
  return vim.wait(1000, function()
    return vim.api.nvim_buf_line_count(buf) == n
  end, 5)
end

test("editor restores the locale lines when they are all deleted", function()
  local p = tmp_project({ en = { "{", '  "k": "K"', "}" }, fr = { "{", '  "k": "Kf"', "}" } })
  local buf = editor.open(p, "k")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  assert(wait_lines(buf, 2))
  vim.wait(20)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "K", "Kf" })
  eq(#vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}) >= 2, true)
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

test("editor removes added lines but keeps the edits made before", function()
  local p = tmp_project({ en = { "{", '  "k": "K"', "}" }, fr = { "{", '  "k": "Kf"', "}" } })
  local buf = editor.open(p, "k")
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Kf edited" })
  vim.wait(20)
  vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "extra", "lines" })
  assert(vim.wait(1000, function()
    return vim.api.nvim_buf_line_count(buf) == 2
  end, 5))
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "K", "Kf edited" })
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

test("undo still reaches earlier edits after a rolled-back deletion", function()
  local p = tmp_project({ en = { "{", '  "k": "K"', "}" }, fr = { "{", '  "k": "Kf"', "}" } })
  local buf = editor.open(p, "k")
  local function step(cmd)
    vim.cmd(cmd)
    vim.cmd("let &undolevels = &undolevels")
    vim.wait(30)
  end
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  step("normal! A edited")
  step("normal! ggdG")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "K", "Kf edited" })
  step("silent normal! u")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "K", "Kf" })
  step("silent normal! u")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "K", "Kf" })
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

test("insert-mode keys never join locale lines", function()
  local p = tmp_project({ en = { "{", '  "k": "K"', "}" }, fr = { "{", '  "k": "Kf"', "}" } })
  local buf = editor.open(p, "k")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_feedkeys(vim.keycode("i<BS><BS><C-w><Esc>"), "x", false)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_feedkeys(vim.keycode("A<Del><CR>X<Esc>"), "x", false)
  vim.wait(30)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "K", "KfX" })
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

test("dd clears the value instead of deleting the line", function()
  local p = tmp_project({ en = { "{", '  "k": "K"', "}" }, fr = { "{", '  "k": "Kf"', "}" } })
  local buf = editor.open(p, "k")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("normal dd")
  vim.wait(20)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "K", "" })
  vim.cmd("normal o")
  vim.cmd("normal J")
  vim.wait(20)
  eq(vim.api.nvim_buf_line_count(buf), 2)
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

test("the empty locales are translated when the float is closed, not on :w", function()
  local requests = {}
  local p = tmp_project({
    en = { "{", "}" },
    fr = { "{", '  "greet": "Salut"', "}" },
    de = { "{", "}" },
  }, {
    translate = {
      provider = function(req, cb)
        table.insert(requests, req)
        cb(nil, { de = "Hallo" })
      end,
    },
  })
  local buf = editor.open(p, "greet")
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "Hello" })
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("write")
  end)
  vim.wait(50)
  eq(#requests, 0)
  editor.close(buf)
  assert(vim.wait(2000, function()
    return p.store:get("greet", "de") ~= nil
  end))
  eq(
    requests[1],
    { key = "greet", source_locale = "en", source = "Hello", targets = { "de" }, schema_locales = { "de", "fr" } }
  )
  eq(p.store:get("greet", "de"), "Hallo")
  eq(p.store:get("greet", "fr"), "Salut")
  vim.fn.delete(p.root, "rf")
end)

test("closing with :q also translates, closing a fully translated key does not", function()
  local requests = {}
  local p = tmp_project({ en = { "{", '  "k": "K"', "}" }, fr = { "{", "}" } }, {
    translate = {
      provider = function(req, cb)
        table.insert(requests, req)
        cb(nil, { fr = "Kf" })
      end,
    },
  })
  editor.open(p, "k")
  vim.cmd("quit")
  assert(vim.wait(2000, function()
    return p.store:get("k", "fr") ~= nil
  end))
  eq(#requests, 1)
  local buf = editor.open(p, "k")
  editor.close(buf)
  vim.wait(50)
  eq(#requests, 1)
  vim.fn.delete(p.root, "rf")
end)

test(":I18n translate inside the float translates now", function()
  local requests = {}
  local p = tmp_project({ en = { "{", "}" }, fr = { "{", "}" } }, {
    translate = {
      provider = function(req, cb)
        table.insert(requests, req)
        cb(nil, { fr = "Bonjour" })
      end,
    },
  })
  local buf = editor.open(p, "greet")
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "Hello" })
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("write")
  end)
  require("i18n-ts.navigation").translate()
  assert(vim.wait(2000, function()
    return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "Bonjour"
  end))
  eq(#requests, 1)
  editor.close(buf)
  vim.wait(50)
  eq(#requests, 1)
  vim.fn.delete(p.root, "rf")
end)

test("translation keeps running after the float is closed, with a live indicator", function()
  local i18n = require("i18n-ts")
  local display = require("i18n-ts.display")
  local finish
  local p = tmp_project({ en = { "{", "}" }, fr = { "{", "}" }, de = { "{", "}" } }, {
    translate = {
      provider = function(_, cb)
        finish = function()
          cb(nil, { fr = "Bonjour", de = "Hallo" })
        end
      end,
    },
  })
  vim.fn.writefile({ "<template>{{ t('greet') }}</template>" }, p.root .. "/Page.vue")
  i18n.projects[p.root] = p
  vim.cmd.edit(p.root .. "/Page.vue")
  local source = vim.api.nvim_get_current_buf()
  vim.bo[source].filetype = "vue"
  i18n.attach(source)

  local buf = editor.open(p, "greet")
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "Hello" })
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("write")
  end)
  editor.close(buf)
  assert(p.pending.greet, "translation should be pending after the float is closed")

  local function marks_text()
    local text = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(source, display.ns, 0, -1, { details = true })) do
      for _, chunk in ipairs(m[4].virt_text or {}) do
        table.insert(text, chunk[1])
      end
    end
    return table.concat(text)
  end
  assert(
    vim.wait(1000, function()
      return marks_text():find("translating 2 locales", 1, true) ~= nil
    end),
    "no indicator in the source buffer: " .. marks_text()
  )

  require("i18n-ts.edit").set(p.store, "greet", { de = "Guten Tag" })
  finish()
  assert(vim.wait(1000, function()
    return p.store:get("greet", "fr") ~= nil
  end))
  eq(p.store:get("greet", "fr"), "Bonjour")
  eq(p.store:get("greet", "de"), "Guten Tag")
  eq(p.pending.greet, nil)
  assert(
    vim.wait(1000, function()
      return not marks_text():find("translating", 1, true)
    end),
    "indicator still shown: " .. marks_text()
  )
  vim.cmd("silent! %bwipeout!")
  i18n.projects[p.root] = nil
  vim.fn.delete(p.root, "rf")
end)

test("the editor float shows a loader on the lines being translated", function()
  local finish
  local p = tmp_project({ en = { "{", "}" }, fr = { "{", "}" }, de = { "{", "}" } }, {
    translate = {
      provider = function(_, cb)
        finish = function()
          cb(nil, { fr = "Bonjour", de = "Hallo" })
        end
      end,
    },
  })
  local buf = editor.open(p, "greet")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "Hello" })
  vim.api.nvim_feedkeys(vim.keycode("<C-t>"), "x", false)
  eq(p.store:get("greet", "en"), "Hello")
  local function line_marks(row)
    local text = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, { details = true })) do
      for _, chunk in ipairs(m[4].virt_text or {}) do
        table.insert(text, chunk[1])
      end
    end
    return table.concat(text)
  end
  local function title()
    local parts = {}
    for _, chunk in ipairs(vim.api.nvim_win_get_config(win).title or {}) do
      table.insert(parts, chunk[1])
    end
    return table.concat(parts)
  end
  assert(line_marks(1):find("translating", 1, true), "no loader on the de line: " .. line_marks(1))
  assert(line_marks(2):find("translating", 1, true), "no loader on the fr line: " .. line_marks(2))
  assert(not line_marks(0):find("translating", 1, true), "the source line should not show a loader")
  assert(title():find("translating 2 locales", 1, true), "no loader in the title: " .. title())
  local first_frame = title()
  assert(
    vim.wait(1000, function()
      return title() ~= first_frame
    end),
    "the title loader is not animated"
  )
  finish()
  assert(vim.wait(1000, function()
    return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "Hallo"
  end))
  vim.wait(20)
  eq(line_marks(1):find("translating", 1, true), nil)
  eq(title():find("translating", 1, true), nil)
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

local function with_select(answer, fn)
  local prompts = {}
  local original = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    table.insert(prompts, opts.prompt)
    on_choice(answer == "confirm" and items[1] or items[#items])
  end
  local ok, err = pcall(fn, prompts)
  vim.ui.select = original
  assert(ok, err)
end

local function float_ui(buf)
  local win = vim.fn.bufwinid(buf)
  local virt_lines, badges = {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    for _, line in ipairs(m[4].virt_lines or {}) do
      local text = {}
      for _, chunk in ipairs(line) do
        table.insert(text, chunk[1])
      end
      table.insert(virt_lines, table.concat(text))
    end
    if m[4].virt_text_pos == "eol" then
      local text = {}
      for _, chunk in ipairs(m[4].virt_text) do
        table.insert(text, chunk[1])
      end
      badges[m[2] + 1] = table.concat(text)
    end
  end
  local footer = {}
  for _, chunk in ipairs(vim.api.nvim_win_get_config(win).footer or {}) do
    table.insert(footer, chunk[1])
  end
  return {
    legend = table.concat(virt_lines, "\n"),
    badges = badges,
    footer = table.concat(footer),
    height = vim.api.nvim_win_get_height(win),
  }
end

test("the float shows a keymap legend, toggled with ?", function()
  local p = tmp_project(
    { en = { "{", '  "k": "K"', "}" }, fr = { "{", "}" } },
    { translate = { provider = "claude_code" } }
  )
  local buf = editor.open(p, "k")
  local ui = float_ui(buf)
  for _, text in ipairs({ ":w", "save", "<C-t>", "translate empty", "gT", "re-translate all", "dd", "clear value" }) do
    assert(ui.legend:find(text, 1, true), "legend misses '" .. text .. "':\n" .. ui.legend)
  end
  local full = ui.height
  vim.api.nvim_feedkeys("?", "x", false)
  ui = float_ui(buf)
  eq(ui.legend, "")
  eq(ui.height, 2)
  assert(ui.footer:find("? help", 1, true), ui.footer)
  vim.api.nvim_feedkeys("?", "x", false)
  eq(float_ui(buf).height, full)
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

test("gT re-translates by default, <A-t> is no longer mapped", function()
  local p = tmp_project({ en = { "{", '  "k": "K"', "}" }, fr = { "{", '  "k": "Kf"', "}" } }, {
    translate = {
      provider = function(_, cb)
        cb(nil, { fr = "New" })
      end,
    },
  })
  local buf = editor.open(p, "k")
  assert(float_ui(buf).legend:find("gT", 1, true), float_ui(buf).legend)
  eq(float_ui(buf).legend:find("<A-t>", 1, true), nil)
  eq(vim.fn.maparg("<A-t>", "n", false, true).buffer, nil)
  with_select("confirm", function()
    vim.api.nvim_feedkeys("gT", "x", false)
  end)
  assert(vim.wait(2000, function()
    return p.store:get("k", "fr") == "New"
  end))
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

test("editor.keys remaps or disables the float keys, and the legend follows", function()
  local p = tmp_project({ en = { "{", '  "k": "K"', "}" }, fr = { "{", "}" } }, {
    translate = { provider = "claude_code" },
    editor = { keys = { retranslate = "<leader>r", translate = false, clear = { "dd", "<C-k>" } } },
  })
  local buf = editor.open(p, "k")
  local legend = float_ui(buf).legend
  assert(legend:find("<leader>r", 1, true), legend)
  eq(legend:find("<C-t>", 1, true), nil)
  eq(legend:find("translate empty", 1, true), nil)
  eq(vim.fn.maparg("<C-t>", "n", false, true).buffer, nil)
  eq(vim.fn.maparg("gT", "n", false, true).buffer, nil)
  eq(vim.fn.maparg("<C-k>", "n", false, true).buffer, 1)
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

test("the legend hides translation keys when no provider is set", function()
  local p = tmp_project({ en = { "{", '  "k": "K"', "}" } })
  local buf = editor.open(p, "k")
  local ui = float_ui(buf)
  eq(ui.legend:find("<C-t>", 1, true), nil)
  assert(ui.footer:find("translation off", 1, true), ui.footer)
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

test("badges and footer follow the edits live", function()
  local p = tmp_project({ en = { "{", '  "k": "K"', "}" }, fr = { "{", "}" }, de = { "{", '  "k": "Kd"', "}" } })
  local buf = editor.open(p, "k")
  local ui = float_ui(buf)
  assert(ui.badges[1]:find("source", 1, true), vim.inspect(ui.badges))
  assert(ui.badges[3]:find("missing", 1, true), vim.inspect(ui.badges))
  eq(ui.badges[2], nil)
  assert(ui.footer:find("1 missing", 1, true), ui.footer)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Kd edited" })
  vim.wait(30)
  ui = float_ui(buf)
  assert(ui.badges[2]:find("modified", 1, true), vim.inspect(ui.badges))
  assert(ui.footer:find("1 modified", 1, true), ui.footer)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("write")
  end)
  vim.wait(30)
  ui = float_ui(buf)
  eq(ui.badges[2], nil)
  eq(ui.footer:find("modified", 1, true), nil)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "" })
  vim.wait(30)
  ui = float_ui(buf)
  assert(ui.badges[2]:find("emptied, kept on save", 1, true), vim.inspect(ui.badges))
  eq(ui.footer:find("modified", 1, true), nil)
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

test(":I18n retranslate replaces every other locale after confirmation", function()
  local requests = {}
  local p = tmp_project({
    en = { "{", '  "k": "New text"', "}" },
    fr = { "{", '  "k": "Ancien"', "}" },
    de = { "{", "}" },
  }, {
    translate = {
      provider = function(req, cb)
        table.insert(requests, req)
        cb(nil, { fr = "Nouveau", de = "Neu" })
      end,
    },
  })
  local navigation = require("i18n-ts.navigation")
  with_select("cancel", function(prompts)
    navigation.retranslate("k", p)
    eq(prompts[1], "Re-translate 2 locales of 'k' from en? Existing values will be replaced.")
  end)
  vim.wait(50)
  eq(#requests, 0)
  with_select("confirm", function()
    navigation.retranslate("k", p)
  end)
  assert(vim.wait(2000, function()
    return p.store:get("k", "fr") == "Nouveau"
  end))
  eq(requests[1].targets, { "de", "fr" })
  eq(p.store:get("k", "de"), "Neu")
  eq(p.store:get("k", "en"), "New text")
  vim.fn.delete(p.root, "rf")
end)

test("retranslate keeps a value changed while the request was running", function()
  local finish
  local p = tmp_project({
    en = { "{", '  "k": "New"', "}" },
    fr = { "{", '  "k": "Old fr"', "}" },
    de = { "{", '  "k": "Old de"', "}" },
  }, {
    translate = {
      provider = function(_, cb)
        finish = function()
          cb(nil, { fr = "Nouveau", de = "Neu" })
        end
      end,
    },
  })
  with_select("confirm", function()
    require("i18n-ts.navigation").retranslate("k", p)
  end)
  edit.set(p.store, "k", { de = "Mine" })
  finish()
  assert(vim.wait(2000, function()
    return p.store:get("k", "fr") == "Nouveau"
  end))
  eq(p.store:get("k", "de"), "Mine")
  vim.fn.delete(p.root, "rf")
end)

test("gT in the float saves, retranslates and updates the lines", function()
  local p = tmp_project({
    en = { "{", '  "k": "Old"', "}" },
    fr = { "{", '  "k": "Vieux"', "}" },
  }, {
    translate = {
      provider = function(req, cb)
        eq(req.source, "Fresh")
        cb(nil, { fr = "Frais" })
      end,
    },
  })
  local buf = editor.open(p, "k")
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "Fresh" })
  with_select("confirm", function()
    vim.api.nvim_feedkeys("gT", "x", false)
  end)
  assert(vim.wait(2000, function()
    return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "Frais"
  end))
  eq(p.store:get("k", "en"), "Fresh")
  eq(p.store:get("k", "fr"), "Frais")
  eq(vim.bo[buf].modified, false)
  editor.close(buf)
  vim.fn.delete(p.root, "rf")
end)

test("editor does not translate when the default locale is empty", function()
  local called = false
  local p = tmp_project({ en = { "{", "}" }, fr = { "{", "}" } }, {
    translate = {
      provider = function(_, cb)
        called = true
        cb(nil, {})
      end,
    },
  })
  local buf = editor.open(p, "k")
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "Seulement fr" })
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("write")
  end)
  editor.close(buf)
  vim.wait(100)
  eq(called, false)
  eq(p.store:get("k", "fr"), "Seulement fr")
  vim.fn.delete(p.root, "rf")
end)

-- translate

local translate = require("i18n-ts.translate")
local req = { key = "common.save", source_locale = "en-US", source = "Save {count}", targets = { "fr", "de" } }

local function with_runner(responses, fn)
  local calls = {}
  local original = translate.runner
  translate.runner = function(cmd, opts, on_exit)
    local body
    for _, arg in ipairs(cmd) do
      if arg:sub(1, 1) == "@" then
        body = table.concat(read(arg:sub(2)), "\n")
      end
    end
    table.insert(calls, { cmd = cmd, opts = opts, body = body })
    local r = table.remove(responses, 1)
    on_exit({ code = 0, stdout = r, stderr = "" })
  end
  local ok, err = pcall(fn, calls)
  translate.runner = original
  assert(ok, err)
end

local function run_sync(cfg, request)
  local done, err, result = false, nil, nil
  translate.run(cfg, request, function(e, r)
    done, err, result = true, e, r
  end)
  assert(
    vim.wait(3000, function()
      return done
    end),
    "translate callback never ran"
  )
  return err, result
end

local anthropic_cfg =
  vim.tbl_deep_extend("force", config.defaults.translate, { provider = "anthropic", retry_delay_ms = 1 })

local function api_response(code, body, retry_after)
  return vim.json.encode(body) .. "\n" .. code .. " " .. (retry_after or "")
end

test("anthropic request: light model, schema with the targets, no effort, key kept out of argv", function()
  vim.env.I18N_TS_TEST_KEY = "sk-test-secret"
  local cfg = vim.tbl_deep_extend("force", anthropic_cfg, { anthropic = { api_key_env = "I18N_TS_TEST_KEY" } })
  local text = vim.json.encode({ fr = "Enregistrer {count}", de = "Speichern {count}" })
  with_runner({
    api_response(200, { stop_reason = "end_turn", content = { { type = "text", text = text } } }),
  }, function(calls)
    local err, result = run_sync(cfg, req)
    eq(err, nil)
    eq(result, { fr = "Enregistrer {count}", de = "Speichern {count}" })
    local call = calls[1]
    assert(not table.concat(call.cmd, " "):find("sk-test-secret", 1, true), "API key leaked into argv")
    assert(call.opts.stdin:find("x-api-key: sk-test-secret", 1, true), "API key missing from curl stdin config")
    local body = vim.json.decode(call.body)
    eq(body.model, "claude-haiku-4-5")
    eq(body.output_config.effort, nil)
    eq(body.thinking, nil)
    eq(body.output_config.format.schema.required, { "fr", "de" })
    eq(body.output_config.format.schema.additionalProperties, false)
  end)
  vim.env.I18N_TS_TEST_KEY = nil
end)

test("anthropic errors: refusal, max_tokens, invalid key, missing key", function()
  vim.env.I18N_TS_TEST_KEY = "k"
  local cfg = vim.tbl_deep_extend("force", anthropic_cfg, { anthropic = { api_key_env = "I18N_TS_TEST_KEY" } })
  with_runner({
    api_response(200, { stop_reason = "refusal", content = {} }),
    api_response(200, { stop_reason = "max_tokens", content = {} }),
    api_response(401, { type = "error", error = { message = "invalid x-api-key" } }),
  }, function()
    assert(run_sync(cfg, req):find("refused", 1, true))
    assert(run_sync(cfg, req):find("max_tokens", 1, true))
    assert(run_sync(cfg, req):find("I18N_TS_TEST_KEY", 1, true))
  end)
  vim.env.I18N_TS_TEST_KEY = nil
  assert(run_sync(cfg, req):find("I18N_TS_TEST_KEY is not set", 1, true))
end)

test("anthropic retries once on 429 then succeeds", function()
  vim.env.I18N_TS_TEST_KEY = "k"
  local cfg = vim.tbl_deep_extend("force", anthropic_cfg, { anthropic = { api_key_env = "I18N_TS_TEST_KEY" } })
  with_runner({
    api_response(429, { type = "error", error = { message = "rate limited" } }, "0"),
    api_response(200, { stop_reason = "end_turn", content = { { type = "text", text = '{"fr":"A","de":"B"}' } } }),
  }, function(calls)
    local err, result = run_sync(cfg, req)
    eq(err, nil)
    eq(result.fr, "A")
    eq(#calls, 2)
  end)
  vim.env.I18N_TS_TEST_KEY = nil
end)

local claude_cfg = vim.tbl_deep_extend(
  "force",
  config.defaults.translate,
  { provider = "claude_code", claude_code = { session = false } }
)

local function arg_after(cmd, flag)
  for i, a in ipairs(cmd) do
    if a == flag then
      return cmd[i + 1]
    end
  end
end

test("claude_code runs claude -p with the light model, a schema, no tools and no API key", function()
  with_runner({
    vim.json.encode({ type = "result", is_error = false, structured_output = { fr = "Enregistrer", de = "Speichern" } }),
  }, function(calls)
    local err, result = run_sync(claude_cfg, req)
    eq(err, nil)
    eq(result, { fr = "Enregistrer", de = "Speichern" })
    local cmd = calls[1].cmd
    eq(cmd[1], "claude")
    assert(vim.tbl_contains(cmd, "-p"))
    eq(arg_after(cmd, "--model"), "claude-haiku-4-5")
    eq(arg_after(cmd, "--output-format"), "json")
    eq(arg_after(cmd, "--tools"), "")
    eq(vim.json.decode(arg_after(cmd, "--json-schema")).required, { "fr", "de" })
    assert(not vim.tbl_contains(cmd, "--bare"), "--bare would skip the Claude Code login")
    eq(vim.json.decode(calls[1].opts.stdin).source, "Save {count}")
    eq(calls[1].opts.cwd, vim.fn.stdpath("cache"))
  end)
end)

test("claude_code falls back to a JSON result string and reports CLI errors", function()
  with_runner({
    vim.json.encode({ type = "result", is_error = false, result = '{"fr":"A","de":"B"}' }),
    vim.json.encode({ type = "result", is_error = true, result = "Not logged in" }),
    "not json",
  }, function()
    local err, result = run_sync(claude_cfg, req)
    eq(err, nil)
    eq(result, { fr = "A", de = "B" })
    assert(run_sync(claude_cfg, req):find("Not logged in", 1, true))
    assert(run_sync(claude_cfg, req):find("unexpected output", 1, true))
  end)
end)

-- claude_code session

local session = require("i18n-ts.claude_session")
local fake_claude = { "nvim", "-l", fixtures .. "/fake_claude.lua" }

local function session_cfg(overrides)
  return vim.tbl_deep_extend("force", config.defaults.translate, {
    provider = "claude_code",
    claude_code = vim.tbl_extend("force", { cmd = fake_claude, prewarm = false }, overrides or {}),
  })
end

local function spawn_counter()
  local file = vim.fn.tempname()
  vim.env.FAKE_CLAUDE_SPAWNS = file
  return function()
    return vim.fn.filereadable(file) == 1 and #vim.fn.readfile(file) or 0
  end, function()
    vim.fn.delete(file)
    vim.env.FAKE_CLAUDE_SPAWNS = nil
  end
end

local function session_req(source, targets)
  return { key = "k", source_locale = "en", source = source, targets = targets or { "fr", "de" } }
end

test("claude_code session: one warm process answers several requests in order", function()
  local spawns, cleanup = spawn_counter()
  local cfg = session_cfg()
  for i, source in ipairs({ "One", "Two", "Three" }) do
    local err, result = run_sync(cfg, session_req(source))
    eq(err, nil)
    eq(result, { fr = "fr:" .. source, de = "de:" .. source })
    eq(session.status(cfg)[1].turns, i)
  end
  eq(spawns(), 1)
  session.stop_all()
  cleanup()
end)

test("claude_code session: concurrent requests are queued on the same process", function()
  local spawns, cleanup = spawn_counter()
  vim.env.FAKE_CLAUDE_DELAY_MS = "50"
  local cfg = session_cfg()
  local results = {}
  for _, source in ipairs({ "A", "B", "C" }) do
    translate.run(cfg, session_req(source, { "fr" }), function(err, result)
      table.insert(results, err or result.fr)
    end)
  end
  assert(vim.wait(5000, function()
    return #results == 3
  end))
  eq(results, { "fr:A", "fr:B", "fr:C" })
  eq(spawns(), 1)
  vim.env.FAKE_CLAUDE_DELAY_MS = nil
  session.stop_all()
  cleanup()
end)

test("claude_code session: recycled after max_turns", function()
  local spawns, cleanup = spawn_counter()
  local cfg = session_cfg({ max_turns = 2 })
  for _, source in ipairs({ "1", "2", "3" }) do
    eq(run_sync(cfg, session_req(source)), nil)
  end
  eq(spawns(), 2)
  session.stop_all()
  cleanup()
end)

test("claude_code session: stopped when idle", function()
  local cfg = session_cfg({ idle_timeout_ms = 100 })
  eq(run_sync(cfg, session_req("x")), nil)
  eq(session.status(cfg)[1].state, "ready")
  assert(vim.wait(2000, function()
    return #session.status(cfg) == 0 or session.status(cfg)[1].state == "stopped"
  end))
  session.stop_all()
end)

test("claude_code session: a crash falls back to one-shot, the next request restarts it", function()
  local spawns, cleanup = spawn_counter()
  vim.env.FAKE_CLAUDE_CRASH_ON = "2"
  local cfg = session_cfg()
  eq(select(2, run_sync(cfg, session_req("first"))), { fr = "fr:first", de = "de:first" })
  local err, result = run_sync(cfg, session_req("second"))
  eq(err, nil)
  eq(result, { fr = "fr:second", de = "de:second" })
  vim.env.FAKE_CLAUDE_CRASH_ON = nil
  eq(select(2, run_sync(cfg, session_req("third"))), { fr = "fr:third", de = "de:third" })
  eq(spawns(), 3)
  session.stop_all()
  cleanup()
end)

test("claude_code session: a request times out and the process is restarted", function()
  vim.env.FAKE_CLAUDE_DELAY_MS = "1500"
  local cfg = session_cfg({ request_timeout_ms = 200 })
  local err = run_sync(cfg, session_req("slow"))
  assert(err and err:find("timed out", 1, true), tostring(err))
  vim.env.FAKE_CLAUDE_DELAY_MS = nil
  eq(select(2, run_sync(cfg, session_req("fast"))), { fr = "fr:fast", de = "de:fast" })
  session.stop_all()
end)

test("claude_code session: prewarm starts the process and sends a warm-up turn", function()
  local spawns, cleanup = spawn_counter()
  local cfg = session_cfg({ prewarm = true })
  translate.prewarm(cfg, { "fr", "de" })
  assert(vim.wait(3000, function()
    return (session.status(cfg)[1] or {}).turns == 1
  end))
  eq(spawns(), 1)
  eq(select(2, run_sync(cfg, session_req("after"))), { fr = "fr:after", de = "de:after" })
  eq(spawns(), 1)
  session.stop_all()
  cleanup()
end)

test("claude_code session = false always uses one-shot calls", function()
  local spawns, cleanup = spawn_counter()
  local cfg = session_cfg({ session = false })
  eq(select(2, run_sync(cfg, session_req("a"))), { fr = "fr:a", de = "de:a" })
  eq(select(2, run_sync(cfg, session_req("b"))), { fr = "fr:b", de = "de:b" })
  eq(spawns(), 2)
  eq(#session.status(cfg), 0)
  cleanup()
end)

test("command provider gets the request on stdin and returns its JSON", function()
  local stdin_file = vim.fn.tempname()
  vim.env.I18N_TS_TEST_STDIN = stdin_file
  local cfg = vim.tbl_deep_extend("force", config.defaults.translate, {
    provider = "command",
    command = { "sh", fixtures .. "/translate.sh" },
  })
  local err, result = run_sync(cfg, req)
  eq(err, nil)
  eq(result, { fr = "Bonjour", de = "Hallo" })
  eq(vim.json.decode(table.concat(read(stdin_file), "\n")), req)
  vim.fn.delete(stdin_file)
  vim.env.I18N_TS_TEST_STDIN = nil
end)

test(".i18n-ts.json cannot configure translation", function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.writefile(
    { '{ "translate": { "provider": "command", "command": ["rm", "-rf", "/"] } }' },
    root .. "/.i18n-ts.json"
  )
  config.setup({})
  eq(config.for_root(root).translate.provider, nil)
  vim.fn.delete(root, "rf")
end)

print(("\n%d tests, %d failure(s)"):format(count, failures))
os.exit(failures == 0 and 0 or 1)
