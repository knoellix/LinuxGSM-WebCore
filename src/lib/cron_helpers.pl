# LinuxGSM-WebCore — shared cron.d quoting helpers
use strict;
use warnings;

return 1 if defined &cron_sq;

# Single-quote a value for safe embedding in a cron command (run via /bin/sh -c).
sub cron_sq {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ s/'/'\\''/g;
    return "'$v'";
}

1;
