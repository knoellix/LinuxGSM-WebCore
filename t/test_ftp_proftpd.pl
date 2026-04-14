#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 10;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/..";

chdir "$Bin/.." or die "Cannot chdir to project root: $!";

sub system_logged { return 0 }

require 'src/lib/ftp_proftpd.pl';

my $tmp = tempdir(CLEANUP => 1);
mkdir "$tmp/conf.d";

open(my $fh, '>', "$tmp/proftpd.conf") or die $!;
print $fh "ServerName test\n";
print $fh "Include conf.d/*.conf\n";
close $fh;

open($fh, '>', "$tmp/conf.d/base.conf") or die $!;
print $fh "AuthUserFile $tmp/ftpd.passwd\n";
print $fh "DefaultRoot ~\n";
print $fh "TLSEngine on\n";
print $fh "TLSRequired on\n";
print $fh "PassivePorts 50000 50100\n";
close $fh;

open($fh, '>', "$tmp/ftpd.passwd") or die $!;
print $fh "fivem_ftp:x:33:33::/home/fivem:/bin/false\n";
close $fh;

my @files = discover_proftpd_config_files("$tmp/proftpd.conf");
ok(scalar(@files) >= 2, 'discover_proftpd_config_files resolves include files');

{
    local *discover_proftpd_config_files = sub { return ("$tmp/proftpd.conf", "$tmp/conf.d/base.conf"); };
    local *find_main_proftpd_config = sub { return "$tmp/proftpd.conf"; };
    my %state = discover_ftp_state();
    is($state{'auth_user_file'}, "$tmp/ftpd.passwd", 'discover_ftp_state reads AuthUserFile');
    is(scalar(@{$state{'warnings'}}), 2, 'discover_ftp_state warns only about missing cert and key');
}

my @users = parse_ftpd_passwd("$tmp/ftpd.passwd");
is($users[0]{'name'}, 'fivem_ftp', 'parse_ftpd_passwd parses username');

{
    local *find_main_proftpd_config = sub { return undef; };
    my %state = discover_ftp_state();
    is(scalar(@{$state{'warnings'}}), 1, 'missing main config returns single base warning');
}

{
    no warnings 'once';
    local $main::config{'proftpd_main_config'} = "$tmp/proftpd.conf";
    is(find_main_proftpd_config(), "$tmp/proftpd.conf", 'config override path is preferred');
}

# Test directory-style IncludeOptional (Debian default: IncludeOptional /etc/proftpd/conf.d/)
{
    my $tmp2 = tempdir(CLEANUP => 1);
    mkdir "$tmp2/conf.d";
    open(my $fh2, '>', "$tmp2/proftpd.conf") or die $!;
    print $fh2 "ServerName test2\n";
    print $fh2 "IncludeOptional $tmp2/conf.d/\n";
    close $fh2;
    open($fh2, '>', "$tmp2/conf.d/tls.conf") or die $!;
    print $fh2 "TLSEngine on\n";
    close $fh2;
    my @f2 = discover_proftpd_config_files("$tmp2/proftpd.conf");
    my %f2_set = map { $_ => 1 } @f2;
    ok($f2_set{"$tmp2/conf.d/tls.conf"}, 'discover_proftpd_config_files loads conf.d via directory include');
}

# FTP password storage tests
{
    my $cfg_dir = tempdir(CLEANUP => 1);

    save_ftp_password($cfg_dir, 'inst1', 'secret123');
    my $got = read_ftp_password($cfg_dir, 'inst1');
    is($got, 'secret123', 'save_ftp_password/read_ftp_password round-trip');

    my $mode = (stat("$cfg_dir/ftp_pass_inst1"))[2] & 07777;
    is($mode, 0600, 'saved password file has mode 0600');

    delete_ftp_password($cfg_dir, 'inst1');
    ok(!-f "$cfg_dir/ftp_pass_inst1", 'delete_ftp_password removes file');
}

