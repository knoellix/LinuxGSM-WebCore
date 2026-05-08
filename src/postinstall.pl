#!/usr/bin/perl
# postinstall.pl — called by Webmin after module installation
# Installs the monitor cron job into /etc/cron.d/

my $cron_src  = "$module_root/scripts/linuxgsm-webcore-monitor.cron";
my $cron_dest = "/etc/cron.d/linuxgsm-webcore-monitor";

if (-f $cron_src && !-f $cron_dest) {
    system("cp", $cron_src, $cron_dest);
    chmod(0644, $cron_dest);
}

1;
