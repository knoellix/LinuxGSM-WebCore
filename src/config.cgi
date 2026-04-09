#!/usr/bin/perl
use strict;
use warnings;

require './lib/core.pl';

our (%text, %config, %in);
&ReadParse(\%in);
&header($text{'config_title'}, '');

print "<p>$text{'config_title'}</p>\n";
# TODO: module configuration options

&footer('index.cgi', $text{'index_title'});
