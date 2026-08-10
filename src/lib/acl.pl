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

our (%access, $module_name, $remote_user, $config_directory,
     $module_root, $module_root_directory);

# Per-request caches — reset to undef between test cases
our $_effective_role_cache;
our $_module_acl_cache;

# Webmin's init_config() populates these globals in package main::, but
# this lib runs inside the module's own package. The `our` variables above
# bind to <module>::<name>, which can be empty/undef even though the data
# is sitting in main::. These accessors transparently bridge both namespaces
# — prefer the module-package value when set, fall back to main:: otherwise.
sub _ctx_remote_user { return defined $remote_user ? $remote_user : $main::remote_user }
sub _ctx_config_dir  { return defined $config_directory ? $config_directory : $main::config_directory }
# Webmin sets $module_root_directory (not $module_root) on every request.
# Some of our CGIs alias $module_root = $module_root_directory; index.cgi
# and several others do not. Honour every reasonable name so the defaultacl
# lookup at "$root/defaultacl" works regardless of which CGI loaded us.
sub _ctx_module_root {
    return $module_root           if defined $module_root;
    return $module_root_directory if defined $module_root_directory;
    return $main::module_root     if defined $main::module_root;
    return $main::module_root_directory;
}
sub _ctx_module_name { return defined $module_name ? $module_name : $main::module_name }
sub _ctx_access {
    return %access if %access;
    return %main::access if %main::access;
    return ();
}

