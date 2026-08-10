#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/module_config.pl';
require './lib/acl.pl';

our (%text, %config, %in);
&ReadParse(\%in);

# Legacy save handler for bookmarks to the old config.cgi page.
if ($in{'save'}) {
    &is_admin() or &error($text{'err_acl_admin_only'} || 'Access denied');
    &module_config_sync_in();
    $config{debug_logging} = &module_config_bool($in{'debug_logging'});
    &module_config_save()
        or &error($text{'integrations_save_failed'} || 'Einstellungen konnten nicht gespeichert werden.');
    &module_config_flash_mark_ok()
        or &error($text{'integrations_save_failed'} || 'Einstellungen konnten nicht gespeichert werden.');
    &redirect('integrations.cgi?saved=1&xnavigation=1');
    exit;
}

&redirect('integrations.cgi?xnavigation=1');
exit;
