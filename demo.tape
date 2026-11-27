# Cortado demo. Run it from the repository root: vhs demo.tape
#
# The demo runs in a throwaway directory with its own CLAUDE_CONFIG_DIR, so it
# never reads or writes ~/.claude. The sample sessions are JSON files shaped
# like the data Claude Code pipes to its statusline command.

Output demo.gif

Set Shell "bash"
Set FontSize 15
Set Width 1700
Set Height 400
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms
Set WaitTimeout 15s
Set WaitPattern /coffee-shop \$$/

Hide
Type 'export CORTADO_HOME="$PWD" PS1="\[\e[1;36m\]coffee-shop\[\e[0m\] $ " demo="$(mktemp -d /tmp/cortado-demo.XXXXXX)"'
Enter
Type 'unset PROMPT_COMMAND; export CLAUDE_CONFIG_DIR="$demo/claude" && mkdir -m 700 "$CLAUDE_CONFIG_DIR"'
Enter
# One line at the recording's width, as in a wide Claude Code window.
Type 'printf "TERMINAL_WIDTH=165\nRIGHT_SIDE_RESERVE=0\n" > "$CLAUDE_CONFIG_DIR/cortado.conf" && chmod 600 "$CLAUDE_CONFIG_DIR/cortado.conf"'
Enter
Type 'cortado() { "$CORTADO_HOME/cortado.sh" "$@"; }'
Enter
# A small Node.js project with uncommitted work, for the git and project readings.
Type 'mkdir "$demo/coffee-shop" && cd "$demo/coffee-shop" && git init -q -b main'
Enter
Type 'printf "%s\n" "{\"name\":\"coffee-shop\"}" > package.json && git add . && git -c user.name=demo -c user.email=demo@example.com commit -qm init && printf "draft\n" > menu.md && printf "\n" >> package.json'
Enter
Type 'now=$(date +%s); ws="\"workspace\":{\"current_dir\":\"$PWD\"},\"model\":{\"display_name\":\"Opus 5.5\"}"'
Enter
Type 'printf "{%s}\n" "$ws" > "$demo/new-session.json"'
Enter
Type 'printf "{%s,\"context_window\":{\"context_window_size\":200000,\"current_usage\":{\"input_tokens\":82000}},\"cost\":{\"total_cost_usd\":1.84,\"total_duration_ms\":2700000},\"rate_limits\":{\"five_hour\":{\"used_percentage\":38,\"resets_at\":%s},\"seven_day\":{\"used_percentage\":71,\"resets_at\":%s}}}\n" "$ws" $((now + 7200)) $((now + 300000)) > "$demo/session.json"'
Enter
Type 'printf "{%s,\"context_window\":{\"context_window_size\":200000,\"current_usage\":{\"input_tokens\":166000}},\"cost\":{\"total_cost_usd\":14.20,\"total_duration_ms\":9000000},\"rate_limits\":{\"five_hour\":{\"used_percentage\":96,\"resets_at\":%s},\"seven_day\":{\"used_percentage\":81,\"resets_at\":%s}}}\n" "$ws" $((now + 1500)) $((now + 90000)) > "$demo/late-session.json"'
Enter
Type 'clear'
Enter
Show

Type "# Claude Code sends the session to Cortado on every update"
Enter
Sleep 400ms
Type "cortado < ../session.json"
Sleep 300ms
Enter
Wait
Sleep 3s

Type "# A new session has no usage yet, so Cortado shows -- instead of a guess"
Enter
Sleep 400ms
Type "cortado < ../new-session.json"
Sleep 300ms
Enter
Wait
Sleep 3s

Type "# Later on, the indicators warn as limits get close"
Enter
Sleep 400ms
Type "cortado < ../late-session.json"
Sleep 300ms
Enter
Wait
Sleep 4s

Hide
Type "clear"
Enter
Show

Type "# Change settings any time, without reinstalling"
Enter
Sleep 400ms
Type "cortado config --set DISPLAY_MODE=compact"
Sleep 300ms
Enter
Wait
Sleep 800ms
Type "cortado < ../session.json"
Sleep 300ms
Enter
Wait
Sleep 3s

Type "cortado config --set COLOR_THEME=monochrome"
Sleep 300ms
Enter
Wait
Sleep 800ms
Type "cortado < ../session.json"
Sleep 300ms
Enter
Wait
Sleep 4s

Hide
Type 'cd / && rm -rf "$demo"'
Enter
