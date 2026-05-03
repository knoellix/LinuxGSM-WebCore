# LinuxGSM-WebCore - Firewall management via ufw or iptables
use strict;
use warnings;

# Guard against duplicate-load: test stubs or prior requires already defined
# firewall_status → skip the whole file to avoid "redefined" warnings.
return 1 if defined &firewall_status;

# Open a UDP+TCP port for a game server.
sub firewall_open_port {
    my ($port, $proto) = @_;
    $port  = int($port);
    $proto = ($proto && $proto eq 'udp') ? 'udp' : 'tcp';

    if (&has_ufw()) {
        &system_logged("ufw allow $port/$proto");
    } else {
        &system_logged("iptables -A INPUT -p $proto --dport $port -j ACCEPT");
    }
}

# Close a port when a game server is deprovisioned.
sub firewall_close_port {
    my ($port, $proto) = @_;
    $port  = int($port);
    $proto = ($proto && $proto eq 'udp') ? 'udp' : 'tcp';

    if (&has_ufw()) {
        &system_logged("ufw delete allow $port/$proto");
    } else {
        &system_logged("iptables -D INPUT -p $proto --dport $port -j ACCEPT");
    }
}

sub has_ufw {
    return -x '/usr/sbin/ufw' || -x '/usr/bin/ufw';
}

# Internal: return ufw status output (split out for testability)
sub _ufw_status_output {
    return `timeout 2 ufw status 2>/dev/null`;
}

# Check if a port is open in the firewall.
# Returns 1 if open, 0 if closed or unknown.
sub firewall_status {
    my ($port) = @_;
    $port = int($port);
    if (&has_ufw()) {
        my $out = &_ufw_status_output();
        return 1 if $out =~ /^$port\b[^\n]*ALLOW/m;
        return 1 if $out =~ /^$port\/(?:tcp|udp)\b[^\n]*ALLOW/m;
        return 0;
    } else {
        # iptables: check rule via system_logged (Webmin handles privilege escalation)
        my $rc = &system_logged("timeout 2 iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null");
        return $rc == 0 ? 1 : 0;
    }
}

1;
