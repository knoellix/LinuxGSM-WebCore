#!/usr/bin/env perl
# Create a Webmin-visible job record for monitor-driven SteamCMD restarts.
# Called from monitor_instance.sh (root, cron). Prints 16-char job_id to stdout.
# Env: MODULE_ROOT (required). Args: <config_dir> <instance_id> <unix_user>
use strict;
use warnings;

BEGIN {
    no warnings 'redefine';
    *::log_error = sub { print STDERR @_, "\n" };
    *::log_debug = sub { };
}

my $module_root = $ENV{MODULE_ROOT} or die "MODULE_ROOT not set\n";
push @INC, "$module_root/lib";

our $config_directory;
my ($config_dir, $instance_id, $unix_user) = @ARGV;
die "usage: monitor_create_job.pl <config_dir> <instance_id> <unix_user>\n"
    unless $config_dir && $instance_id && $unix_user;

$config_directory = $config_dir;

require 'jobs.pl';

my $jid = create_job($unix_user);
write_job_meta($jid, $instance_id, 'monitor_restart', $unix_user,
    { trigger => 'monitor' });
print $jid;
