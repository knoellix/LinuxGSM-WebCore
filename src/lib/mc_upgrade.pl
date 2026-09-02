# mc_upgrade.pl — Minecraft loader/MC version upgrade preflight and plans
use strict;
use warnings;

our @MC_UPGRADE_TEST_LOADER_VERSIONS;
our @MC_UPGRADE_TEST_MC_VERSIONS;
our $MC_UPGRADE_TEST_MC_VERSIONS_OVERRIDE;
our $MC_UPGRADE_TEST_LOADER_VERSIONS_OVERRIDE;
our ($module_config_directory, $config_directory);
our %text;

use constant MC_UPGRADE_VERSION_CACHE_TTL => 3600;
use constant MC_UPGRADE_COMPAT_CACHE_TTL  => 300;

# Cache root for version lists and compat reports. Lives in the module config
# directory on purpose: the CGI runs as root and must not create root-owned
# files inside $SERVER_DIR (see security-isolation.mdc).
sub _mc_upgrade_cache_root {
    my $base = $module_config_directory || '';
    $base = $config_directory || '' unless $base =~ m{^/};
    return undef unless $base =~ m{^/} && -d $base;
    my $dir = "$base/upgrade_cache";
    return $dir if -d $dir;
    mkdir($dir, 0700) or return undef;
    return -d $dir ? $dir : undef;
}

sub _mc_upgrade_cache_file {
    my ($name) = @_;
    $name //= '';
    $name =~ s/[^a-zA-Z0-9._-]+/_/g;
    return undef unless $name =~ /\S/;
    my $root = _mc_upgrade_cache_root();
    return undef unless $root;
    return "$root/$name.json";
}

