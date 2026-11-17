#!/bin/bash

if [[ -f ./grepback ]]; then
  echo -e "==================== TEST OUTPUT 1 ====================\n\n" > test_results
  ./grepback -n "\w+(?= :: proc)" parser.odin >> test_results 2>&1 
  echo -e "\n\n==================== TEST OUTPUT 2 ====================\n\n" >> test_results
  ./grepback -o "parse_(?!atom\b|alt\b)\w+" parser.odin >> test_results 2>&1 
  echo -e "\n\n==================== TEST OUTPUT 3 ====================\n\n" >> test_results
  ./grepback -o "(?<=\.)[A-Z][A-Za-z_]+" parser.odin >> test_results 2>&1
  echo -e "\n\n==================== TEST OUTPUT 4 ====================\n\n" >> test_results
  ./grepback -n "(?<!return )new_node\(" parser.odin >> test_results 2>&1
  echo -e "\n\n==================== TEST OUTPUT 5 ====================\n\n" >> test_results
  ./grepback -in "bitmap_(digit|word|space)" parser.odin >> test_results 2>&1
  echo -e "\n\n==================== TEST OUTPUT 6 ====================\n\n" >> test_results
  cat vm.odin | ./grepback -c "case \." >> test_results 2>&1
  echo -e "\n\n==================== TEST OUTPUT 7 ====================\n\n" >> test_results
  ./grepback -n -- "-> \(" parser.odin >> test_results 2>&1
  echo -e "\n\n==================== TEST OUTPUT 8 ====================\n\n" >> test_results
  ./grepback "(?<=parse_\w+)proc" parser.odin >> test_results 2>&1 
  echo -e "\n\n==================== TEST OUTPUT 9 ====================\n\n" >> test_results
  echo "hello" | ./grepback >> test_results 2>&1
  echo -e "\n\n==================== TEST OUTPUT 10 ====================\n\n" >> test_results
  ./grepback -p item_12 -p item_99 -x item_ab >> test_results 2>&1
  echo -e "\n\n==================== TEST OUTPUT 11 ====================\n\n" >> test_results
  ./grepback -p foo_user -p foo_guest -x foo_admin >> test_results 2>&1
  echo -e "\n\n==================== TEST OUTPUT 12 ====================\n\n" >> test_results
  ./grepback -p foo_user -p foo_guest -p foo_root -x foo_admin >> test_results 2>&1
  echo -e "\n\n==================== TEST OUTPUT 13 ====================\n\n" >> test_results
  ./grepback -u -p ERR_404 -p ERR_503 -x "2026-11-17 INFO: healthy" -x "2026-11-17 WARN: ERR_200" >> test_results 2>&1 
else
  echo "Binary not built yet."
fi

