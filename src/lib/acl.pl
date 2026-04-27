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

our (%access, $module_name, $remote_user, $config_directory);

# Per-request cache — reset to undef between test cases
our $_effective_role_cache;

# Returns effective role string: 'admin', 'operator', or 'viewer'.
sub effective_role {
    return $_effective_role_cache if defined $_effective_role_cache;
    $_effective_role_cache = _compute_role();
    return $_effective_role_cache;
}

sub _compute_role {
    # 1. Webmin master admins always get full access regardless of module ACL
    if (defined $remote_user) {
        eval {
            foreign_require('acl', 'acl-lib.pl');
            return 'admin' if acl::master_admin($remote_user);
        };
    }

    # 2. Role from %access (populated by init_config from module ACL)
    return $access{'role'} if defined $access{'role'};

    # 3. Direct file fallback when %access is empty (package namespace mismatch)
    if (defined $remote_user && defined $module_name && defined $config_directory) {
        my %facl;
        eval {
            my $ufile = "$config_directory/$module_name/$remote_user";
            my $dfile = "$config_directory/$module_name/defaultacl";
            &read_file($ufile, \%facl) if -r $ufile;
            &read_file($dfile, \%facl) if !%facl && -r $dfile;
        };
        return $facl{'role'} if defined $facl{'role'};
    }

    # 4. Legacy: servers=* without role field → admin
    return 'admin' if defined $access{'servers'} && $access{'servers'} =~ /^\s*\*\s*$/;

    # 5. Legacy: restricted servers without role field → operator
    return 'operator' if defined $access{'servers'} && $access{'servers'} =~ /\S/;

    # 6. Safe default
    return 'operator';
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
