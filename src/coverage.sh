#!/bin/bash

# This script runs menhir on every grammar in ../bench/good,
# aborting if it takes too long.

export OCAMLRUNPARAM=b
make clean || exit 1
make bootstrap || exit 1
rm log
for f in ../bench/good/*.mly ; do
  echo $f | tee -a log
  (timeout 10 time _stage2/menhir.native -v $f) 2>> log
done