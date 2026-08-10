#!/usr/bin/perl
# postinstall.pl — called by Webmin after module installation/upgrade
use strict;
use warnings;

our ($module_root, $config_directory, $module_config_directory);

# Remove broken wrapper from earlier versions (create_wrapper used module config as WEBMIN_CONFIG).
for my $dir (grep { defined $_ && $_ ne '' } ($config_directory, $module_config_directory)) {
    my $stale = "$dir/joblogserver.pl";
    unlink($stale) if -f $stale;
}

# Merge new config keys from module template without overwriting existing values.
if (defined $module_root && defined $config_directory
    && -r "$module_root/config" && -d $config_directory) {
    my %defaults;
    eval { &read_file("$module_root/config", \%defaults) };
    if (%defaults) {
        my $cfg_file = "$config_directory/config";
        my %current;
        eval { &read_file($cfg_file, \%current) } if -r $cfg_file;
        my $changed = 0;
        for my $k (keys %defaults) {
            next if exists $current{$k};
            $current{$k} = $defaults{$k};
            $changed = 1;
        }
        eval { &write_file($cfg_file, \%current) } if $changed;
    }
}

# Migrate monitoring cron.
#
# Older versions installed a single /etc/cron.d entry that ran monitor_all.sh
# as root (whole-registry sweep). That contradicts LGSM's model and this build
# removes monitor_all.sh. Replace it with per-instance cron.d entries that run
# as the game user for ALL instances (LGSM `./script monitor` + native watchdog).
if (defined $module_root && defined $config_directory) {
    my $cron_file = '/etc/cron.d/linuxgsm-webcore-monitor';
    my $old_format = 0;
    if (-f $cron_file && open(my $cfh, '<', $cron_file)) {
        local $/;
        my $txt = <$cfh>;
        close($cfh);
        $old_format = 1 if defined $txt && $txt =~ /monitor_all\.sh/;
    }
    my $rebuilt = 0;
    eval {
        require "$module_root/lib/instance.pl";
        require "$module_root/lib/monitor.pl";
        if (defined &rebuild_monitor_cron) {
            $rebuilt = &rebuild_monitor_cron($module_root, $config_directory) ? 1 : 0;
        }
        1;
    };
    # If we could not write the new cron but the old (now-broken) one is still
    # present, remove it so cron does not keep invoking a deleted script.
    if (!$rebuilt && $old_format) {
        unlink($cron_file);
    }
}

# Rebuild scheduled-restart cron (per-instance daily lines as game user).
if (defined $module_root && defined $config_directory) {
    eval {
        require "$module_root/lib/schedule.pl";
        if (defined &rebuild_schedule_cron) {
            &rebuild_schedule_cron($module_root, $config_directory);
        }
        1;
    };
}

1;
