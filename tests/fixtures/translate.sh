#!/bin/sh
# Test provider: keeps the request it received and answers with fixed translations.
cat > "$I18N_TS_TEST_STDIN"
printf '{"fr":"Bonjour","de":"Hallo"}'
