#!/bin/bash
# Sets the password of the visit statistics (https://dualrecorder.benjoni.com/stats/).
# Asks for it twice (not shown) and writes only its hash to website/stats/password.php – upload that file.
set -euo pipefail
cd "$(dirname "$0")/../website"
read -rs -p "Password for the statistics: " P; echo
read -rs -p "Again: " Q; echo
if [ -z "$P" ]; then echo "Empty password – nothing saved."; exit 1; fi
if [ "$P" != "$Q" ]; then echo "The two passwords differ – nothing saved."; exit 1; fi
printf %s "$P" | php -r 'echo "<?php\nconst STATS_PASSWORD_HASH = ".var_export(password_hash(stream_get_contents(STDIN), PASSWORD_DEFAULT), true).";\n";' > stats/password.php
unset P Q
chmod 600 stats/password.php
echo "Saved to website/stats/password.php"
