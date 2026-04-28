#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 25;
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