sub _mc_upgrade_cache_read {
    my ($name, $ttl) = @_;
    my $path = _mc_upgrade_cache_file($name);
    return undef unless $path && -f $path;
    my $age = time() - (stat($path))[9];
    return undef if $age < 0 || $age >= ($ttl // 0);
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close($fh);
    return undef unless defined $raw && $raw =~ /\S/;
    require JSON::PP;
    my $data = eval { JSON::PP::decode_json($raw) };
    return ref($data) eq 'HASH' ? $data : undef;
}

sub _mc_upgrade_cache_write {
    my ($name, $data) = @_;
    return 0 unless ref($data) eq 'HASH';
    my $path = _mc_upgrade_cache_file($name);
    return 0 unless $path;
    require JSON::PP;
    my $json = eval { JSON::PP::encode_json($data) };
    return 0 unless defined $json;
    open(my $fh, '>', $path) or return 0;
    print $fh $json;
    close($fh) or return 0;
    chmod(0600, $path);
    return 1;
}

sub mc_upgrade_cache_forget {
    my (@names) = @_;
    my $removed = 0;
    for my $name (@names) {
        my $path = _mc_upgrade_cache_file($name);
        next unless $path && -f $path;
        $removed++ if unlink($path);
    }
    return $removed;
}

# Cached loader build list for an MC version.
#   refresh  => 1  discard cache and fetch
#   no_fetch => 1  cache-only (page render path, keeps the overview offline)
sub mc_upgrade_cached_loader_versions {
    my ($loader, $mc, $opts) = @_;
    $opts = {} unless ref($opts) eq 'HASH';
    return () unless mc_loader_is_modded($loader // '');
    $mc //= '';
    $mc =~ s/[^0-9.]//g;
    return () unless $mc =~ /^[0-9.]+$/;
    my $name = "loader_${loader}_${mc}";
    if (!$opts->{'refresh'}) {
        my $hit = _mc_upgrade_cache_read($name, MC_UPGRADE_VERSION_CACHE_TTL);
        if (ref($hit) eq 'HASH' && ref($hit->{'versions'}) eq 'ARRAY') {
            return @{ $hit->{'versions'} };
        }
        return () if $opts->{'no_fetch'};
    }
    my @list = _mc_upgrade_avail_loader_versions($loader, $mc);
    _mc_upgrade_cache_write($name, { versions => \@list, loader => $loader, mc_version => $mc })
        if @list;
    return @list;
}

sub mc_upgrade_cached_mc_versions {
    my ($opts) = @_;
    $opts = {} unless ref($opts) eq 'HASH';
    if (!$opts->{'refresh'}) {
        my $hit = _mc_upgrade_cache_read('mc_versions', MC_UPGRADE_VERSION_CACHE_TTL);
        if (ref($hit) eq 'HASH' && ref($hit->{'versions'}) eq 'ARRAY') {
            return @{ $hit->{'versions'} };
        }
        return () if $opts->{'no_fetch'};
    }
    my @list = _mc_upgrade_avail_mc_versions();
    _mc_upgrade_cache_write('mc_versions', { versions => \@list }) if @list;
    return @list;
}

sub mc_upgrade_version_cache_names {
    my ($loader, $mc) = @_;
    my @names = ('mc_versions');
    $mc //= '';
    $mc =~ s/[^0-9.]//g;
    push @names, "loader_${loader}_${mc}"
        if mc_loader_is_modded($loader // '') && $mc =~ /^[0-9.]+$/;
    return @names;
}

# Loader builds that actually belong to an MC line — the missing precondition
# for an MC upgrade (the wizard MC list alone says nothing about loader builds).
sub mc_upgrade_loader_builds_for_mc {
    my ($loader, $mc, $opts) = @_;
    $opts = {} unless ref($opts) eq 'HASH';
    return () unless mc_loader_is_modded($loader // '');
    $mc //= '';
    $mc =~ s/[^0-9.]//g;
    return () unless $mc =~ /^[0-9.]+$/;
    my @avail = ref($opts->{'loader_versions'}) eq 'ARRAY'
        ? @{ $opts->{'loader_versions'} }
        : mc_upgrade_cached_loader_versions($loader, $mc, $opts);
    return grep { mc_loader_version_matches_mc($loader, $mc, $_) } @avail;
}

sub mc_upgrade_set_loader_versions_for_test {
    @MC_UPGRADE_TEST_LOADER_VERSIONS = @_;
    $MC_UPGRADE_TEST_LOADER_VERSIONS_OVERRIDE = 1;
}

sub mc_upgrade_clear_loader_versions_for_test {
    @MC_UPGRADE_TEST_LOADER_VERSIONS = ();
    $MC_UPGRADE_TEST_LOADER_VERSIONS_OVERRIDE = 0;
}

sub mc_upgrade_set_mc_versions_for_test {
    @MC_UPGRADE_TEST_MC_VERSIONS = @_;
    $MC_UPGRADE_TEST_MC_VERSIONS_OVERRIDE = 1;
}

sub mc_upgrade_clear_mc_versions_for_test {
    @MC_UPGRADE_TEST_MC_VERSIONS = ();
    $MC_UPGRADE_TEST_MC_VERSIONS_OVERRIDE = 0;
}

sub _mc_upgrade_avail_mc_versions {
    if ($MC_UPGRADE_TEST_MC_VERSIONS_OVERRIDE) {
        return @MC_UPGRADE_TEST_MC_VERSIONS;
    }
    return mc_list_mc_versions();
}

sub _mc_upgrade_avail_loader_versions {
    my ($loader, $mc_version) = @_;
    if ($MC_UPGRADE_TEST_LOADER_VERSIONS_OVERRIDE) {
        return @MC_UPGRADE_TEST_LOADER_VERSIONS;
    }
    return mc_fetch_loader_versions($loader, $mc_version);
}

# Loader builds newer than the pinned profile version (same MC line).
sub mc_upgrade_loader_upgrade_candidates {
    my ($profile, $versions_ref) = @_;
    return () unless ref($profile) eq 'HASH';
    my $loader = $profile->{'loader'} // '';
    return () unless mc_loader_is_modded($loader);
    my @avail = ref($versions_ref) eq 'ARRAY' ? @$versions_ref
        : _mc_upgrade_avail_loader_versions($loader, $profile->{'mc_version'} // '');
    return @avail unless @avail;
    my $current = mc_sanitize_loader_version_pin($loader, $profile->{'loader_version'});
    return @avail unless defined $current;
    return grep { mc_loader_version_cmp($_, $current) > 0 } @avail;
}

# Returns undef when valid; otherwise an error token.
sub mc_upgrade_validate_loader_target {
    my ($profile, $target, $versions_ref) = @_;
    return 'invalid' unless ref($profile) eq 'HASH';
    my $loader = $profile->{'loader'} // '';
    my $mc = $profile->{'mc_version'} // '';
    return 'loader_not_modded' unless mc_loader_is_modded($loader);
    my $clean = mc_sanitize_loader_version_pin($loader, $target);
    return 'invalid_target' unless defined $clean;
    return 'invalid_target' unless mc_loader_version_matches_mc($loader, $mc, $clean);

    my @avail = ref($versions_ref) eq 'ARRAY' ? @$versions_ref
        : _mc_upgrade_avail_loader_versions($loader, $mc);
    if (@avail) {
        return 'invalid_target' unless grep { $_ eq $clean } @avail;
    } else {
        return 'invalid_target' if mc_validate_loader_version_pin($loader, $mc, $clean);
    }

    my $current = mc_sanitize_loader_version_pin($loader, $profile->{'loader_version'});
    if (defined $current && mc_loader_version_cmp($clean, $current) <= 0) {
        return 'not_newer';
    }
    return undef;
}

sub mc_upgrade_loader_plan {
    my ($profile, $target_loader_version, $versions_ref) = @_;
    my $err = mc_upgrade_validate_loader_target($profile, $target_loader_version, $versions_ref);
    return (0, undef, $err // 'invalid_target') if $err;
    my $clean = mc_sanitize_loader_version_pin($profile->{'loader'}, $target_loader_version);
    return (0, undef, 'invalid_target') unless defined $clean;
    return (1, {
        mode                  => 'loader',
        loader                => $profile->{'loader'} // '',
        mc_version            => $profile->{'mc_version'} // '',
        target_loader_version => $clean,
        needs_java            => 0,
        lgsm_script           => $profile->{'lgsm_script'} // '',
    }, undef);
}

# True when the current loader family supports an MC release (wizard list or structural).
sub mc_upgrade_mc_loader_supports {
    my ($loader, $mc_version) = @_;
    $loader =~ s/[^a-z]//g;
    $mc_version =~ s/[^0-9.]//g;
    return 0 unless $loader && $mc_version =~ /^[0-9.]+$/;
    return 0 unless mc_loader_is_modded($loader);
    return 0 unless mc_loader_config($loader);
    my @list = _mc_upgrade_avail_mc_versions();
    return 0 unless @list;
    return 1 if grep { $_ eq $mc_version } @list;
    return 0;
}

sub mc_upgrade_mc_needs_java {
    my ($profile, $target_mc) = @_;
    return 0 unless ref($profile) eq 'HASH';
    $target_mc =~ s/[^0-9.]//g;
    return 0 unless $target_mc =~ /^[0-9.]+$/;
    my %probe = (%$profile, mc_version => $target_mc);
    return 1 if mc_profile_java_needs_sync(\%probe);
    my $target_java = int(resolve_java_major($target_mc));
    my $current_java = int($profile->{'java_major'} // 0);
    return $target_java != $current_java ? 1 : 0;
}

sub mc_upgrade_mc_upgrade_candidates {
    my ($profile, $versions_ref) = @_;
    return () unless ref($profile) eq 'HASH';
    my $loader = $profile->{'loader'} // '';
    return () unless mc_loader_is_modded($loader);
    my $current = $profile->{'mc_version'} // '';
    $current =~ s/[^0-9.]//g;
    return () unless $current =~ /^[0-9.]+$/;
    my @avail = ref($versions_ref) eq 'ARRAY' ? @$versions_ref : _mc_upgrade_avail_mc_versions();
    return grep {
        my $v = $_;
        $v =~ s/[^0-9.]//g;
        $v ne $current
            && mc_upgrade_mc_loader_supports($loader, $v)
            && mc_loader_version_cmp($v, $current) > 0
    } @avail;
}

sub mc_upgrade_validate_mc_target {
    my ($profile, $target_mc, $versions_ref) = @_;
    return 'invalid' unless ref($profile) eq 'HASH';
    my $loader = $profile->{'loader'} // '';
    return 'loader_not_modded' unless mc_loader_is_modded($loader);
    my $clean = $target_mc // '';
    $clean =~ s/[^0-9.]//g;
    return 'invalid_target' unless $clean =~ /^[0-9.]+$/;
    return 'invalid_target' unless mc_upgrade_mc_loader_supports($loader, $clean);

    my $current = $profile->{'mc_version'} // '';
    $current =~ s/[^0-9.]//g;
    return 'same_version' if $current eq $clean;
    return 'not_newer' if $current =~ /^[0-9.]+$/ && mc_loader_version_cmp($clean, $current) <= 0;

    my @avail = ref($versions_ref) eq 'ARRAY' ? @$versions_ref : _mc_upgrade_avail_mc_versions();
    if (@avail) {
        return 'invalid_target' unless grep { $_ eq $clean } @avail;
    }
    return undef;
}

sub mc_upgrade_mc_plan {
    my ($profile, $target_mc_version, $versions_ref) = @_;
    my $err = mc_upgrade_validate_mc_target($profile, $target_mc_version, $versions_ref);
    return (0, undef, $err // 'invalid_target') if $err;
    my $clean = $target_mc_version // '';
    $clean =~ s/[^0-9.]//g;
    my $target_java = int(resolve_java_major($clean));
    return (1, {
        mode               => 'mc',
        loader             => $profile->{'loader'} // '',
        mc_version         => $profile->{'mc_version'} // '',
        target_mc_version  => $clean,
        target_java_major  => $target_java,
        needs_java         => mc_upgrade_mc_needs_java($profile, $clean) ? 1 : 0,
        lgsm_script        => $profile->{'lgsm_script'} // '',
    }, undef);
}

our %MC_UPGRADE_TEST_MOD_COMPAT;

sub mc_upgrade_set_mod_compat_for_test {
    my ($source, $project_id, $has_compat) = @_;
    my $key = lc("$source:$project_id");
    $MC_UPGRADE_TEST_MOD_COMPAT{$key} = $has_compat ? 1 : 0;
}

sub mc_upgrade_clear_mod_compat_for_test {
    %MC_UPGRADE_TEST_MOD_COMPAT = ();
}

sub _mc_upgrade_mod_compat_key {
    my ($source, $project_id) = @_;
    $source =~ s/[^a-z]//g;
    return lc("$source:$project_id");
}

# 1 = compatible version exists, 0 = none, -1 = could not check (unknown source / CF key).
sub _mc_upgrade_mod_has_compatible_version {
    my ($source, $project_id, $target_profile, $version_id) = @_;
    $source =~ s/[^a-z]//g;
    return -1 unless $source =~ /^(?:modrinth|curseforge)$/;
    my $key = _mc_upgrade_mod_compat_key($source, $project_id);
    if (exists $MC_UPGRADE_TEST_MOD_COMPAT{$key}) {
        return $MC_UPGRADE_TEST_MOD_COMPAT{$key} ? 1 : 0;
    }
    if ($source eq 'modrinth') {
        my $pid = $project_id // '';
        $pid =~ s/[^a-zA-Z0-9_-]//g;
        if ($version_id && $version_id =~ /^[a-zA-Z0-9_-]+$/) {
            my $resolved = modrinth_resolve_project_id_from_version($version_id);
            $pid = $resolved if defined $resolved && $resolved =~ /\S/;
        }
        return 0 unless $pid =~ /\S/;
        my $list = modrinth_list_compatible_versions($pid, $target_profile);
        return (ref($list) eq 'ARRAY' && @$list) ? 1 : 0;
    }
    return -1 unless _curseforge_api_headers();
    my $list = curseforge_list_compatible_files(
        $project_id, $target_profile, { skip_download_url => 1 });
    return (ref($list) eq 'ARRAY' && @$list) ? 1 : 0;
}

# Unique Modrinth/CurseForge projects from the installed-mod index (enabled + disabled).
sub mc_upgrade_collect_index_mods {
    my ($server_dir, $profile) = @_;
    return [] unless defined $server_dir && $server_dir ne '';
    return [] unless ref($profile) eq 'HASH';
    my $mods = list_installed_mods($server_dir, $profile);
    return [] unless ref($mods) eq 'ARRAY';
    my %seen;
    my @out;
    for my $mod (@$mods) {
        next unless ref($mod) eq 'HASH';
        my $source = $mod->{'source'} // '';
        $source =~ s/[^a-z]//g;
        next unless $source eq 'modrinth' || $source eq 'curseforge';
        next unless $mod->{'has_update_meta'};
        my $pid = $mod->{'project_id'} // '';
        $pid =~ s/[\t\n\r\0]//g;
        next unless $pid =~ /\S/;
        my $dedupe = _mc_upgrade_mod_compat_key($source, $pid);
        next if $seen{$dedupe}++;
        $seen{$dedupe} = 1;
        push @out, {
            source     => $source,
            project_id => $pid,
            version_id => $mod->{'version_id'} // '',
            title      => _mc_mods_display_name($mod),
            basename   => $mod->{'basename'} // '',
        };
    }
    return \@out;
}

# Read-only compat scan for an MC upgrade target (no mod auto-update).
# The cache key carries the loader family because mod availability is scoped to
# (loader family, MC version) on both Modrinth and CurseForge.
sub _mc_upgrade_compat_cache_name {
    my ($server_dir, $loader, $target_mc) = @_;
    return undef unless defined $server_dir && $server_dir ne '';
    $loader //= '';
    $loader =~ s/[^a-z]//g;
    return undef unless $loader =~ /\S/;
    $target_mc //= '';
    $target_mc =~ s/[^0-9.]//g;
    return undef unless $target_mc =~ /^[0-9.]+$/;
    my $key = $server_dir;
    $key =~ s{^/+}{};
    $key =~ s/[^a-zA-Z0-9]+/_/g;
    $key = substr($key, 0, 60);
    my $safe_mc = $target_mc;
    $safe_mc =~ s/\./_/g;
    return "compat_${key}_${loader}_${safe_mc}";
}

# Remove root-owned caches written into $SERVER_DIR by module versions <= 0.2.2.
sub _mc_upgrade_drop_legacy_compat_cache {
    my ($server_dir) = @_;
    return 0 unless defined $server_dir && $server_dir =~ m{^/} && -d "$server_dir/.webcore";
    my $removed = 0;
    for my $path (glob("$server_dir/.webcore/mc_compat_*.json")) {
        next unless -f $path;
        $removed++ if unlink($path);
    }
    return $removed;
}

sub mc_upgrade_mod_compat_report {
    my ($server_dir, $profile, $target_mc_version) = @_;
    my $empty = {
        target_mc_version    => '',
        loader               => '',
        total                => 0,
        compatible           => [],
        incompatible         => [],
        unknown              => [],
        unchecked_curseforge => [],
    };
    return $empty unless ref($profile) eq 'HASH';

    my $clean_mc = $target_mc_version // '';
    $clean_mc =~ s/[^0-9.]//g;
    return $empty unless $clean_mc =~ /^[0-9.]+$/;

    my $loader = $profile->{'loader'} // '';
    $loader =~ s/[^a-z]//g;

    _mc_upgrade_drop_legacy_compat_cache($server_dir);

    my $cache_name = _mc_upgrade_compat_cache_name($server_dir, $loader, $clean_mc);
    if ($cache_name) {
        my $cached = _mc_upgrade_cache_read($cache_name, MC_UPGRADE_COMPAT_CACHE_TTL);
        if (ref($cached) eq 'HASH'
            && ($cached->{'target_mc_version'} // '') eq $clean_mc
            && ($cached->{'loader'} // '') eq $loader
            && ref($cached->{'compatible'}) eq 'ARRAY') {
            return $cached;
        }
    }

    my %target_prof = %$profile;
    $target_prof{'mc_version'} = $clean_mc;

    my $projects = mc_upgrade_collect_index_mods($server_dir, $profile);
    my @compatible;
    my @incompatible;
    my @unknown;
    my @unchecked_cf;

    for my $mod (@$projects) {
        next unless ref($mod) eq 'HASH';
        my $has = _mc_upgrade_mod_has_compatible_version(
            $mod->{'source'}, $mod->{'project_id'}, \%target_prof,
            $mod->{'version_id'} // '');
        if ($has == 1) {
            push @compatible, $mod;
        } elsif ($has == 0) {
            push @incompatible, $mod;
        } elsif (($mod->{'source'} // '') eq 'curseforge') {
            push @unchecked_cf, $mod;
        } else {
            push @unknown, $mod;
        }
    }

    my $report = {
        target_mc_version    => $clean_mc,
        loader               => $loader,
        total                => scalar @$projects,
        compatible           => \@compatible,
        incompatible         => \@incompatible,
        unknown              => \@unknown,
        unchecked_curseforge => \@unchecked_cf,
    };

    _mc_upgrade_cache_write($cache_name, $report) if $cache_name;

    return $report;
}

# Ordered upgrade check. The chosen dimension is validated first, then the
# opposite dimension, and only when both hold do we spend API calls on mods.
#   $target = { mode => 'mc',     target_mc_version     => '26.2' }
#           | { mode => 'loader', target_loader_version => '26.1.2.99' }
#   $opts   = { skip_mods => 1, loader_versions => [...], mc_versions => [...],
#               refresh => 1, no_fetch => 1 }
sub mc_upgrade_check_chain {
    my ($server_dir, $profile, $target, $opts) = @_;
    $target = {} unless ref($target) eq 'HASH';
    $opts   = {} unless ref($opts) eq 'HASH';
    my $mode = ($target->{'mode'} // '') eq 'loader' ? 'loader' : 'mc';

    my %chain = (
        mode       => $mode,
        order      => [ 'mc', 'loader', 'mods' ],
        ok         => 0,
        blocked_at => undef,
        steps      => {
            mc     => { status => 'skipped' },
            loader => { status => 'skipped' },
            mods   => { status => 'skipped' },
        },
    );

    unless (ref($profile) eq 'HASH' && mc_loader_is_modded($profile->{'loader'} // '')) {
        $chain{'blocked_at'} = $mode;
        $chain{'steps'}{$mode} = { status => 'fail', err => 'loader_not_modded' };
        return \%chain;
    }

    my $loader = $profile->{'loader'} // '';
    my $cur_mc = $profile->{'mc_version'} // '';
    $cur_mc =~ s/[^0-9.]//g;
    my $cur_pin = $profile->{'loader_version'} // '';

    if ($mode eq 'mc') {
        my $target_mc = $target->{'target_mc_version'} // '';
        $target_mc =~ s/[^0-9.]//g;
        my $verr = mc_upgrade_validate_mc_target($profile, $target_mc, $opts->{'mc_versions'});
        if ($verr) {
            $chain{'steps'}{'mc'} = { status => 'fail', err => $verr, value => $target_mc };
            $chain{'blocked_at'} = 'mc';
            return \%chain;
        }
        $chain{'steps'}{'mc'} = { status => 'ok', value => $target_mc, from => $cur_mc };

        my @builds = mc_upgrade_loader_builds_for_mc($loader, $target_mc, $opts);
        if (!@builds) {
            $chain{'steps'}{'loader'} = {
                status => 'fail',
                err    => 'loader_no_build_for_mc',
                value  => $target_mc,
                from   => $cur_pin,
            };
            $chain{'blocked_at'} = 'loader';
            return \%chain;
        }
        $chain{'steps'}{'loader'} = {
            status     => 'ok',
            value      => $builds[0],
            from       => $cur_pin,
            candidates => \@builds,
            java_major => int(resolve_java_major($target_mc)),
            needs_java => mc_upgrade_mc_needs_java($profile, $target_mc) ? 1 : 0,
        };
        $chain{'target_mc_version'}     = $target_mc;
        $chain{'target_loader_version'} = $builds[0];
    } else {
        my $pin = $target->{'target_loader_version'} // '';
        my $clean = mc_sanitize_loader_version_pin($loader, $pin);
        if (!defined $clean) {
            $chain{'steps'}{'loader'} = { status => 'fail', err => 'invalid_target', value => $pin };
            $chain{'blocked_at'} = 'loader';
            return \%chain;
        }
        # The MC line gates everything: a build from another line can never apply.
        unless ($cur_mc =~ /^[0-9.]+$/
            && mc_loader_version_matches_mc($loader, $cur_mc, $clean)) {
            $chain{'steps'}{'mc'} = {
                status => 'fail',
                err    => 'mc_line_mismatch',
                value  => $cur_mc,
            };
            $chain{'blocked_at'} = 'mc';
            return \%chain;
        }
        # A loader build bump keeps the MC version — mods are checked on that line.
        $chain{'steps'}{'mc'} = { status => 'unchanged', value => $cur_mc };

        my $verr = mc_upgrade_validate_loader_target($profile, $pin, $opts->{'loader_versions'});
        if ($verr) {
            $chain{'steps'}{'loader'} = { status => 'fail', err => $verr, value => $pin };
            $chain{'blocked_at'} = 'loader';
            return \%chain;
        }
        $chain{'steps'}{'loader'} = { status => 'ok', value => $clean, from => $cur_pin };
        $chain{'target_mc_version'}     = $cur_mc;
        $chain{'target_loader_version'} = $clean;
    }

    if ($opts->{'skip_mods'}) {
        $chain{'ok'} = 1;
        return \%chain;
    }

    my $report = mc_upgrade_mod_compat_report($server_dir, $profile, $chain{'target_mc_version'});
    my $bad = ref($report) eq 'HASH' ? ($report->{'incompatible'} // []) : [];
    my $cf  = ref($report) eq 'HASH' ? ($report->{'unchecked_curseforge'} // []) : [];
    $chain{'steps'}{'mods'} = {
        status => ((@$bad || @$cf) ? 'warn' : 'ok'),
        report => $report,
        issues => scalar(@$bad),
        total  => ref($report) eq 'HASH' ? ($report->{'total'} // 0) : 0,
    };
    $chain{'ok'} = @$bad ? 0 : 1;
    return \%chain;
}

sub mc_upgrade_chain_error_text {
    my ($step, $err, $mode) = @_;
    $err  //= '';
    $step //= '';
    $mode //= '';
    return '' unless $err =~ /\S/;
    my @keys;
    push @keys, 'mc_upgrade_check_blocked_loader_no_build' if $err eq 'loader_no_build_for_mc';
    push @keys, 'mc_upgrade_check_blocked_mc_mismatch'     if $err eq 'mc_line_mismatch';
    push @keys, "mc_upgrade_${step}_$err";
    push @keys, "mc_upgrade_mc_$err" if $mode eq 'mc';
    push @keys, "mc_upgrade_$err";
    for my $key (@keys) {
        return $text{$key} if defined $text{$key} && $text{$key} =~ /\S/;
    }
    return $err;
}

sub _mc_upgrade_chain_step_detail {
    my ($step, $state, $chain) = @_;
    $state = {} unless ref($state) eq 'HASH';
    my $status = $state->{'status'} // 'skipped';
    if ($status eq 'fail') {
        return &html_escape(mc_upgrade_chain_error_text($step, $state->{'err'}, $chain->{'mode'}));
    }
    if ($step eq 'mods') {
        return &html_escape($text{'mc_upgrade_check_mods_skipped'}
            || 'Not checked — earlier step failed.') if $status eq 'skipped';
        return &html_escape(&text('mc_upgrade_check_mods_detail',
            ($state->{'issues'} // 0), ($state->{'total'} // 0)));
    }
    my $from = $state->{'from'} // '';
    my $to   = $state->{'value'} // '';
    my $detail = '';
    if ($status eq 'unchanged') {
        $detail = &html_escape(&text('mc_upgrade_check_detail_unchanged', $to));
    } elsif ($from =~ /\S/ && $from ne $to) {
        $detail = &html_escape("$from \x{2192} $to");
    } else {
        $detail = &html_escape($to);
    }
    if ($step eq 'loader' && $state->{'needs_java'} && ($state->{'java_major'} // 0) > 0) {
        $detail .= "<br><small>"
            . &html_escape(&text('mc_upgrade_mc_java_change', $state->{'java_major'}))
            . "</small>";
    }
    return $detail;
}

# HTML for mc_upgrade_check_chain (Webmin CGI context).
sub mc_upgrade_render_check_chain_html {
    my ($chain) = @_;
    return '' unless ref($chain) eq 'HASH';
    my $steps = ref($chain->{'steps'}) eq 'HASH' ? $chain->{'steps'} : {};
    my @order = ref($chain->{'order'}) eq 'ARRAY' ? @{ $chain->{'order'} } : qw(mc loader mods);

    my @rows;
    for my $step (@order) {
        my $state = $steps->{$step} // {};
        my $status = $state->{'status'} // 'skipped';
        push @rows, [
            &html_escape($text{"mc_upgrade_check_step_$step"} || $step),
            &html_escape($text{"mc_upgrade_check_status_$status"} || $status),
            _mc_upgrade_chain_step_detail($step, $state, $chain),
        ];
    }

    my $out = &ui_columns_table(
        [
            $text{'mc_upgrade_check_col_step'}   || 'Step',
            $text{'mc_upgrade_check_col_status'} || 'Result',
            $text{'mc_upgrade_check_col_detail'} || 'Detail',
        ],
        '100%',
        \@rows,
    );

    my $blocked = $chain->{'blocked_at'} // '';
    if ($blocked =~ /\S/) {
        my $state = $steps->{$blocked} // {};
        $out .= "<div class=\"alert alert-warning\">"
            . &html_escape(mc_upgrade_chain_error_text($blocked, $state->{'err'}, $chain->{'mode'}))
            . "</div>\n";
        return $out;
    }

    if (($chain->{'mode'} // '') eq 'loader') {
        $out .= "<p><small>" . &html_escape($text{'mc_upgrade_check_loader_build_note'}
            || 'Mod sources only know the loader family and the MC version, not the build number.')
            . "</small></p>\n";
    }

    my $mods = $steps->{'mods'} // {};
    if (ref($mods->{'report'}) eq 'HASH') {
        my $html = mc_upgrade_render_mod_compat_report_html($mods->{'report'});
        $out .= $html if defined $html && $html ne '';
    }
    return $out;
}

sub mc_upgrade_preflight {
    my ($inst, $profile, $server_dir, $target, $ctx) = @_;
    $ctx = {} unless ref($ctx) eq 'HASH';
    $target = {} unless ref($target) eq 'HASH';

    return { ok => 0, err => 'profile_missing' } unless ref($profile) eq 'HASH';
    return { ok => 0, err => 'loader_not_modded' }
        unless mc_loader_is_modded($profile->{'loader'} // '');

    my $runtime = $ctx->{'runtime_status'} // '';
    if ($runtime eq 'online' || $runtime eq 'running') {
        return { ok => 0, err => 'server_must_be_stopped' };
    }

    my $iid = $ctx->{'instance_id'} // '';
    if ($iid !~ /\S/ && ref($inst) eq 'HASH') {
        $iid = $inst->{'instance_id'} // $inst->{'user'} // '';
    }
    if ($iid =~ /\S/) {
        my $job = find_running_job_for_instance($iid);
        return { ok => 0, err => 'job_running' } if $job;
    }

    my $mode = $target->{'mode'} // 'loader';
    if ($mode eq 'loader') {
        my $pin = $target->{'target_loader_version'} // '';
        my $verr = mc_upgrade_validate_loader_target($profile, $pin, $ctx->{'loader_versions'});
        return { ok => 0, err => ($verr // 'invalid_target') } if $verr;
        return { ok => 1 };
    }
    if ($mode eq 'mc') {
        my $mc = $target->{'target_mc_version'} // '';
        my $verr = mc_upgrade_validate_mc_target($profile, $mc, $ctx->{'mc_versions'});
        return { ok => 0, err => ($verr // 'invalid_target') } if $verr;
        return { ok => 1 };
    }
    return { ok => 0, err => 'invalid_mode' };
}

# HTML summary/table for mc_upgrade_mod_compat_report (Webmin CGI context).
sub mc_upgrade_render_mod_compat_report_html {
    my ($report) = @_;
    our %text;
    return '' unless ref($report) eq 'HASH';
    my $target = $report->{'target_mc_version'} // '';
    return '' unless $target =~ /\S/;
    return '' unless ($report->{'total'} // 0) > 0;

    my $out = '';
    my $bad = $report->{'incompatible'} // [];
    my $cf_skip = $report->{'unchecked_curseforge'} // [];
    if (@$bad) {
        my $msg = &text('mc_upgrade_mod_compat_warning',
            scalar @$bad,
            $target,
        );
        $out .= "<details open><summary>" . &html_escape($msg) . "</summary>\n";
        my @rows;
        my $n = 0;
        for my $mod (@$bad) {
            last unless ref($mod) eq 'HASH';
            last if ++$n > 25;
            push @rows, [
                &html_escape($mod->{'title'} // $mod->{'basename'} // '?'),
                &html_escape($mod->{'project_id'} // ''),
                &html_escape($text{"mc_mods_source_$mod->{'source'}"} // ($mod->{'source'} // '')),
            ];
        }
        $out .= &ui_columns_table(
            [
                $text{'mc_upgrade_mod_compat_col_mod'} || 'Mod',
                $text{'mc_upgrade_mod_compat_col_project'} || 'Project',
                $text{'mc_mods_col_source'} || 'Source',
            ],
            '100%',
            \@rows,
        );
        if (@$bad > 25) {
            $out .= "<p><small>" . &html_escape(&text(
                'mc_upgrade_mod_compat_truncated',
                scalar(@$bad) - 25,
            )) . "</small></p>\n";
        }
        $out .= "</details>\n";
    } elsif (!@$cf_skip) {
        $out .= "<p><em>" . &html_escape(&text(
            'mc_upgrade_mod_compat_ok',
            $report->{'total'} // 0,
            $target,
        )) . "</em></p>\n";
    }
    if (@$cf_skip) {
        $out .= "<p><em>" . &html_escape(&text(
            'mc_upgrade_mod_compat_cf_skipped',
            scalar @$cf_skip,
        )) . "</em></p>\n";
    }
    return $out;
}

sub write_upgrade_job_plan {
    my ($job_dir, $plan, $unix_user) = @_;
    return 0 unless defined $job_dir && -d $job_dir;
    return 0 unless ref($plan) eq 'HASH';
    require JSON::PP;
    my $path = "$job_dir/upgrade_plan.json";
    my $json = JSON::PP::encode_json($plan);
    open(my $fh, '>', $path) or return 0;
    print $fh $json;
    close($fh);
    &chown_job_files_to_user($unix_user, $path)
        if defined $unix_user && $unix_user ne '';
    open(my $rfh, '<', $path) or return 0;
    local $/;
    my $read = <$rfh>;
    close($rfh);
    return 0 unless defined $read && $read eq $json;
    return 1;
}

1;
