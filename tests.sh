#!/bin/bash

if [[ -f ./regenx ]]; then
  cmds=(
    './regenx -n "\w+(?= :: proc)" parser.odin'
    './regenx -o "parse_(?!atom\b|alt\b)\w+" parser.odin'
    './regenx -o "(?<=\.)[A-Z][A-Za-z_]+" parser.odin'
    './regenx -n "(?<!return )new_node\(" parser.odin'
    './regenx -in "bitmap_(digit|word|space)" parser.odin'
    './regenx "missing_target"'
    'cat vm.odin | ./regenx -c "case \." -'
    'printf "alpha\nfoo-bar\nbeta\n" | ./regenx -n "-" -'
    './regenx --no-recursive -c "package regenx" .'
    './regenx -n -- "-> \(" parser.odin'
    './regenx "(?<=parse_\w+)proc" parser.odin'
    'echo "hello" | ./regenx'
    './regenx -p item_12 -p item_99 -x item_ab'
    './regenx -p foo_user -p foo_guest -x foo_admin'
    './regenx -p foo_user -p foo_guest -p foo_root -x foo_admin'
    './regenx -u -p ERR_404 -p ERR_503 -x "2026-11-17 INFO: healthy" -x "2026-11-17 WARN: ERR_200"'
    './regenx -p "user_7" -p "user_42" -p "user_1089" -x "user_admin" -x "guest_42"'
    './regenx -p "env_prod" -p "env_stage" -p "env_dev" -p "env_qa" -x "env_test" -x "env_local"'
    './regenx -p "2026-11-17" -p "2025-01-09" -p "2024-12-31" -x "11/17/2026" -x "2026-1-9"'
    './regenx -u -p "2026-11-17T14:01:02Z status=502 latency=120ms" -p "2026-11-17T14:01:05Z status=504 latency=3000ms" -x "2026-11-17T14:01:08Z status=200 latency=12ms" -x "2026-11-17T14:01:09Z status=404 latency=4ms"'
  )

  : > test_results
  n=0
  for cmd in "${cmds[@]}"; do
    n=$((n + 1))
    # First header has no leading blank lines, matching the original output
    (( n > 1 )) && echo -e "\n\n" >> test_results
    echo -e "==================== TEST OUTPUT $n ====================\n\n" >> test_results
    eval "$cmd" >> test_results 2>&1
  done
else
  echo "Binary not built yet."
fi

