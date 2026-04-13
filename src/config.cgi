#!/usr/bin/perl
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
