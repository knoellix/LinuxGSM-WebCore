#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 64;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

require "$Bin/stubs.pl";
our $config_directory;
my $tmp = tempdir(CLEANUP => 1);
$config_directory = $tmp;

require "$Bin/../src/lib/jobs.pl";

# Test 1: create_job returns 16-char hex ID
my $job_id = create_job();
like($job_id, qr/^[0-9a-f]{16}$/, 'job_id is 16 hex chars');

# Test 2: job dir created
ok(-d "$tmp/jobs/$job_id", 'job directory created');

# Test 3: status file created with 'running'
ok(-f "$tmp/jobs/$job_id/status", 'status file created');

# Test 4: get_job_status returns 'running'
is(get_job_status($job_id), 'running', 'initial status is running');

# Test 5: get_job_output returns empty at offset 0
my ($out, $len) = get_job_output($job_id, 0);
is($out, '', 'initial output empty');

# Test 6: initial length is 0
is($len, 0, 'initial length 0');

# Test 7+8: append output and read with offset
open(my $fh, '>>', "$tmp/jobs/$job_id/output") or die $!;
print $fh "line1\nline2\n";
close($fh);
my ($new_out, $new_len) = get_job_output($job_id, 0);
is($new_out, "line1\nline2\n", 'full output read from offset 0');
my ($delta, $delta_len) = get_job_output($job_id, 6);
is($delta, "line2\n", 'delta read from offset 6');

# Test 9: get_job_error_hint returns empty when no file
is(get_job_error_hint($job_id), '', 'no error_hint file returns empty');

# Test 10: get_job_status returns undef for unknown job
is(get_job_status('nonexistent1234567'), undef, 'unknown job returns undef status');

# --- Task 2: write_job_meta + get_all_jobs + Zombie ---

# Test 11: write_job_meta erstellt meta-Datei
{
    my $jid = create_job();
    write_job_meta($jid, 'windrose_1', 'install_game', 'wuser');
    ok(-f "$tmp/jobs/$jid/meta", 'write_job_meta: meta file created');
}

# Test 12-15: meta-Inhalt korrekt
{
    my $jid = create_job();
    write_job_meta($jid, 'mc_srv', 'update', 'mcuser');
    my %m;
    open(my $f, '<', "$tmp/jobs/$jid/meta") or die $!;
    while (<$f>) { chomp; my ($k,$v)=split(/=/,$_,2); $m{$k}=$v if $k&&defined $v; }
    close $f;
    is($m{instance_id}, 'mc_srv',    'write_job_meta: instance_id correct');
    is($m{action},      'update',    'write_job_meta: action correct');
    is($m{unix_user},   'mcuser',    'write_job_meta: unix_user correct');
    like($m{started_at}, qr/^\d+$/, 'write_job_meta: started_at is numeric');
}

# Test 15b: write_job_meta optional extra hash (trigger)
{
    my $jid = create_job();
    write_job_meta($jid, 'srv1', 'monitor_restart', 'u1', { trigger => 'monitor' });
    my %m;
    open(my $f, '<', "$tmp/jobs/$jid/meta") or die $!;
    while (<$f>) { chomp; my ($k,$v)=split(/=/,$_,2); $m{$k}=$v if $k&&defined $v; }
    close $f;
    is($m{trigger}, 'monitor', 'write_job_meta: extra trigger=monitor');
}

# Test 16: get_all_jobs findet Job mit meta
{
    my $jid = create_job();
    write_job_meta($jid, 'gs_srv', 'setup_lgsm', 'gsuser');
    finish_job($jid, 'ok');
    my @jobs = get_all_jobs();
    my ($found) = grep { $_->{job_id} eq $jid } @jobs;
    ok(defined $found, 'get_all_jobs: finds job with meta');
}

# Test 17: get_all_jobs: korrekte Felder
{
    my $jid = create_job();
    write_job_meta($jid, 'gs_srv', 'update', 'gsuser');
    finish_job($jid, 'failed');
    my @jobs = get_all_jobs();
    my ($j) = grep { $_->{job_id} eq $jid } @jobs;
    is($j->{status},      'failed', 'get_all_jobs: status correct');
    is($j->{instance_id}, 'gs_srv', 'get_all_jobs: instance_id correct');
}

# Test 18b: get_all_jobs liefert trigger aus meta
{
    my $jid = create_job();
    write_job_meta($jid, 'srv_m', 'monitor_restart', 'um', { trigger => 'monitor' });
    finish_job($jid, 'ok');
    my @jobs = get_all_jobs();
    my ($j) = grep { $_->{job_id} eq $jid } @jobs;
    is($j->{trigger}, 'monitor', 'get_all_jobs: trigger field from meta');
}

