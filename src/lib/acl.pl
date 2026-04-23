# LinuxGSM-WebCore - ACL-Verwaltung via Webmin-Modul-ACL-System
#
# %access wird von Webmins init_config() automatisch befüllt aus:
#   /etc/webmin/<module_name>/<webmin_user>  (oder defaultacl als Fallback)
#
# Felder:
#   role           admin | operator | viewer
#   servers        Leerzeichen-getrennte Instance-IDs (oder leer für admins)
#   can_manage_ftp 0/1  — gilt für operator und viewer; admins haben immer FTP
#
# Rückwärtskompatibilität:
#   servers=* ohne role-Feld → admin
#   Kein role-Feld, servers eingeschränkt → operator
use strict;
use warnings;

our (%access, $module_name, $remote_user);

# Returns effective role string: 'admin', 'operator', or 'viewer'.
# Webmin-native admins always get 'admin', regardless of the role field.
# Legacy: servers=* without role field → 'admin'.
sub effective_role {
    my $is_wbm_admin = 0;
    eval {
        foreign_require('acl', 'acl-lib.pl');
        $is_wbm_admin = acl::master_admin($remote_user) ? 1 : 0;
    };
    return 'admin' if $is_wbm_admin;

    # Legacy backwards-compat: old servers=* without explicit role → admin
    if (!defined $access{'role'} && defined $access{'servers'}
            && $access{'servers'} =~ /^\s*\*\s*$/) {
        return 'admin';
    }

    return $access{'role'} // 'operator';
}

# Returns 1 if current user is admin.
sub is_admin { return effective_role() eq 'admin' ? 1 : 0 }

# Returns 1 if current user may create new game servers (admin only).
sub can_create { return is_admin() }

# Returns 1 if current user may run the scanner (admin only).
sub can_scan { return is_admin() }

# Returns 1 if current user may manage FTP users.
# Admins always can; operator/viewer need can_manage_ftp=1.
sub can_manage_ftp {
    return 1 if is_admin();
    return $access{'can_manage_ftp'} ? 1 : 0;
}

# Returns list of Instance-IDs the current user may access.
# Returns ('*') for admins (unrestricted).
sub allowed_servers {
    return ('*') if is_admin();
    return ('*') unless defined $access{'servers'};
    my $s = $access{'servers'};
    $s =~ s/^\s+|\s+$//g;
    return ('*') if $s eq '' || $s eq '*';
    return grep { /\S/ } split /\s+/, $s;
}

# Returns 1 if current user may access the given instance ID.
sub user_can_manage {
    my ($id) = @_;
    return 1 if is_admin();
    my @allowed = allowed_servers();
    return 1 if grep { $_ eq '*' } @allowed;
    return scalar grep { $_ eq $id } @allowed;
}

# Returns 1 if current user has read-only access to the given instance.
# Viewers with access are read-only; operators and admins are never read-only.
sub user_is_readonly {
    my ($id) = @_;
    return 0 unless effective_role() eq 'viewer';
    return user_can_manage($id) ? 1 : 0;
}

# Returns all instances the current user may see (filtered by role/servers).
sub list_managed_instances {
    my @all = list_instances();
    return @all if is_admin();
    return grep { user_can_manage($_->{'id'} // $_->{'user'} // '') } @all;
}

# Grants $webmin_user access to $instance_id by appending to their servers list.
# No-op if already has access. Called by wizard/scan after install.
sub grant_server_access {
    my ($webmin_user, $instance_id) = @_;
    my %acl = get_module_acl($webmin_user, $module_name);
    my @servers = grep { /\S/ } split /\s+/, ($acl{'servers'} // '');
    return if grep { $_ eq $instance_id || $_ eq '*' } @servers;
    push @servers, $instance_id;
    $acl{'servers'} = join(' ', @servers);
    save_module_acl(\%acl, $webmin_user, $module_name);
}

# Returns sorted list of Webmin usernames explicitly assigned to $instance_id.
# Admins (via Webmin or servers=*) are excluded — they have implicit access.
sub get_server_owners {
    my ($instance_id) = @_;
    my @owners;
    for my $uname (list_webmin_users()) {
        next unless $uname =~ /\S/;
        eval {
            my %acl = get_module_acl($uname, $module_name);
            my @s = grep { /\S/ } split /\s+/, ($acl{'servers'} // '');
            push @owners, $uname if grep { $_ eq $instance_id } @s;
        };
    }
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
