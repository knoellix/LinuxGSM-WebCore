#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

require "$Bin/stubs.pl";

our $root_directory;
my $fake_root = tempdir(CLEANUP => 1);
$root_directory = $fake_root;

{
    no warnings qw(redefine once);
    *main::foreign_check = sub {
        my ($mod) = @_;
        return $mod eq 'xterm' ? 1 : 0;
    };
    *main::get_webmin_version = sub { return '2.500'; };
}

require "$Bin/../src/lib/live_log.pl";

ok(live_log_xterm_module_installed(), 'xterm module reported installed');
ok(!live_log_xterm_assets_ok($fake_root), 'assets missing without files');

mkdir("$fake_root/xterm", 0755) or die $!;
for my $f (qw(xterm.css xterm.js xterm-addon-attach.js xterm-addon-fit.js)) {
    open(my $fh, '>', "$fake_root/xterm/$f") or die $!;
    close($fh);
}
ok(live_log_xterm_assets_ok($fake_root), 'assets ok when files present');

my $st = live_log_status($fake_root);
ok($st->{xterm_module}, 'status: xterm_module');
ok($st->{xterm_assets}, 'status: xterm_assets');
isa_ok($st->{perl_missing}, 'ARRAY', 'perl_missing is arrayref');

if (live_log_ready($fake_root)) {
    pass('live log ready when xterm + perl deps satisfied');
} else {
    ok(live_log_first_problem($fake_root), 'first_problem set when not ready');
}

my @apt = live_log_apt_packages();
ok(@apt >= 2, 'apt package list defined');

{
    our $module_root;
    $module_root = "$Bin/..";
    my @logged;
    no warnings qw(redefine once);
    local *main::system_logged = sub { push @logged, $_[0]; return 0; };
    install_live_log_apt_packages();
    ok(
        (grep { /module_bootstrap_deps\.sh/ && /live_log/ } @logged),
        'install_live_log_apt_packages calls module_bootstrap_deps.sh live_log'
    );
    ok(
        !(grep { /\bapt-get\b/ } @logged),
        'install_live_log_apt_packages does not call apt-get directly'
    );
}

{
    local $ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
    local $ENV{'WEBMIN_VAR'} = '/var/webmin';
    my $cmd = live_log_launch_jobserver_cmd(
        '12345', '/home/u/jobs/0123456789abcdef/output', 'sess',
        '/wm/linuxgsm-webcore', '/usr/share/webmin');
    like($cmd, qr{WEBMIN_CONFIG='/etc/webmin'}, 'launch uses global webmin config');
    like($cmd, qr{/scripts/joblogserver\.pl}, 'launch uses module script not wrapper');
}

{
    my $block = job_log_view_block("line1\nline2", id => 'test_log');
    like($block, qr/class="lgsm-job-log-view"/, 'block includes log view class');
    like($block, qr/class="lgsm-job-log-body"/, 'block includes log body wrapper');
    like($block, qr/class="lgsm-job-log-spacer"/, 'block includes bottom spacer');
    like($block, qr/id="test_log"/, 'block includes id');
    like($block, qr/querySelector\('#test_log'\)/, 'block includes scroll js');
    my $live = job_log_view_block("live\nlog", id => 'live_log', live => 1);
    like($live, qr/class="lgsm-job-log-scrollhost"/, 'live block uses scroll host');
    unlike($live, qr/MutationObserver/, 'live block skips auto-scroll observer');
    my $css = job_log_view_page_css();
    like($css, qr/lgsm-job-log-lock/, 'page css locks document scroll on live pages');
    like($css, qr/lgsm-job-log-scrollhost/, 'page css defines scroll host');
    like($css, qr/<meta charset="utf-8">/i, 'page css sets utf-8 meta');
    my $js = job_log_json_for_script({ runningMsg => "Läuft…", suffix => " — LGSM" });
    like($js, qr/\\u00e4/, 'script json escapes umlauts as unicode');
    unlike($js, qr/LÃ¤uft/, 'script json avoids raw mojibake bytes');
}

done_testing();