# Test 19: Zombie-Erkennung — PGID nicht existent → status wird failed
{
    my $jid = create_job();
    write_job_meta($jid, 'test', 'install_game', 'u');
    # Schreibe eine PID die mit Sicherheit nicht läuft
    open(my $pf, '>', "$tmp/jobs/$jid/pgid") or die $!;
    print $pf "2147483647\n";
    close $pf;
    # Status ist noch 'running', aber Prozess existiert nicht
    my @jobs = get_all_jobs();
    my ($zj) = grep { $_->{job_id} eq $jid } @jobs;
    is($zj->{status}, 'failed', 'get_all_jobs: zombie detected and marked failed');
}

# --- Task 3: abort_job + delete_job + _auto_cleanup ---

# Test 20: abort_job setzt status=aborted
{
    my $jid = create_job();
    write_job_meta($jid, 'test', 'install_game', 'u');
    open(my $pf, '>', "$tmp/jobs/$jid/pgid") or die $!;
    print $pf "2147483647\n";   # nicht existent, kill schlägt lautlos fehl
    close $pf;
    abort_job($jid);
    is(get_job_status($jid), 'aborted', 'abort_job: sets status=aborted');
}

# Test 21: delete_job entfernt Job-Dir
{
    my $jid = create_job();
    write_job_meta($jid, 'test', 'update', 'u');
    finish_job($jid, 'ok');
    delete_job($jid);
    ok(!-d "$tmp/jobs/$jid", 'delete_job: removes job directory');
}

# Test 22: delete_job verweigert laufenden Job (gibt 0 zurück)
{
    my $jid = create_job();
    write_job_meta($jid, 'test', 'update', 'u');
    my $result = delete_job($jid);   # status=running
    is($result, 0, 'delete_job: refuses running job');
}

# Test 23: Job-Dir bleibt erhalten nach verweigertem delete
{
    my $jid = create_job();
    write_job_meta($jid, 'test', 'update', 'u');
    delete_job($jid);
    ok(-d "$tmp/jobs/$jid", 'delete_job: running job dir still exists');
}

# Test 24-25: _auto_cleanup_jobs behält max 10 abgeschlossene Jobs
{
    # Lösche alle bestehenden Jobs zuerst (sauberer Zustand)
    opendir(my $dh, "$tmp/jobs") or die $!;
    for my $jid (readdir($dh)) {
        next if $jid =~ /^\./;
        my $jdir = "$tmp/jobs/$jid";
        unlink "$jdir/$_" for qw(meta pgid status output error_hint pid);
        rmdir $jdir;
    }
    closedir $dh;

    # Erstelle 11 abgeschlossene Jobs (kein create_job, direkt anlegen)
    for my $i (1..11) {
        my $jid = sprintf('deadbeef%08d', $i);
        mkdir "$tmp/jobs/$jid", 0700 or next;
        open(my $sf, '>', "$tmp/jobs/$jid/status") or next;
        print $sf "ok\n"; close $sf;
        open(my $mf, '>', "$tmp/jobs/$jid/meta") or next;
        print $mf "instance_id=t\naction=update\nstarted_at=$i\nunix_user=u\n";
        close $mf;
    }
    # create_job löst _auto_cleanup_jobs aus — direkt danach prüfen (vor finish_job)
    my $new_jid = create_job();

    my @done = grep { $_->{status} ne 'running' } get_all_jobs();
    ok(scalar(@done) <= 10, '_auto_cleanup_jobs: keeps max 10 completed jobs');
    ok(scalar(@done) >= 1,  '_auto_cleanup_jobs: keeps at least the newest job');
}

# --- Task 3 (neu): create_job($unix_user) — User-Home-Style ---
our $_jobs_home_base;   # aus jobs.pl importiert
use File::Temp qw(tempdir);
my $fake_home = tempdir(CLEANUP => 1);
$_jobs_home_base = $fake_home;  # tests schreiben nach fake home statt /home

# Test 26: create_job mit unix_user erstellt Job im User-Home
{
    my $jid = create_job('gameuser1');
    like($jid, qr/^[0-9a-f]{16}$/, 'create_job(user): job_id ist 16 hex-Zeichen');
}

# Test 27: Job-Dir liegt im User-Home
{
    my $jid = create_job('gameuser1');
    ok(-d "$fake_home/gameuser1/jobs/$jid", 'create_job(user): Job-Dir in User-Home angelegt');
}

# Test 28: Pointer-Datei in config_directory/jobs/ (als FILE, nicht Dir)
{
    my $jid = create_job('gameuser1');
    ok(-f "$tmp/jobs/$jid", 'create_job(user): Pointer-Datei in config_directory/jobs/');
    ok(!-d "$tmp/jobs/$jid", 'create_job(user): Pointer ist FILE, kein Dir');
}

