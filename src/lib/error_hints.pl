# LinuxGSM-WebCore - Error hint detection for worker output
use strict;
use warnings;

our %text;

my @_PATTERNS = (
    [ qr/Unable to locate package/i,             'hint_package_not_found' ],
    [ qr/lib\S+\.so[.\d]*: cannot open/i,        'hint_lib_missing' ],
    [ qr/command not found/i,                     'hint_command_not_found' ],
    [ qr/Permission denied/i,                     'hint_permission_denied' ],
    [ qr/No space left on device/i,               'hint_no_space' ],
    [ qr/curl: \(\d+\)|wget: unable to resolve/i, 'hint_network_error' ],
);

sub detect_error_hint {
    my ($output) = @_;
    return '' unless defined $output && length $output;
    for my $pair (@_PATTERNS) {
        my ($pat, $key) = @$pair;
        return ($text{$key} // $key) if $output =~ $pat;
    }
    return '';
}

1;
