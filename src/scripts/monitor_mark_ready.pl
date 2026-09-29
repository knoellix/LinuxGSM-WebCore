#!/usr/bin/env perl
# monitor_mark_ready.pl — Clear starting/paused → running after successful start.
# Runs as the game user (direct write to $SERVER_DIR/.monitor/state).
# Usage: monitor_mark_ready.pl <server_dir>
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

my ($server_dir) = @ARGV;
if (!defined $server_dir || $server_dir eq '') {
    print STDERR "Usage: monitor_mark_ready.pl <server_dir>\n";
    exit 2;
}

require "$FindBin::Bin/../lib/monitor.pl";

# No instance id / config_dir needed: state lives under $server_dir/.monitor.
# set_monitor_ready_after_start only flips starting|paused → running.
set_monitor_ready_after_start($server_dir, undef, undef);
exit 0;