# Test 29: Pointer enthält korrekten Pfad
{
    my $jid = create_job('gameuser1');
    open(my $fh, '<', "$tmp/jobs/$jid") or die $!;
    my $path = <$fh>; close($fh); chomp $path;
    is($path, "$fake_home/gameuser1/jobs/$jid", 'Pointer enthält korrekten User-Home-Pfad');
}

# Test 30: _job_dir() löst Pointer auf
{
    my $jid = create_job('gameuser1');
    my $resolved = _job_dir($jid);
    is($resolved, "$fake_home/gameuser1/jobs/$jid", '_job_dir: löst Pointer auf User-Home-Pfad auf');
}

# Test 31: get_job_status funktioniert für User-Home-Job
{
    my $jid = create_job('gameuser1');
    is(get_job_status($jid), 'running', 'get_job_status: User-Home-Job hat Status running');
}

# Test 32: get_all_jobs enthält User-Home-Jobs
{
    my $jid = create_job('gameuser2');
    write_job_meta($jid, 'wind_1', 'start', 'gameuser2');
    finish_job($jid, 'ok');
    my @jobs = get_all_jobs();
    my ($found) = grep { $_->{job_id} eq $jid } @jobs;
    ok(defined $found, 'get_all_jobs: User-Home-Job wird gefunden');
}

# Test 33: delete_job entfernt User-Home-Dir UND Pointer
{
    my $jid = create_job('gameuser2');
    write_job_meta($jid, 'wind_1', 'stop', 'gameuser2');
    finish_job($jid, 'ok');
    delete_job($jid);
    ok(!-d "$fake_home/gameuser2/jobs/$jid", 'delete_job: User-Home-Dir entfernt');
    ok(!-f "$tmp/jobs/$jid", 'delete_job: Pointer-Datei entfernt');
}

# --- job_dispatch_verified + job_mark_launch_failed ---

# Test 34: job_dispatch_verified true when meta exists and status running
{
    my $jid = create_job('gameuser3');
    write_job_meta($jid, 'srv_x', 'update', 'gameuser3');
    ok(job_dispatch_verified($jid), 'job_dispatch_verified: true for running job with meta');
}

# Test 35: job_dispatch_verified false without meta
{
    my $jid = create_job();
    ok(!job_dispatch_verified($jid), 'job_dispatch_verified: false without meta');
}

# Test 36: job_mark_launch_failed sets failed + hint
{
    my $jid = create_job('gameuser3');
    write_job_meta($jid, 'srv_x', 'start', 'gameuser3');
    job_mark_launch_failed($jid);
    is(get_job_status($jid), 'failed', 'job_mark_launch_failed: status failed');
    is(get_job_error_hint($jid), 'hint_worker_never_started', 'job_mark_launch_failed: error hint set');
}

# Test 37: write_job_meta returns 1 on success
{
    my $jid = create_job();
    ok(write_job_meta($jid, 'i1', 'validate', 'u1'), 'write_job_meta: returns 1 on success');
}

# --- job live log helpers ---

# Test 38: validate_job_output_path accepts canonical home path
ok(validate_job_output_path('/home/mcuser/jobs/0123456789abcdef/output'),
    'validate_job_output_path: valid home job output path');

# Test 39: validate_job_output_path rejects invalid paths
ok(!validate_job_output_path('/tmp/evil/output'), 'validate_job_output_path: rejects /tmp');
ok(!validate_job_output_path('/home/mcuser/jobs/short/output'), 'validate_job_output_path: rejects short job id');

# Test 40: job_output_file resolves via pointer
{
    my $jid = create_job('gameuser1');
    is(job_output_file($jid), "$fake_home/gameuser1/jobs/$jid/output",
        'job_output_file: resolves user-home output path');
}

# Test 41-42: validate_job_for_instance
{
    my $jid = create_job('gameuser1');
    write_job_meta($jid, 'inst_a', 'update', 'gameuser1');
    ok(validate_job_for_instance($jid, 'inst_a'), 'validate_job_for_instance: match');
    ok(!validate_job_for_instance($jid, 'inst_b'), 'validate_job_for_instance: mismatch');
}

is(job_action_label('start', { jobs_action_start => 'Go' }), 'Go', 'job_action_label: localized');
is(job_action_label('custom_action', {}), 'custom_action', 'job_action_label: fallback');
is(job_next_instance_status('mc_java_setup'), 'mc_ready', 'job_next_instance_status: mc_java_setup');
is(job_next_instance_status('reinstall'), 'installed', 'job_next_instance_status: reinstall');
is(job_next_instance_status('update'), '', 'job_next_instance_status: unknown empty');

