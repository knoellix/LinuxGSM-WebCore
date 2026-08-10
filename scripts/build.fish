#!/usr/bin/env fish
# Colored build from fish:  fish scripts/build.fish
# Same as: bash scripts/build.sh  (colors work in both)

set -l script_dir (dirname (status filename))
exec bash "$script_dir/build.sh" $argv
