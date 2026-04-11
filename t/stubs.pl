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

# error() wird in Tests NICHT als Stub definiert — jedes Test-File
# definiert es selbst (manche wollen es fangen, manche nicht).

1;
