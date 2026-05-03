#!/usr/bin/env bash
# diag-acl.sh — Diagnose der LinuxGSM-WebCore ACL-Auflösung.
# Aufruf:  bash diag-acl.sh <webmin-username> [--clear-log]
set -u

USER_TO_CHECK="${1:-}"
CLEAR_LOG=0
for arg in "$@"; do
    [ "$arg" = "--clear-log" ] && CLEAR_LOG=1
done

if [ -z "$USER_TO_CHECK" ] || [ "$USER_TO_CHECK" = "--clear-log" ]; then
    echo "Usage: $0 <webmin-username> [--clear-log]" >&2
    exit 2
fi

MOD_DIR="/usr/share/webmin/linuxgsm-webcore"
ETC_DIR="/etc/webmin/linuxgsm-webcore"
LOG="/var/webmin/miniserv.error"

if [ "$CLEAR_LOG" = "1" ] && [ -w "$LOG" ]; then
    : > "$LOG"
    echo "[diag] $LOG geleert."
fi

echo "=== 1. Deploy-Status: enthält acl.pl die neuen Helpers? ==="
grep -nE '_ctx_remote_user|module_root_directory|is_master = 1|ACL resolved' \
    "$MOD_DIR/lib/acl.pl" | head -8 \
    || echo "  acl.pl nicht gefunden"

echo
echo "=== 2. ALLE ACL-Dateien für '$USER_TO_CHECK' (mit Inhalt) ==="
find /etc/webmin -maxdepth 3 \
        \( -name "$USER_TO_CHECK.acl" -o -name "$USER_TO_CHECK.gacl" \
        -o -name "$USER_TO_CHECK" \) \
    2>/dev/null | sort -u | while read -r p; do
    echo "  --- $p ---"
    cat -A "$p"
    echo
done

echo
echo "=== 3. defaultacl ==="
[ -f "$MOD_DIR/defaultacl" ] && cat -A "$MOD_DIR/defaultacl" || echo "  FEHLT"

echo
echo "=== 4. Registry ==="
[ -f "$ETC_DIR/instances" ] && cat -A "$ETC_DIR/instances" || echo "  KEINE Registry."

echo
echo "=== 5. Frische Log-Zeilen ($LOG, letzte 60, ACL-relevant priorisiert) ==="
if [ -f "$LOG" ]; then
    grep -E '\[LGSM-(DEBUG|ERROR)\]|linuxgsm' "$LOG" | tail -60
    echo
    echo "  -- LETZTE 15 Zeilen GENERELL --"
    tail -15 "$LOG"
else
    echo "  $LOG nicht gefunden."
fi

echo
echo "=== 6. Live-Test ==="

# Webmin's web-lib needs WEBMIN_CONFIG and a $0 that resolves under /usr/share/webmin.
export WEBMIN_CONFIG=/etc/webmin
export WEBMIN_VAR=/var/webmin

# Write the test driver to a real file — Webmin's web-lib-funcs.pl bails when
# $0 is "-" because it does a full-path sanity check ("Script was not run
# with full path"). Run it from inside the module directory so $0 resolves.
DRIVER="$MOD_DIR/.diag_acl_driver.pl"
cat > "$DRIVER" <<'PERL'
#!/usr/bin/perl
use strict;
use warnings;

my $check_user = $ARGV[0] // 'unknown';

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();
require './lib/core.pl';
require './lib/acl.pl';
require './lib/instance.pl';
require './lib/logging.pl';

our (%access, $remote_user, $config_directory, $module_name,
     $module_root, $module_root_directory);
$remote_user = $check_user;

# Reset our package caches so the lookup runs fresh.
our ($_effective_role_cache, $_module_acl_cache);
$_effective_role_cache = undef;
$_module_acl_cache     = undef;

print "--- context ---\n";
print "remote_user            = $remote_user\n";
print "module_name            = ", ($module_name//'<undef>'), "\n";
print "config_directory       = ", ($config_directory//'<undef>'), "\n";
print "main::config_directory = ", ($main::config_directory//'<undef>'), "\n";
print "module_root            = ", ($module_root//'<undef>'), "\n";
print "module_root_directory  = ", ($module_root_directory//'<undef>'), "\n";
print "main::module_root      = ", ($main::module_root//'<undef>'), "\n";
print "main::module_root_directory = ", ($main::module_root_directory//'<undef>'), "\n";
print "%access                = ", (join(",", sort keys %access) || '<empty>'), "\n";
print "%main::access keys     = ", (join(",", sort keys %main::access) || '<empty>'), "\n";
for (sort keys %main::access) {
    my $v = $main::access{$_};
    $v //= '<undef>';
    $v =~ s/[\x00-\x1F]/?/g;   # show binary garbage
    print "    $_ = $v\n";
}

print "\n--- raw get_module_acl (Webmin's API) ---\n";
my $mn = $module_name // $main::module_name // 'linuxgsm-webcore';
if (defined &get_module_acl) {
    my %got = get_module_acl($remote_user, $mn);
    if (%got) {
        for my $k (sort keys %got) {
            my $v = $got{$k} // '<undef>';
            $v =~ s/[\x00-\x1F]/?/g;
            print "    $k = $v\n";
        }
    } else {
        print "    <empty> — get_module_acl returned no fields\n";
    }
} else {
    print "    get_module_acl not available\n";
}

print "\n--- resolved ---\n";
print "effective_role  = ", &effective_role(), "\n";
print "is_admin        = ", (&is_admin() ? 1 : 0), "\n";
print "allowed_servers = (", join(",", &allowed_servers()), ")\n";

print "\n--- per-instance filter ---\n";
for my $i (&list_instances()) {
    my $id = $i->{id} // $i->{user};
    printf "  %-50s manage=%d readonly=%d\n", $id,
        (&user_can_manage($id)?1:0), (&user_is_readonly($id)?1:0);
}
PERL

cd "$MOD_DIR" || exit 3
perl "$DRIVER" "$USER_TO_CHECK"
rm -f "$DRIVER"
