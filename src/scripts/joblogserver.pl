#!/usr/bin/perl
# WebSocket server: stream background job output (tail -F) to xterm.js (Webmin pattern).
# Usage: joblogserver.pl <port> <output_file_path>
# Env: SESSION_ID — validated via miniserv websocket key rewrite.
use strict;
use warnings;
no warnings 'uninitialized';

BEGIN {
    if (!$ENV{'WEBMIN_CONFIG'} || !-f "$ENV{'WEBMIN_CONFIG'}/miniserv.conf") {
        for my $c ('/etc/webmin', '/usr/local/etc/webmin') {
            if (-f "$c/miniserv.conf") {
                $ENV{'WEBMIN_CONFIG'} = $c;
                last;
            }
        }
        $ENV{'WEBMIN_CONFIG'} ||= '/etc/webmin';
    }
    my $webmin_root;
    if (open(my $cf, '<', "$ENV{'WEBMIN_CONFIG'}/miniserv.conf")) {
        while (my $line = <$cf>) {
            if ($line =~ /^root=(.+)/) {
                $webmin_root = $1;
                chomp($webmin_root);
                last;
            }
        }
        close($cf);
    }
    if (!$webmin_root) {
        my $here = __FILE__;
        $here =~ s{/[^/]+$}{};    # scripts/
        $here =~ s{/[^/]+$}{};    # module/
        $webmin_root = $here;
    }
    push(@INC, $webmin_root) if $webmin_root && -d $webmin_root;
}
use WebminCore;

our ($module_name);
$module_name ||= 'linuxgsm-webcore';
&init_config();

sub _joblog_tail_bin {
    return '/usr/bin/tail' if -x '/usr/bin/tail';
    return '/bin/tail'    if -x '/bin/tail';
    return 'tail';
}

sub _joblog_start_tail {
    my ($output_file) = @_;
    my $tail_bin = _joblog_tail_bin();
    pipe(my $rpipe, my $wpipe) or die "pipe failed: $!\n";
    my $pid = fork();
    if (!defined $pid) {
        die "fork tail failed: $!\n";
    }
    if (!$pid) {
        close($rpipe);
        open(STDOUT, '>&', fileno($wpipe)) or exit(1);
        open(STDERR, '>&', fileno($wpipe)) or exit(1);
        close($wpipe);
        exec($tail_bin, '-n', '500', '-F', $output_file)
            or die "exec tail failed: $!\n";
    }
    close($wpipe);
    return ($rpipe, $pid);
}

unless (caller) {
    my ($port, $output_file) = @ARGV;
    $port =~ s/\D//g;
    $main::session_id = $ENV{'SESSION_ID'} if $ENV{'SESSION_ID'};
    if (!$port || !defined $output_file || $output_file !~ m|^/home/[a-z][a-z0-9_-]{0,30}/jobs/[0-9a-f]{16}/output$|) {
        &remove_miniserv_websocket($port, $module_name) if $port;
        die "usage: joblogserver.pl <port> </home/user/jobs/<id>/output>\n";
    }
    if (!-f $output_file) {
        open(my $cf, '>', $output_file) or die "cannot create $output_file: $!\n";
        close($cf);
    }

    my ($tailfh, $tail_pid) = _joblog_start_tail($output_file);
    if (!$tail_pid) {
        &remove_miniserv_websocket($port, $module_name);
        die "Failed to start tail for $output_file\n";
    }

    eval { require Net::WebSocket::Server; 1 }
        or do {
            &remove_miniserv_websocket($port, $module_name);
            kill('KILL', $tail_pid);
            die "Net::WebSocket::Server missing\n";
        };
    require IO::Socket::INET;

    if (fork()) {
        exit(0);
    }
    untie(*STDIN);
    close(STDIN);

    $SIG{'ALRM'} = sub {
        &remove_miniserv_websocket($port, $module_name);
        kill('KILL', $tail_pid) if $tail_pid;
        die "timeout waiting for websocket connection\n";
    };
    alarm(120);

    my ($wsconn, $buf);
    my $server_socket = IO::Socket::INET->new(
        Listen    => 5,
        LocalAddr => '127.0.0.1',
        LocalPort => $port,
        Proto     => 'tcp',
        ReuseAddr => 1,
    ) or do {
        &remove_miniserv_websocket($port, $module_name);
        kill('KILL', $tail_pid) if $tail_pid;
        die "failed to listen on port $port: $!\n";
    };

    Net::WebSocket::Server->new(
        listen => $server_socket,
        on_connect => sub {
            my ($serv, $conn) = @_;
            if ($wsconn) {
                $conn->disconnect();
                return;
            }
            $wsconn = $conn;
            alarm(0);
            $conn->on(
                handshake => sub {
                    my ($c, $handshake) = @_;
                    my $key = $handshake->req->fields->{'sec-websocket-key'};
                    my $sess = $main::session_id // $ENV{'SESSION_ID'};
                    if (!&verify_joblog_websocket_key($key, $sess)) {
                        $c->disconnect();
                    }
                },
                ready => sub {
                    my ($c) = @_;
                    $c->send_binary($buf) if length($buf // '');
                },
                utf8 => sub {
                    # Read-only log view — ignore keyboard input.
                },
                disconnect => sub {
                    &remove_miniserv_websocket($port, $module_name);
                    kill('KILL', $tail_pid) if $tail_pid;
                    exit(0);
                },
            );
        },
        watch_readable => [
            $tailfh => sub {
                my $chunk;
                my $ok = sysread($tailfh, $chunk, 8192);
                if (!defined $ok || $ok <= 0) {
                    &remove_miniserv_websocket($port, $module_name);
                    kill('KILL', $tail_pid) if $tail_pid;
                    exit(0);
                }
                if ($wsconn) {
                    $wsconn->send_binary($chunk);
                } else {
                    $buf .= $chunk;
                }
            },
        ],
    )->start;

    &remove_miniserv_websocket($port, $module_name);
    kill('KILL', $tail_pid) if $tail_pid;
}

sub verify_joblog_websocket_key {
    my ($key, $sess) = @_;
    return 0 if !defined($key) || !defined($sess) || $sess eq '';
    require MIME::Base64;
    my $dsess = MIME::Base64::encode_base64($sess);
    $key =~ s/\s//g;
    $dsess =~ s/\s//g;
    return 0 if $key eq '' || $dsess eq '';
    return $key eq $dsess ? 1 : 0;
}

1;
