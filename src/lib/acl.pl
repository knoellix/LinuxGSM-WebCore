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
sub can_create { return $access{'can_create'} ? 1 : 0 }

# Returns 1 if current Webmin user may run the scanner.
sub can_scan { return $access{'can_scan'} ? 1 : 0 }

# Returns list of Unix usernames the current user may manage.
# Returns the single-element list ('*') for unrestricted access.
sub allowed_servers {
    my $s = $access{'servers'} // '';
    $s =~ s/^\s+|\s+$//g;
    return ('*') if $s eq '*';
    return grep { /\S/ } split /\s+/, $s;
}

# Returns 1 if the current user may manage the given Unix game user.
sub user_can_manage {
    my ($game_user) = @_;
    my @allowed = allowed_servers();
    return 1 if grep { $_ eq '*' } @allowed;
    return scalar grep { $_ eq $game_user } @allowed;
}

# Returns all instances the current user may manage.
# Admins (servers=*) get the full unfiltered list.
sub list_managed_instances {
    my @all = &list_instances();
    return @all if grep { $_ eq '*' } (allowed_servers());
    return grep { user_can_manage($_->{'user'}) } @all;
}

# Grants $webmin_user access to $game_user by appending to their servers list.
# No-op if already has access (including wildcard). Called by wizard after install.
sub grant_server_access {
    my ($webmin_user, $game_user) = @_;
    my %acl = get_module_acl($webmin_user, $module_name);
    my @servers = grep { /\S/ } split /\s+/, ($acl{'servers'} // '');
    return if grep { $_ eq $game_user || $_ eq '*' } @servers;
    push @servers, $game_user;
    $acl{'servers'} = join(' ', @servers);
    save_module_acl(\%acl, $webmin_user, $module_name);
}

# Returns sorted list of Webmin usernames that have access to $game_user.
sub get_server_owners {
    my ($game_user) = @_;
    my @owners;
    eval {
        foreign_require('acl', 'acl-lib.pl');
        for my $u (acl::list_users()) {
            next unless ref($u) eq 'HASH';
            my %acl = get_module_acl($u->{'name'}, $module_name);
            my @s = grep { /\S/ } split /\s+/, ($acl{'servers'} // '');
            push @owners, $u->{'name'} if grep { $_ eq $game_user || $_ eq '*' } @s;
        }
    };
    return sort @owners;
}

# Returns a sorted list of all Webmin usernames.
sub list_webmin_users {
    my @names;
    eval {
        foreign_require('acl', 'acl-lib.pl');
        @names = map { $_->{'name'} } acl::list_users();
    };
    return sort @names;
}

1;
