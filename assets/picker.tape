# Regenerate from the repo root: vhs assets/picker.tape
# Fictional project (assets/demo-project), canned demo translation provider: no API call.
# Captions and the key display come from assets/demo-init.lua.

Output assets/picker.gif

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
Type "NVIM_APPNAME=i18n-ts-demo DEMO=picker nvim -u ../../assets/demo-init.lua src/components/CartSummary.vue"
Enter
Sleep 3s
Show

# 1. Intro
Sleep 2.5s

# 2. Search keys and translations
Type " Ik"
Sleep 1.5s
Type "cart"
Sleep 2s
Down
Sleep 1.2s
Down
Sleep 2s

# 3. Jump to the definition
Enter
Sleep 3s

# 4. Back, then find an unused key
Ctrl+O
Sleep 1.5s
Type " Ik"
Sleep 1s
Type "empty"
Sleep 2s

# 5. Remove it from every locale
Ctrl+X
Sleep 3s
Enter
Sleep 3.5s

Hide
Type ":qa!"
Enter
