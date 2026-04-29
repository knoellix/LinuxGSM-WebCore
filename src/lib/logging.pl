# LinuxGSM-WebCore - Structured logging
package main;
use strict;
use warnings;

our (%config);

sub log_error {
    my ($msg) = @_;
    warn "[LGSM-ERROR] $msg\n";
}

sub log_action {
    my ($action, $object, $params) = @_;
    $params //= {};
    &webmin_log($action, 'lgsm', $object, $params);
}

sub log_debug {
    my ($msg) = @_;
    return unless $config{debug_logging};
    warn "[LGSM-DEBUG] $msg\n";
}

1;
