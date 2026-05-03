# LinuxGSM-WebCore - Error hint detection for worker output
use strict;
use warnings;

our %text;

my @_PATTERNS = (
    [ qr/Unable to locate package|E: Package '[^']+' has no installation candidate/i, 'hint_package_not_found' ],
    [ qr/lib\S+\.so[.\d]*: cannot open|error.*libssl|no such file.*\.so/i,           'hint_lib_missing' ],
    [ qr/command not found/i,                                                          'hint_command_not_found' ],
    [ qr/Permission denied/i,                                                          'hint_permission_denied' ],
    [ qr/No space left on device/i,                                                    'hint_no_space' ],
    [ qr/curl: \(\d+\)|wget: unable to resolve/i,                                     'hint_network_error' ],
    [ qr/Login Failure|Invalid Password|steamcmd.*login.*fail/i,                      'hint_steamcmd_login' ],
    [ qr/No server binary found|No executable server binary found/i,                   'hint_no_server_binary' ],
    [ qr/exited shortly after start/i,                                                  'hint_server_process_exited' ],
    [ qr/Wine runtime required|wine: command not found|wine64: command not found/i,   'hint_wine_required' ],
    [ qr/msvcp140\.dll.*unimplemented|ntlm_auth was not found/i,                       'hint_wine_required' ],
);

sub get_hint {
    my ($key) = @_;
    return '' unless defined $key && length $key;
    return $text{$key} // '';
}

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
