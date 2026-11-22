#!/bin/zsh
# Usage: eda.sh <code-file.js> [args-json] [timeout-ms]
# Runs a JS snippet in the 嘉立创EDA session through the official CLI and saves raw output as evidence.
set -u
W="${0:A:h:h}"
APP="/Applications/嘉立创EDA(专业版).app/Contents/MacOS/LCEDA-Pro"
S=$(cat "$W/evidence/session.txt")
name="${1:t:r}"
out="$W/evidence/$name.json"
"$APP" invoke --session "$S" --ext-uuid eda --code-file "$1" --args "${2:-{\}}" --timeout "${3:-60000}" >"$out" 2>"$out.err" </dev/null
print "exit=$? -> $out ($(wc -c <"$out" | tr -d ' ') bytes)"
