# LinuxGSM-WebCore - Firewall management via Webmin firewall API (UFW/iptables fallback)
use strict;
use warnings;

# Guard against duplicate-load: test stubs or prior requires already defined
# firewall_status → skip the whole file to avoid "redefined" warnings.
return 1 if defined &firewall_status;

sub _firewall_webmin_open {
    my ($port, $proto) = @_;
    return 0 unless defined &foreign_check && &foreign_check('firewall');
    eval {
        &foreign_require('firewall', 'firewall-lib.pl');
        1;
    } or return 0;
    if (defined &allow_in_port) {
        &allow_in_port($port, $proto, "LinuxGSM-WebCore $port/$proto");
        return 1;
    }
    return 0;
}

sub _firewall_webmin_close {
    my ($port, $proto) = @_;
    return 0 unless defined &foreign_check && &foreign_check('firewall');
    eval {
        &foreign_require('firewall', 'firewall-lib.pl');
        1;
    } or return 0;
    if (defined &delete_in_port) {
        &delete_in_port($port, $proto);
        return 1;
    }
    return 0;
}

# Open a UDP+TCP port for a game server. Returns 1 on success.
sub firewall_open_port {
    my ($port, $proto) = @_;
    $port  = int($port);
    return 0 unless $port > 0;
    $proto = ($proto && $proto eq 'udp') ? 'udp' : 'tcp';

    # Idempotent: port already visible in status → OK.
    return 1 if &firewall_status($port);

    my $rc = 0;
    if (&_firewall_webmin_open($port, $proto)) {
        return &firewall_status($port) ? 1 : 0;
    }
    if (&has_ufw()) {
        $rc = &system_logged("ufw allow $port/$proto");
    } else {
        $rc = &system_logged("iptables -A INPUT -p $proto --dport $port -j ACCEPT");
    }
    return 0 if $rc != 0;
    return &firewall_status($port) ? 1 : 0;
}

# Close a port when a game server is deprovisioned. Returns 1 on success.
sub firewall_close_port {
    my ($port, $proto) = @_;
    $port  = int($port);
    return 0 unless $port > 0;
    $proto = ($proto && $proto eq 'udp') ? 'udp' : 'tcp';

    return 1 unless &firewall_status($port);

    my $rc = 0;
    if (&_firewall_webmin_close($port, $proto)) {
        return &firewall_status($port) ? 0 : 1;
    }
    if (&has_ufw()) {
        $rc = &system_logged("ufw delete allow $port/$proto");
    } else {
        $rc = &system_logged("iptables -D INPUT -p $proto --dport $port -j ACCEPT");
    }
    return 0 if $rc != 0;
    return &firewall_status($port) ? 0 : 1;
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
