# Regenerate from the repo root: vhs assets/translate.tape
# Fictional project (assets/demo-project), canned demo translation provider: no API call.
# Captions and the key display come from assets/demo-init.lua.

Output assets/translate.gif

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
Type "NVIM_APPNAME=i18n-ts-demo DEMO=translate nvim -u ../../assets/demo-init.lua src/components/CartSummary.vue"
Enter
Sleep 3s
Show

# 1. cart.free_shipping is missing
Sleep 3.5s
Type "15G"
Sleep 1s

# 2. Open it: every locale is missing
Type " Ie"
Sleep 3s

# 3. Type the en-US value only
Type "A"
Type "Free shipping over $50"
Escape
Sleep 1s

# 4. Save and close: background translation with a live indicator
Enter
Sleep 5s

# 5. Every locale is filled
Type " Is"
Sleep 4s

# 6. Change the source text
Type " Ie"
Sleep 2s
Type "cc"
Type "Free shipping on orders over $50"
Escape
Sleep 1s

# 7. Re-translate every locale, after confirmation (same as <A-t>, which VHS can't send as Meta)
Type ":I18n retranslate"
Enter
Sleep 2s
Enter
Sleep 5s
Type "q"
Sleep 3s

Hide
Type ":qa!"
Enter
