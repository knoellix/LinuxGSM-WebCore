#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

require "$Bin/stubs.pl";
our (%text);
our $module_root = "$Bin/../src";

# Minimal Webmin UI stubs (forms only — same shape as production markup).
sub ui_form_start {
    my ($script, $method) = @_;
    $script //= '';
    $method //= 'post';
    return qq{<form action="$script" method="$method">\n};
}
sub ui_hidden {
    my ($name, $value) = @_;
    $name  //= '';
    $value //= '';
    return qq{<input type="hidden" name="$name" value="$value">\n};
}
sub ui_submit {
    my ($label) = @_;
    $label //= '';
    return qq{<input type="submit" value="$label">\n};
}
sub ui_form_end { return "</form>\n"; }

require "$Bin/../src/lib/core.pl";
require "$Bin/../src/lib/server_control_bar.pl";

%text = (
    mc_mods_page_instance_label => 'Instance',
    mc_mods_page_status_label   => 'Status',
    mc_mods_page_start_btn      => 'Start',
    mc_mods_page_stop_btn       => 'Stop',
    mc_mods_page_log_btn        => 'Log',
    mc_mods_page_back_manage    => 'Back to manage',
    jobs_action_restart         => 'Restart',
    mc_mods_page_readonly_hint  => 'Read-only mode: Start/Stop actions are disabled.',
);

subtest 'full bar when not readonly' => sub {
    my $html = server_control_bar_html(
        cgi                 => 'workshop.cgi',
        instance_id         => 'pz1',
        readonly            => 0,
        runtime_status_html => 'ONLINE',
    );
    like($html, qr/name="action" value="start"/,   'start action');
    like($html, qr/name="action" value="stop"/,    'stop action');
    like($html, qr/name="action" value="restart"/, 'restart action');
    like($html, qr/name="action" value="monitor"/, 'log/monitor action');
    like($html, qr/action="workshop\.cgi"/,        'posts to workshop.cgi');
    like($html, qr/name="instance_id" value="pz1"/, 'instance id');
    like($html, qr/ONLINE/, 'runtime badge present');
    like($html, qr/value="Restart"/, 'restart button label');
};

subtest 'readonly hides mutation actions' => sub {
    my $html = server_control_bar_html(
        cgi                 => 'mods.cgi',
        instance_id         => 'mc1',
        readonly            => 1,
        runtime_status_html => 'OFF',
    );
    unlike($html, qr/name="action" value="start"/,   'no start');
    unlike($html, qr/name="action" value="stop"/,    'no stop');
    unlike($html, qr/name="action" value="restart"/, 'no restart');
    like($html, qr/name="action" value="monitor"/,   'log still shown');
    like($html, qr/Read-only mode/,                  'readonly hint');
};

subtest 'extra status parts and action filter' => sub {
    my $extra = ui_instance_status_part('Monitor', 'running');
    my $html = server_control_bar_html(
        cgi                 => 'mods.cgi',
        instance_id         => 'mc1',
        readonly            => 0,
        runtime_status_html => 'ON',
        extra_status_parts  => [$extra],
        actions             => [qw(start log)],
        back_cgi            => 'manage.cgi',
    );
    like($html, qr/Monitor/, 'extra status part');
    like($html, qr/name="action" value="start"/, 'start kept');
    unlike($html, qr/name="action" value="stop"/, 'stop filtered out');
    unlike($html, qr/name="action" value="restart"/, 'restart filtered out');
    like($html, qr/name="action" value="monitor"/, 'log kept');
    unlike($html, qr/Back to manage/, 'back filtered out');
};

done_testing();
