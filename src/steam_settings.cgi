#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
&init_config();

our %in;
&ReadParse(\%in);

my $qs = $ENV{QUERY_STRING} // '';
$qs =~ s/[^\w=&\.\-%\+]//g;
&redirect('integrations.cgi' . ($qs ? '?' . $qs : ''));
exit;
