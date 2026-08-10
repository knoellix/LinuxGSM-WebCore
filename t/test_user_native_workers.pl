#!/usr/bin/perl
# t/test_user_native_workers.pl
# Invariant (drop-root-runtime plan): user-native workers (*_user.sh) run as the
# game user and must NOT contain an internal `su -s /bin/bash` privilege step.
# The only allowed su is the dispatch privilege-drop in Perl (user_worker_launch_cmd).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

chdir "$Bin/.." or die "Cannot chdir to repo root: $!\n";

my @workers = glob('src/scripts/*_user.sh');
ok(scalar(@workers) > 0, 'found user-native worker scripts');

for my $path (@workers) {
    open(my $fh, '<', $path) or do { fail("cannot read $path: $!"); next; };
    my @offending;
    while (my $line = <$fh>) {
        # Ignore comment lines (leading whitespace + #).
        next if $line =~ /^\s*#/;
        push @offending, $. if $line =~ /\bsu\s+-s\s+\/bin\/bash\b/;
    }
    close($fh);
    is(scalar(@offending), 0,
        "$path contains no internal 'su -s /bin/bash' (line(s): @offending)");
}

# apt is centralized in provision_deps.sh (one-time root bootstrap). The former
# apt-owning install workers must not call apt-get anymore.
for my $p ('src/scripts/setup_lgsm.sh', 'src/scripts/steamcmd_install.sh') {
    if (-f $p) {
        open(my $fh, '<', $p) or do { fail("cannot read $p: $!"); next; };
        my $bad = 0;
        while (my $l = <$fh>) {
            next if $l =~ /^\s*#/;
            $bad++ if $l =~ /\bapt-get\b/;
        }
        close($fh);
        is($bad, 0, "$p contains no apt-get (moved to provision_deps.sh)");
    }
}

# provision_deps.sh and module_bootstrap_deps.sh are apt owners (root bootstrap).
for my $apt_script (qw(src/scripts/provision_deps.sh src/scripts/module_bootstrap_deps.sh)) {
    if (-f $apt_script) {
        open(my $fh, '<', $apt_script) or die "cannot read $apt_script: $!\n";
        local $/;
        my $s = <$fh>;
        close($fh);
        like($s, qr/apt-get install/, "$apt_script installs system packages");
    }
}

# manage.cgi must not rm serverfiles as root during steamcmd reinstall dispatch.
if (-f 'src/manage.cgi') {
    open(my $fh, '<', 'src/manage.cgi') or die "cannot read manage.cgi: $!\n";
    local $/;
    my $src = <$fh>;
    close($fh);
    ok($src !~ /rm\s+-rf\s+'\$server_dir\/serverfiles'/, 'manage.cgi: no root rm serverfiles in dispatch');
}

# game_action_user.sh must self-verify it runs as the target user.
my $ga = 'src/scripts/game_action_user.sh';
if (-f $ga) {
    open(my $fh, '<', $ga) or die "cannot read $ga: $!\n";
    local $/;
    my $src = <$fh>;
    close($fh);
    like($src, qr/job_log_init_as_user/, "$ga uses user-native job logging");
    like($src, qr/must run as .*UNIX_USER/, "$ga self-verifies effective user");
    like($src, qr/PIPESTATUS\[1\]/, "$ga uses LGSM exit code from yes|install pipe");
    like($src, qr/LGSM_RC="\$\{PIPESTATUS\[0\]\}"/, "$ga checks worker exit after tee pipe");
}

done_testing();
