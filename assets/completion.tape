# Regenerate from the repo root: vhs assets/completion.tape
# Fictional project (assets/demo-project), canned demo translation provider: no API call.
# Captions and the key display come from assets/demo-init.lua.

Output assets/completion.gif

Require nvim

Set Shell "bash"
Set FontSize 15
Set Width 1400
Set Height 860
Set Padding 16
Set Theme "TokyoNight"
Set TypingSpeed 70ms
Set Framerate 24

# Off camera: install the plugins, then work on a fresh copy so assets/demo-project is never modified
Hide
Type "NVIM_APPNAME=i18n-ts-demo nvim --headless -u assets/demo-init.lua '+Lazy! sync' +qa && rm -rf .tmp/demo && mkdir -p .tmp && cp -R assets/demo-project .tmp/demo && cd .tmp/demo && clear"
Enter
Sleep 45s
Type "NVIM_APPNAME=i18n-ts-demo DEMO=completion nvim -u ../../assets/demo-init.lua src/components/CartSummary.vue"
Enter
Sleep 3s
Show

# 1. Intro
Sleep 2.5s
Type "13G"
Sleep 1s

# 2. New line, start a translation call
Type "o"
Type `<p>{{ t("`
Sleep 2.5s
Type "acc"
Sleep 3s

# 3. Accept: the translation shows at once
Enter
Type `") }}</p>`
Escape
Sleep 3.5s

Hide
Type ":qa!"
Enter
