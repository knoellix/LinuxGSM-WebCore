#!/usr/bin/perl
# -------------------------------------------------------------------------
# LinuxGSM Webcore - Webmin Module
# Copyright (C) 2026 Christian Möllmann knoellix 128321164+knoellix@users.noreply.github.com
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License.
# -------------------------------------------------------------------------
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';

our (%text, %config, %in);
&ReadParse(\%in);
&header($text{'config_title'}, '');

print &ui_table_start($text{'config_title'}, "width=100%", 2);
# TODO: Modul-Konfigurationsoptionen
print &ui_table_end();

&footer('index.cgi', $text{'index_title'});