subtest 'user_worker_launch_cmd' => sub {
    ok(!defined user_worker_launch_cmd(worker => '/x/w.sh'),
        'undef without unix_user');
    ok(!defined user_worker_launch_cmd(unix_user => 'gs'),
        'undef without worker');

    my $cmd = user_worker_launch_cmd(
        unix_user   => 'gs_foo',
        module_root => '/opt/mod',
        worker      => '/opt/mod/scripts/mc_loader_install_user.sh',
        args        => [ '/home/gs_foo/jobs/abc', 'gs_foo', '/home/gs_foo/srv' ],
        env         => { WEBCORE_JOB_DIR => '/home/gs_foo/jobs/abc' },
    );
    like($cmd, qr/^setsid nohup su -s \/bin\/bash -c '/, 'starts with su privilege drop');
    like($cmd, qr/ &$/, 'backgrounded');
    like($cmd, qr/MODULE_ROOT=/, 'passes MODULE_ROOT');
    like($cmd, qr/WEBCORE_JOB_DIR=/, 'passes extra env');
    like($cmd, qr/exec bash /, 'execs worker via bash');
    like($cmd, qr/'gs_foo' &$/, 'ends with target user');

    # Injection safety: a single quote in an argument must not break quoting.
    my $evil = user_worker_launch_cmd(
        unix_user   => 'gs_foo',
        module_root => '/opt/mod',
        worker      => '/opt/mod/scripts/w.sh',
        args        => [ "/srv/a'b; touch /tmp/pwned" ],
    );
    is(system('bash', '-nc', $evil), 0, 'generated command is valid shell (balanced quotes)');
    unlike($evil, qr/a'b/, 'embedded single quote escaped, not left bare (no quote-break)');
};

# --- get_job_output_display: sanitize + tail truncate ---
{
    my $jid = create_job();
    my $big = ("Please answer yes or no.\r\n") x 20000;
    open(my $fh, '>', "$tmp/jobs/$jid/output") or die $!;
    print $fh $big;
    close($fh);
    my $disp = get_job_output_display($jid, 4096);
    like($disp, qr/earlier log output omitted/, 'display truncates huge logs');
    unlike($disp, qr/\r/, 'display strips carriage returns');
    like($disp, qr/Please answer yes or no\./, 'display keeps recent tail content');
}

# --- get_job_output_display: strip ANSI color codes ---
{
    my $jid = create_job();
    open(my $fh, '>', "$tmp/jobs/$jid/output") or die $!;
    print $fh "\e[32mSuccess!\e[0m normal and orphaned [37m__\e[0m\n";
    close($fh);
    my $disp = get_job_output_display($jid);
    is($disp, "Success! normal and orphaned __\n", 'display strips ANSI SGR codes');
    unlike($disp, qr/\[32m|\[0m|\[37m/, 'display removes orphaned CSI fragments');
}

# --- sync_monitor_job_pointers: game-user monitor_restart job ---
{
    no warnings 'redefine';
    *main::_load_registered = sub {
        return (
            pw1 => {
                user   => 'gs_pw',
                script => "$tmp/pw-1/pwserver",
            },
        );
    };
    $_jobs_home_base = $tmp;
    my $sdir = "$tmp/pw-1";
    my $jid  = 'aabbccddeeff0011';
    require File::Path;
    File::Path::make_path("$sdir/.monitor", "$tmp/gs_pw/jobs/$jid");
    open(my $mf, '>', "$tmp/gs_pw/jobs/$jid/meta") or die $!;
    print $mf "instance_id=pw1\naction=monitor_restart\nstarted_at=1700000000\nunix_user=gs_pw\n";
    close($mf);
    open(my $sf, '>', "$tmp/gs_pw/jobs/$jid/status") or die $!;
    print $sf "ok\n";
    close($sf);
    {
        open(my $of, '>', "$tmp/gs_pw/jobs/$jid/output") or die $!;
        print $of "monitor restart ok\n";
        close($of);
    }
    open(my $st, '>', "$sdir/.monitor/state") or die $!;
    print $st "status=running\nrestart_count=0\nwindow_start=1700000000\n";
    print $st "last_restart_at=1700000000\nlast_restart_job=$jid\n";
    close($st);

    ok(sync_monitor_job_pointers(), 'sync_monitor_job_pointers: registers pointer from state');
    ok(-f "$tmp/jobs/$jid", 'sync_monitor_job_pointers: pointer file created');
    my @jobs = get_instance_jobs('pw1');
    my ($found) = grep { $_->{job_id} eq $jid && ($_->{action} // '') eq 'monitor_restart' } @jobs;
    ok(defined $found, 'get_instance_jobs: monitor_restart visible for instance');
    is($found->{status}, 'ok', 'get_instance_jobs: monitor_restart status ok');
}

# --- _ensure_job_pointer: existing pointer is success ---
{
    my $jid = create_job('gs_pw');
    write_job_meta($jid, 'pw1', 'monitor_restart', 'gs_pw');
    finish_job($jid, 'ok');
    ok(_ensure_job_pointer($jid, 'gs_pw'), '_ensure_job_pointer: existing pointer returns success');
}
