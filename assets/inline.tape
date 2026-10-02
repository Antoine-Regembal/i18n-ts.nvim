# Regenerate from the repo root: vhs assets/inline.tape
# Fictional project (assets/demo-project), canned demo translation provider: no API call.
# Captions and the key display come from assets/demo-init.lua.

Output assets/inline.gif

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
Type "NVIM_APPNAME=i18n-ts-demo DEMO=inline nvim -u ../../assets/demo-init.lua src/components/CartSummary.vue"
Enter
Sleep 3s
Show

# 1. Translations next to every call, missing key as a diagnostic
Sleep 3.5s
Type "10G"
Sleep 1s

# 2. Switch the displayed locale: de, es, fr
Type " In"
Sleep 2.5s
Type " In"
Sleep 1.5s
Type " In"
Sleep 3s

# 3. Every locale of the key under the cursor
Type "13G"
Sleep 0.5s
Type " Is"
Sleep 4s

# 4. Go to definition in the displayed locale
Type "gd"
Sleep 3.5s

# 5. Back
Ctrl+O
Sleep 3s

Hide
Type ":qa!"
Enter