# Returns the effective module ACL for the current request as a hashref
# with keys role, servers, can_manage_ftp.
#
# Webmin populates %main::access from /etc/webmin/<module>/<user>, but
# this lib runs inside the module's package. `our %access` in this file
# binds to <module>::access, which can be empty even when the on-disk
# ACL is fully populated. Without this fallback, allowed_servers() reads
# `undef` for $access{'servers'} and returns ('*'), making every operator
# a de-facto admin. So: prefer %access (test harness, well-bridged
# namespaces), but fall back to reading $config_directory/$remote_user
# (and defaultacl) directly when fields are missing.
sub _module_acl {
    return $_module_acl_cache if defined $_module_acl_cache;
    my %acl;

    my %ax = _ctx_access();
    if (%ax) {
        for my $key (qw(role servers can_manage_ftp)) {
            $acl{$key} = $ax{$key} if defined $ax{$key};
        }
    }

    my $needs_more = !defined $acl{'role'}
        || !defined $acl{'servers'}
        || !defined $acl{'can_manage_ftp'};
    my $ru = _ctx_remote_user();
    my $mn = _ctx_module_name();
    my $mr = _ctx_module_root();

    # Preferred path: Webmin's canonical get_module_acl API.
    #
    # We can't just read $config_directory/$user — Webmin stores per-user
    # module ACLs at /etc/webmin/<module>/<module>/<user>.acl on most
    # installs (double-nested because $config_directory is module-specific
    # AND save_module_acl appends another /<module> layer). Plus the .acl
    # suffix. get_module_acl() abstracts all of that away.
    if ($needs_more && defined $ru && defined $mn && defined &get_module_acl) {
        my %file;
        eval {
            my %got = get_module_acl($ru, $mn);
            for my $k (keys %got) { $file{$k} = $got{$k} }
        };
        for my $key (qw(role servers can_manage_ftp)) {
            $acl{$key} //= $file{$key};
        }
        $needs_more = !defined $acl{'role'}
            || !defined $acl{'servers'}
            || !defined $acl{'can_manage_ftp'};
    }

    # Last-resort: read defaultacl shipped inside the module dir.
    # get_module_acl already merges defaultacl on most Webmin versions,
    # so this branch is only reached when get_module_acl is unavailable
    # (test harness) or the module has no per-user file at all.
    if ($needs_more && defined $mr && -r "$mr/defaultacl") {
        my %dflt;
        eval { &read_file("$mr/defaultacl", \%dflt) };
        for my $key (qw(role servers can_manage_ftp)) {
            $acl{$key} //= $dflt{$key};
        }
    }

    $_module_acl_cache = \%acl;
    &log_debug("ACL resolved: user=" . ($ru // '?')
        . " role=" . ($acl{'role'} // 'undef')
        . " servers=" . ($acl{'servers'} // 'undef')) if defined &log_debug;
    return $_module_acl_cache;
}

# Returns effective role string: 'admin', 'operator', or 'viewer'.
sub effective_role {
    return $_effective_role_cache if defined $_effective_role_cache;
    $_effective_role_cache = _compute_role();
    return $_effective_role_cache;
}

sub _compute_role {
    # 1. Webmin master admins always get full access regardless of module ACL.
    #
    # Important Perl gotcha: `return` inside `eval BLOCK` returns from the
    # eval, NOT from the enclosing subroutine. The pre-fix code did
    # `eval { return 'admin' if acl::master_admin(...) }` and silently
    # discarded the result, breaking master-admin recovery for years.
    # That bug stayed invisible while the safe default below was 'admin'
    # — every user fell through and got admin anyway. Once we tightened
    # the default to 'operator', the dormant bug surfaced as "admin sees
    # nothing". Capture the master-admin verdict explicitly via a flag.
    my $ru = _ctx_remote_user();
    if (defined $ru) {
        my $is_master = 0;
        eval {
            foreign_require('acl', 'acl-lib.pl');
            $is_master = 1 if acl::master_admin($ru);
        };
        return 'admin' if $is_master;
    }

    my $acl = _module_acl();

    # 2. Role from resolved ACL (in-memory or on-disk)
    return $acl->{'role'} if defined $acl->{'role'};

    # 3. Legacy: servers=* without role field → admin
    return 'admin' if defined $acl->{'servers'} && $acl->{'servers'} =~ /^\s*\*\s*$/;

    # 4. Legacy: restricted servers without role field → operator
    return 'operator' if defined $acl->{'servers'} && $acl->{'servers'} =~ /\S/;

    # 5. Safe default: never silently elevate. If no ACL data is reachable,
    # treat the user as an operator (no admin powers, no blanket server
    # access). master_admin handling above is the right escape hatch for
    # fresh installs where Webmin admins should still be able to bootstrap.
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
    my $acl = _module_acl();
    return $acl->{'can_manage_ftp'} ? 1 : 0;
}

# Returns list of Instance-IDs the current user may access.
# Returns ('*') for admins (unrestricted).
#
# IMPORTANT: returning ('*') when $access{'servers'} is undef would silently
# escalate every operator/viewer to admin in the Webmin namespace-mismatch
# case (see _module_acl). We resolve through _module_acl which honours the
# on-disk ACL file even if %access never made it into our package.
sub allowed_servers {
    return ('*') if is_admin();
    my $acl = _module_acl();
    my $s = $acl->{'servers'};
    return () unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return ('*') if $s eq '*';
    return () if $s eq '';
    return grep { /\S/ } split /\s+/, $s;
}

# Returns 1 if current user may access the given instance ID.
sub user_can_manage {
    my ($id) = @_;
    return 1 if is_admin();
    my @allowed = allowed_servers();
    my $ok = (grep { $_ eq '*' } @allowed) || (scalar grep { $_ eq $id } @allowed);
    &log_debug("ACL: user=" . (_ctx_remote_user() // '?') . " role=" . effective_role() . " instance=$id → " . ($ok ? "allowed" : "denied")) if defined &log_debug;
    return $ok ? 1 : 0;
}

# Returns 1 if current user has read-only access to the given instance.
# Viewers with access are read-only; operators and admins are never read-only.
sub user_is_readonly {
    my ($id) = @_;
    return 0 unless effective_role() eq 'viewer';
    return user_can_manage($id) ? 1 : 0;
}

# Returns 1 if current user may change instance state (start/stop/config/jobs/etc.).
# Operators and admins on assigned servers; viewers never.
sub user_can_operate {
    my ($id) = @_;
    return 0 if user_is_readonly($id);
    return user_can_manage($id) ? 1 : 0;
}

# Returns all instances the current user may see (filtered by role/servers).
sub list_managed_instances {
    my @all = list_instances();
    return @all if is_admin();
    return grep { user_can_manage($_->{'id'} // $_->{'user'} // '') } @all;
}

# Grants $webmin_user access to $instance_id by appending to their servers list.
# Returns 1 on success (including no-op when access already exists).
sub grant_server_access {
    my ($webmin_user, $instance_id) = @_;
    return 1 unless defined $webmin_user && $webmin_user =~ /\S/;
    return 1 unless defined $instance_id && $instance_id =~ /\S/;
    my $mn = _ctx_module_name();
    return 0 unless defined $mn && $mn ne '';

    my %acl = get_module_acl($webmin_user, $mn);
    my @servers = grep { /\S/ } split /\s+/, ($acl{'servers'} // '');
    return 1 if grep { $_ eq $instance_id || $_ eq '*' } @servers;

    push @servers, $instance_id;
    $acl{'servers'} = join(' ', @servers);
    $acl{'role'} //= 'operator';
    eval { &save_module_acl(\%acl, $webmin_user, $mn); 1 } or return 0;

    my %check = get_module_acl($webmin_user, $mn);
    my @check_servers = grep { /\S/ } split /\s+/, ($check{'servers'} // '');
    return (grep { $_ eq $instance_id || $_ eq '*' } @check_servers) ? 1 : 0;
}

# Returns sorted list of Webmin usernames explicitly assigned to $instance_id.
# Admins (via Webmin or servers=*) are excluded — they have implicit access.
sub get_server_owners {
    my ($instance_id) = @_;
    my $mn = _ctx_module_name();
    my @owners;
    for my $uname (list_webmin_users()) {
        next unless $uname =~ /\S/;
        eval {
            my %acl = get_module_acl($uname, $mn);
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

# Returns the subset of @all_ftp_names visible to the current user.
# Admins: all. Operators/viewers: only names linked via sftp_user to their instances.
sub allowed_ftp_users {
    my (@all_ftp_names) = @_;
    return @all_ftp_names if is_admin();
    my @srv = allowed_servers();
    return @all_ftp_names if grep { $_ eq '*' } @srv;
    my %allowed;
    for my $iid (@srv) {
        my $inst = eval { get_instance($iid) };
        next unless $inst;
        my $su = $inst->{'sftp_user'} // '';
        $allowed{$su} = 1 if $su ne '';
    }
    return grep { $allowed{$_} } @all_ftp_names;
}

1;
