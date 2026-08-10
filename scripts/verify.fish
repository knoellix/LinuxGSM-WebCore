#!/usr/bin/env fish
# Colored verify from fish:  fish scripts/verify.fish

set -l script_dir (dirname (status filename))
exec bash "$script_dir/verify.sh" $argv
