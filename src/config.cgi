#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/acl.pl';

our (%text, %config, %in);
&ReadParse(\%in);
&is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied');

if ($in{'save'}) {
    $config{debug_logging} = $in{'debug_logging'} ? 1 : 0;
    &save_module_config(\%config);
    &redirect('config.cgi');
    exit;
}

&header($text{'config_title'}, '');

print &ui_form_start('config.cgi', 'post');
print &ui_table_start($text{'config_title'}, "width=100%", 2);

print &ui_table_row(
    $text{'config_debug_logging'},
    &ui_radio('debug_logging', $config{debug_logging} ? 1 : 0,
        [[1, $text{'yes'}], [0, $text{'no'}]])
);

print &ui_table_end();
print &ui_submit($text{'acl_manage_save'} || 'Save');
print &ui_form_end();

&footer('index.cgi', $text{'index_title'});
