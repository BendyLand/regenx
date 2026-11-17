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
else
  echo "Binary not built yet."
fi

