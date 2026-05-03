#!/usr/bin/perl
# -------------------------------------------------------------------------
# LinuxGSM Webcore - Webmin Module
# Copyright (C) 2026 Christian Möllmann knoellix 128321164+knoellix@users.noreply.github.com
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License.
# -------------------------------------------------------------------------

# uninstall.cgi — called by Webmin before removing this module.
# Removes per-user ACL files from /etc/webmin/<module>/ so Webmin
# does not leave dangling references after uninstall.

do '../web-lib.pl';
&init_config();

our ($config_directory, $module_name, $module_config_directory);

# Remove all per-user ACL files we created under /etc/webmin/<module>/
if (opendir(my $dh, $module_config_directory)) {
    while (my $f = readdir($dh)) {
        next if $f =~ /^\./;
        my $path = "$module_config_directory/$f";
        unlink $path if -f $path;
    }
    closedir($dh);
}

1;
