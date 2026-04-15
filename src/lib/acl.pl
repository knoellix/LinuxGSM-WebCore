# LinuxGSM-WebCore - ACL-Verwaltung via Webmin-Modul-ACL-System
#
# %access wird von Webmins init_config() automatisch befüllt aus:
#   /etc/webmin/<module_name>/<webmin_user>  (oder defaultacl als Fallback)
#
# Felder:
#   can_create  0/1   Darf Wizard/neue Server anlegen
#   can_scan    0/1   Darf Scan-Seite aufrufen
#   servers     '*' oder Leerzeichen-getrennte Unix-Usernamen
use strict;
use warnings;

our (%access, $module_name);

# Returns 1 if current Webmin user may create new game servers.
# Defaults to 1 if the key is absent (e.g. stale ACL file missing the key).
sub can_create { return !defined($access{'can_create'}) ? 1 : ($access{'can_create'} ? 1 : 0) }

# Returns 1 if current Webmin user may run the scanner.
# Defaults to 1 if the key is absent.
sub can_scan { return !defined($access{'can_scan'}) ? 1 : ($access{'can_scan'} ? 1 : 0) }

# Returns list of Unix usernames the current user may manage.
# Returns ('*') for unrestricted access, including when the key is absent
# (stale ACL file written before the servers field was introduced).
sub allowed_servers {
    return ('*') unless defined $access{'servers'};
    my $s = $access{'servers'};
    $s =~ s/^\s+|\s+$//g;
    return ('*') if $s eq '' || $s eq '*';
    return grep { /\S/ } split /\s+/, $s;
}

# Returns 1 if the current user has unrestricted (admin-level) access.
sub is_admin {
    return 1 if grep { $_ eq '*' } allowed_servers();
    return 0;
}

# Returns the SFTP unix username associated with a game server, or undef.
# Convention: <game_user>-ftp — no extra storage needed.
sub get_sftp_user {
    my ($game_user) = @_;
    my $ftp_user = "${game_user}-ftp";
    return (getpwnam($ftp_user)) ? $ftp_user : undef;
}

# Returns 1 if the current user may manage the given instance (by script ID).
sub user_can_manage {
    my ($script_name) = @_;
    my @allowed = allowed_servers();
    return 1 if grep { $_ eq '*' } @allowed;
    return scalar grep { $_ eq $script_name } @allowed;
}

# Returns all instances the current user may manage.
# Admins (servers=*) get the full unfiltered list.
sub list_managed_instances {
    my @all = &list_instances();
    return @all if grep { $_ eq '*' } (allowed_servers());
    return grep {
        my $instance_key = $_->{'id'} // $_->{'user'} // '';
        user_can_manage($instance_key);
    } @all;
}

# Grants $webmin_user access to $script_name by appending to their servers list.
# No-op if already has access (including wildcard). Called by wizard/scan after install.
sub grant_server_access {
    my ($webmin_user, $script_name) = @_;
    my %acl = get_module_acl($webmin_user, $module_name);
    my @servers = grep { /\S/ } split /\s+/, ($acl{'servers'} // '');
    return if grep { $_ eq $script_name || $_ eq '*' } @servers;
    push @servers, $script_name;
    $acl{'servers'} = join(' ', @servers);
    save_module_acl(\%acl, $webmin_user, $module_name);
}

# Returns sorted list of Webmin usernames explicitly assigned to $script_name.
# Reads ACL files directly from the module root directory — this is where
# save_module_acl() stores them, and avoids fragile foreign_require('acl').
# Users with servers=* (admins) are excluded — they have implicit access.
sub get_server_owners {
    my ($script_name) = @_;
    my @owners;
    eval {
        my $mod_dir = &module_root_directory($module_name);
        -d $mod_dir or return;
        opendir(my $dh, $mod_dir) or return;
        while (my $file = readdir($dh)) {
            # Only process files whose names look like Webmin usernames;
            # skip source files, config, hidden files, and defaultacl.
            next unless $file =~ /^[a-zA-Z0-9._@\-]+$/ && -f "$mod_dir/$file";
            next if $file eq 'defaultacl';
            my %acl = &get_module_acl($file, $module_name);
            my @s = grep { /\S/ } split /\s+/, ($acl{'servers'} // '');
            # Only explicit assignments — wildcard (*) users have implicit access
            push @owners, $file if grep { $_ eq $script_name } @s;
        }
        closedir($dh);
    };
    warn "get_server_owners failed: $@" if $@;
    return sort @owners;
}

# Returns a sorted list of all Webmin usernames.
sub list_webmin_users {
    my @names;
    eval {
        foreign_require('acl', 'acl-lib.pl');
        @names = map { $_->{'name'} } acl::list_users();
    };
    warn "list_webmin_users failed: $@" if $@;
    return sort @names;
}

1;
