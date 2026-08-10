#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
chdir "$Bin/.." or die "cannot chdir: $!";
use lib '.';

require 't/stubs.pl';

our (%config, $config_directory, $module_name,
     $module_config_directory, $module_config_file, $module_root);

$module_name = 'linuxgsm-webcore';
my $tmp = tempdir(CLEANUP => 1);
$config_directory = $tmp;
$module_config_directory = "$tmp/$module_name";
$module_root = 'src';
mkdir $module_config_directory;

require 'src/lib/module_config.pl';

ok(!module_config_bool('0'), 'module_config_bool: "0" is false');
ok(module_config_bool('1'),  'module_config_bool: "1" is true');

{
    %config = (
        modrinth_contact          => 'test@example.com',
        download_allow_custom_url => 1,
        curseforge_api_key        => 'secret-key',
    );
    ok(module_config_save(), 'module_config_save: returns ok');

    %config = ();
    %main::config = ();
    module_config_sync_in();
    is($config{modrinth_contact}, 'test@example.com', 'reload: modrinth_contact persisted');
    is($config{curseforge_api_key}, 'secret-key', 'reload: curseforge_api_key persisted');
}

{
    my $path = module_config_file_path();
    like($path, qr{/linuxgsm-webcore/config\z}, 'module_config_file_path uses module dir');
    ok(-f $path, 'config file exists on disk after save');
}

{
    %config = ();
    %main::config = ();
    module_config_sync_in();
    is($config{modrinth_contact}, 'test@example.com',
        'module_config_sync_in: loads from disk when package hash empty');
}

{
    # Simulate manage.cgi: init left main::config empty, disk has secrets
    %config = ();
    %main::config = ();
    $config{debug_logging} = 0;
    module_config_sync_in();
    is($config{curseforge_api_key}, 'secret-key',
        'merge: disk curseforge visible after partial package config');
}

ok(module_config_flash_mark_ok(), 'module_config_flash_mark_ok: writes flash file');
ok(module_config_flash_consume_ok(), 'module_config_flash_consume_ok: consumes fresh flash');
ok(!module_config_flash_consume_ok(), 'module_config_flash_consume_ok: second consume is false');

{
    my $fake_wm = tempdir(CLEANUP => 1);
    open(my $mf, '>', "$fake_wm/miniserv.conf") or die $!;
    print $mf "port=10000\n";
    close($mf);
    my $mod_cfg_dir = "$fake_wm/linuxgsm-webcore";
    mkdir $mod_cfg_dir or die $!;
    open(my $cf, '>', "$mod_cfg_dir/config") or die $!;
    print $cf "curseforge_api_key=test-bootstrap-key\n";
    close($cf);

    local $ENV{WEBMIN_CONFIG} = $fake_wm;

    no warnings 'redefine';
    undef *read_file if defined &read_file;

    %config = ();
    %main::config = ();
    $module_config_directory = '';
    $config_directory = '';
    $module_config_file = '';
    $module_name = '';

    ok(module_config_bootstrap_standalone($module_root),
        'module_config_bootstrap_standalone: ok');
    is($config{curseforge_api_key}, 'test-bootstrap-key',
        'bootstrap: loads curseforge_api_key without Webmin read_file');
    is(module_config_file_path(), "$mod_cfg_dir/config",
        'bootstrap: resolves module config path');
}

{
    my $job_home = tempdir(CLEANUP => 1);
    my $job_dir = "$job_home/testuser/jobs/0123456789abcdef";
    require File::Path;
    File::Path::make_path($job_dir) or die "mkdir $job_dir: $!";

    ok(write_job_worker_secrets($job_dir, 'testuser', {
        curseforge_api_key => 'job-cf-key',
        modrinth_contact   => 'test@example.com',
    }), 'write_job_worker_secrets: ok');

    ok(-f "$job_dir/.worker_secrets", 'worker secrets file exists');
    ok((stat("$job_dir/.worker_secrets"))[2] & 0600, 'worker secrets mode 0600');

    %config = ();
    local $ENV{WEBCORE_JOB_DIR} = $job_dir;
    ok(module_config_apply_job_secrets(), 'apply job secrets');
    is($config{curseforge_api_key}, 'job-cf-key', 'job secrets overlay CF key');
    is($config{modrinth_contact}, 'test@example.com', 'job secrets overlay modrinth');
}

done_testing();
