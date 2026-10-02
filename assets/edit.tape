# Regenerate from the repo root: vhs assets/edit.tape
# Fictional project (assets/demo-project), canned demo translation provider: no API call.
# Captions and the key display come from assets/demo-init.lua.

Output assets/edit.gif

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
Type "NVIM_APPNAME=i18n-ts-demo DEMO=edit nvim -u ../../assets/demo-init.lua src/components/CartSummary.vue"
Enter
Sleep 3s
Show

# 1. Cursor on t("cart.checkout")
Sleep 2.5s
Type "13G"
Sleep 1s

# 2. Open the editor
Type " Ie"
Sleep 3.5s

# 3. Edit the default locale
Type "cc"
Type "Checkout now"
Sleep 1s

# 4. <Tab> to fr (en-US, de, es, fr) and replace its value
Tab
Sleep 0.4s
Tab
Sleep 0.4s
Tab
Sleep 0.6s
Ctrl+U
Type "Valider la commande"
Escape
Sleep 2.5s

# 5. Save
Type ":w"
Enter
Sleep 2.5s
Type "?"
Sleep 1.5s
Type "?"
Sleep 1.5s

# 6. Close: the inline preview shows the new value
Type "q"
Sleep 3.5s

Hide
Type ":qa!"
Enter
