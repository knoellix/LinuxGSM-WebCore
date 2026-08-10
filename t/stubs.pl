# t/stubs.pl — Webmin-Stubs für Unit-Tests
# Usage: require 't/stubs.pl'; (vor dem require des Moduls)
use strict;
use warnings;

# Webmin package globals
our ($module_root, $current_lang, $config_directory);
our (%text, %config, %gconfig, %in);

$module_root       = 't';
$current_lang      = 'en';
$config_directory  = '/dev/null';

# Stub: read_file — parst key=value Dateien in einen Hash
sub read_file {
    my ($file, $hash_ref) = @_;
    return unless defined $file && -f $file;
    open(my $fh, '<', $file) or return;
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || !/=/;
        my ($k, $v) = split(/=/, $_, 2);
        $hash_ref->{$k} = $v if defined $k && defined $v;
    }
    close($fh);
}

# Stub: system_logged — führt Befehl aus, gibt Exit-Code zurück
sub system_logged {
    return system($_[0]);
}

# Stub: check_referer — CSRF-Check, no-op in Tests
sub check_referer { return 1; }

# Stub: html_escape — minimal HTML escaping
sub html_escape {
    my ($s) = @_;
    $s //= '';
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

# Stub: init_config — no-op in tests (Webmin initializes this in production)
sub init_config { return 1; }

# Stub: write_file — schreibt key=value Paare in eine Datei
sub write_file {
    my ($file, $hash_ref) = @_;
    open(my $fh, '>', $file) or return;
    for my $k (sort keys %$hash_ref) {
        print $fh "$k=$hash_ref->{$k}\n";
    }
    close($fh);
}

# Stub: make_dir — erstellt Verzeichnis mit gegebenen Rechten
sub make_dir {
    my ($dir, $perms) = @_;
    mkdir $dir, ($perms // 0755) unless -d $dir;
}

# Stub: foreign_require — no-op (ACL-Modul nicht verfügbar in Tests)
sub foreign_require { return 1; }

# error() wird in Tests NICHT als Stub definiert — jedes Test-File
# definiert es selbst (manche wollen es fangen, manche nicht).

# Stub: ACL-Verzeichnis für Tests (von Tests auf tempdir gesetzt)
our $stub_acl_dir = '/tmp/webmin-stub-acl';

# Stub: get_module_acl — liest key=value aus $stub_acl_dir/$module/$user
sub get_module_acl {
    my ($user, $module) = @_;
    my %acl;
    my $file = "$stub_acl_dir/$module/$user";
    return %acl unless defined $file && -f $file;
    open(my $fh, '<', $file) or return %acl;
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || !/=/;
        my ($k, $v) = split(/=/, $_, 2);
        $acl{$k} = $v if defined $k && defined $v;
    }
    close($fh);
    return %acl;
}

# Stub: save_module_acl — schreibt key=value nach $stub_acl_dir/$module/$user
sub save_module_acl {
    my ($acl_ref, $user, $module) = @_;
    my $dir = "$stub_acl_dir/$module";
    mkdir $dir unless -d $dir;
    open(my $fh, '>', "$dir/$user") or return 0;
    for my $k (sort keys %$acl_ref) {
        print $fh "$k=$acl_ref->{$k}\n";
    }
    close($fh);
    return 1;
}

# Stubs: log_* — no-op so libs can call them without require logging.pl
sub log_error  {}
sub log_action {}
sub log_debug  {}

1;
