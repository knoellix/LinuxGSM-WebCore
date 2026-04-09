# LinuxGSM-WebCore - Firewall management via ufw or iptables
use strict;
use warnings;

sub system_logged;

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
    return -x '/usr/sbin/ufw';
}

1;
