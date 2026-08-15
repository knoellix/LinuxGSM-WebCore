# LinuxGSM-WebCore - Minecraft mod loader resolution (Fabric / Forge / NeoForge)
use strict;
use warnings;

our ($module_config_directory, $config_directory);

# Mojang launcher meta + per-version Java majors. Cache lives under the module
# config directory (never $SERVER_DIR). TTL ~24h; stale cache is still usable
# when the network fails.
my $_MC_VERSIONS_CACHE_TTL = 86400;
my $_MC_MOJANG_MANIFEST_URL = 'https://launchermeta.mojang.com/mc/game/version_manifest_v2.json';
# Short timeout for Mojang manifest / version JSON (wizard must not block ~120s).
my $_MC_MOJANG_FETCH_TIMEOUT = 10;

sub mc_loader_is_modded {
    my ($loader) = @_;
    return 0 unless defined $loader && $loader =~ /^[a-z]+$/;
    return $loader =~ /^(?:fabric|forge|neoforge)$/ ? 1 : 0;
}

# Map a loader name from a modpack (CurseForge/Modrinth) to an internal loader id.
# Returns undef when the name is unknown. Quilt is recognised but not a
# modded-supported loader here (mc_loader_is_modded excludes it).
sub mc_loader_id_from_name {
    my ($name) = @_;
    return undef unless defined $name && $name =~ /\S/;
    (my $n = lc($name)) =~ s/[^a-z]//g;
    my %map = (
        forge    => 'forge',
        fabric   => 'fabric',
        neoforge => 'neoforge',
        quilt    => 'quilt',
    );
    return $map{$n};
}

# NeoForge version prefix from MC id.
# Legacy Mojang 1.x: 1.21.1 -> 21.1, 1.20 -> 20.0 (NeoForge drops the leading 1).
# Mojang 26.x (year.drop[.hotfix]): 26.1.2 -> 26.1.2, 26.1 -> 26.1.0
# (NeoForge builds are then prefix.build, e.g. 26.1.2.95).
sub mc_neoforge_version_prefix {
    my ($mc_version) = @_;
    return undef unless defined $mc_version;
    if ($mc_version =~ /^1\.(\d+)\.(\d+)$/) {
        return "$1.$2";
    }
    if ($mc_version =~ /^1\.(\d+)$/) {
        return "$1.0";
    }
    # Non-1.x MC ids (e.g. 26.1 / 26.1.2): NeoForge uses the full 3-component id.
    if ($mc_version =~ /^(\d+)\.(\d+)(?:\.(\d+))?$/ && $1 != 1) {
        my ($maj, $min, $patch) = ($1, $2, $3 // 0);
        return "$maj.$min.$patch";
    }
    return undef;
}

sub _mc_version_parts {
    my ($v) = @_;
    return [] unless defined $v;
    $v =~ s/-beta$//;
    my @p = split /\./, $v;
    return [ map { int($_) } @p ];
}

sub _mc_version_cmp {
    my ($a, $b) = @_;
    my $pa = _mc_version_parts($a);
    my $pb = _mc_version_parts($b);
    my $n = @$pa > @$pb ? @$pa : @$pb;
    for my $i (0 .. $n - 1) {
        my $va = $pa->[$i] // 0;
        my $vb = $pb->[$i] // 0;
        return $va <=> $vb if $va != $vb;
    }
    return 0;
}

# True when a NeoForge build version belongs to the MC prefix line.
# Accepts 3-part legacy (21.1.234) and 4-part 26.x (26.1.2.95) builds.
sub _mc_neoforge_version_matches_prefix {
    my ($prefix, $ver) = @_;
    return 0 unless defined $prefix && defined $ver;
    return 0 if $ver =~ /-beta$/;
    # After the MC prefix: one required build component, optional extra segment.
    return $ver =~ /^\Q$prefix\E\.\d+(?:\.\d+)?$/ ? 1 : 0;
}

# Pick newest stable NeoForge version for an MC version from maven-metadata version list.
sub mc_pick_neoforge_version {
    my ($mc_version, $versions_ref) = @_;
    my $prefix = mc_neoforge_version_prefix($mc_version);
    return undef unless $prefix && ref($versions_ref) eq 'ARRAY';
    my @candidates = grep { _mc_neoforge_version_matches_prefix($prefix, $_) } @$versions_ref;
    return undef unless @candidates;
    my @sorted = sort { _mc_version_cmp($a, $b) } @candidates;
    return $sorted[-1];
}

# Forge promotions_slim.json key candidates (recommended before latest).
sub mc_forge_promo_key_candidates {
    my ($mc_version) = @_;
    return () unless defined $mc_version && $mc_version =~ /^[0-9.]+$/;
    my @keys = ("$mc_version-recommended", "$mc_version-latest");
    if ($mc_version =~ /^(\d+\.\d+)\.\d+$/) {
        my $short = $1;
        push @keys, "$short-recommended", "$short-latest";
    }
    return @keys;
}

sub mc_forge_installer_url {
    my ($mc_version, $forge_version) = @_;
    return undef unless defined $mc_version && $mc_version =~ /^[0-9.]+$/;
    return undef unless defined $forge_version && $forge_version =~ /^[0-9.]+$/;
    return "https://maven.minecraftforge.net/net/minecraftforge/forge/${mc_version}-${forge_version}/forge-${mc_version}-${forge_version}-installer.jar";
}

sub mc_neoforge_installer_url {
    my ($neo_version) = @_;
    return undef unless defined $neo_version && $neo_version =~ /^[0-9.]+(?:\.\d+)?$/;
    return "https://maven.neoforged.net/releases/net/neoforged/neoforge/${neo_version}/neoforge-${neo_version}-installer.jar";
}

# Parse Fabric meta API loader list; prefer first stable entry.
sub mc_fabric_pick_loader_version {
    my ($loaders_ref, $pinned) = @_;
    if (defined $pinned && $pinned =~ /^[0-9.]+$/) {
        return $pinned if ref($loaders_ref) eq 'ARRAY'
            && grep {
                ref($_) eq 'HASH'
                    && ref($_->{'loader'}) eq 'HASH'
                    && ($_->{'loader'}{'version'} // '') eq $pinned
            } @$loaders_ref;
        return undef;
    }
    return undef unless ref($loaders_ref) eq 'ARRAY' && @$loaders_ref;
    for my $entry (@$loaders_ref) {
        next unless ref($entry) eq 'HASH';
        my $loader = $entry->{'loader'} // {};
        next unless ref($loader) eq 'HASH';
        my $ver = $loader->{'version'} // '';
        next unless $ver =~ /^[0-9.]+$/;
        return $ver if $loader->{'stable'};
    }
    my $first = $loaders_ref->[0]{'loader'}{'version'} // '';
    return ($first =~ /^[0-9.]+$/) ? $first : undef;
}

sub mc_fabric_pick_installer_url {
    my ($installers_ref) = @_;
    return undef unless ref($installers_ref) eq 'ARRAY' && @$installers_ref;
    for my $entry (@$installers_ref) {
        next unless ref($entry) eq 'HASH';
        my $url = $entry->{'url'} // '';
        return $url if $url =~ m|^https://maven\.fabricmc\.net/| && ($entry->{'stable'} // 0);
    }
    my $url = $installers_ref->[0]{'url'} // '';
    return ($url =~ m|^https://|) ? $url : undef;
}

sub mc_sanitize_loader_version_pin {
    my ($loader, $pin) = @_;
    return undef unless defined $loader && mc_loader_is_modded($loader);
    return undef unless defined $pin && $pin =~ /\S/;
    $pin =~ s/^\s+|\s+$//g;
    return undef if $pin eq '' || $pin eq 'auto';
    if ($loader eq 'neoforge') {
        return $pin if $pin =~ /^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?$/;
    }
    return $pin if $pin =~ /^[0-9.]+$/;
    return undef;
}

# Stable NeoForge builds compatible with an MC version (newest first).
sub mc_filter_neoforge_versions_for_mc {
    my ($mc_version, $versions_ref) = @_;
    my $prefix = mc_neoforge_version_prefix($mc_version);
    return [] unless $prefix && ref($versions_ref) eq 'ARRAY';
    my @candidates = grep { _mc_neoforge_version_matches_prefix($prefix, $_) } @$versions_ref;
    return [] unless @candidates;
    my @sorted = sort { _mc_version_cmp($a, $b) } @candidates;
    return [ reverse @sorted ];
}

# Forge build numbers for an MC version from maven-metadata (newest first).
sub mc_filter_forge_versions_for_mc {
    my ($mc_version, $versions_ref) = @_;
    return [] unless defined $mc_version && $mc_version =~ /^[0-9.]+$/;
    return [] unless ref($versions_ref) eq 'ARRAY';
    my $pfx = "$mc_version-";
    my @out;
    for my $v (@$versions_ref) {
        next unless defined $v && $v =~ /^\Q$pfx\E([0-9.]+)$/;
        push @out, $1;
    }
    return [] unless @out;
    my @uniq = do { my %s; grep { !$s{$_}++ } @out };
    my @sorted = sort { _mc_version_cmp($a, $b) } @uniq;
    return [ reverse @sorted ];
}

# Fabric loader versions for an MC version (newest first).
sub mc_filter_fabric_loader_versions {
    my ($loaders_ref) = @_;
    return [] unless ref($loaders_ref) eq 'ARRAY';
    my @vers;
    for my $entry (@$loaders_ref) {
        next unless ref($entry) eq 'HASH';
        my $loader = $entry->{'loader'} // {};
        next unless ref($loader) eq 'HASH';
        my $ver = $loader->{'version'} // '';
        push @vers, $ver if $ver =~ /^[0-9.]+$/;
    }
    return [] unless @vers;
    my @uniq = do { my %s; grep { !$s{$_}++ } @vers };
    my @sorted = sort { _mc_version_cmp($a, $b) } @uniq;
    return [ reverse @sorted ];
}

# Optional $timeout_secs (default 120) for curl --max-time. Mojang helpers pass ~10.
sub _mc_fetch_url {
    my ($url, $timeout_secs) = @_;
    return undef unless defined $url && $url =~ m|^https://|;
    my $max = 120;
    if (defined $timeout_secs && $timeout_secs =~ /^\d+$/ && int($timeout_secs) > 0) {
        $max = int($timeout_secs);
    }
    (my $safe = $url) =~ s/'/'\\''/g;
    my $raw = `curl -fsSL --max-time $max '$safe' 2>/dev/null`;
    return undef if $? != 0 || !defined $raw || $raw !~ /\S/;
    return $raw;
}

sub _mc_fetch_json {
    my ($url, $timeout_secs) = @_;
    my $raw = _mc_fetch_url($url, $timeout_secs);
    return undef unless defined $raw;
    my $data;
    eval {
        require JSON::PP;
        $data = JSON::PP::decode_json($raw);
    };
    return undef if $@ || !defined $data;
    return $data;
}

# Resolve writable cache dir: prefer $module_config_directory, else $config_directory.
# Skip /dev/null stubs used in unit tests without an explicit temp dir.
sub mc_versions_cache_dir {
    for my $cand (
        (defined $module_config_directory       ? $module_config_directory       : ()),
        (defined $main::module_config_directory ? $main::module_config_directory : ()),
        (defined $config_directory              ? $config_directory              : ()),
        (defined $main::config_directory        ? $main::config_directory        : ()),
    ) {
        next unless defined $cand && $cand ne '' && $cand ne '/dev/null';
        return $cand if -d $cand;
    }
    return '';
}

sub mc_versions_cache_path {
    my $dir = mc_versions_cache_dir();
    return '' unless $dir;
    return "$dir/mc_versions_cache.json";
}

sub mc_versions_cache_load {
    my $path = mc_versions_cache_path();
    return undef unless $path && -f $path;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close($fh);
    return undef unless defined $raw && $raw =~ /\S/;
    my $data;
    eval {
        require JSON::PP;
        $data = JSON::PP::decode_json($raw);
    };
    return undef if $@ || ref($data) ne 'HASH';
    return $data;
}

sub mc_versions_cache_save {
    my ($href) = @_;
    return 0 unless ref($href) eq 'HASH';
    my $path = mc_versions_cache_path();
    return 0 unless $path;
    my $json;
    eval {
        require JSON::PP;
        $json = JSON::PP->new->canonical->pretty->encode($href);
    };
    return 0 if $@ || !defined $json;
    my $tmp = "$path.tmp.$$";
    open(my $fh, '>', $tmp) or return 0;
    print {$fh} $json or do { close($fh); unlink($tmp); return 0; };
    close($fh) or do { unlink($tmp); return 0; };
    eval { chmod 0600, $tmp; };
    rename($tmp, $path) or do { unlink($tmp); return 0; };
    # Read-back verify (no blind success)
    my $rb = mc_versions_cache_load();
    return 0 unless ref($rb) eq 'HASH';
    return 1;
}

sub mc_versions_cache_is_fresh {
    my ($cache) = @_;
    return 0 unless ref($cache) eq 'HASH';
    my $at = $cache->{'fetched_at'};
    return 0 unless defined $at && $at =~ /^\d+$/;
    return (time() - int($at)) < $_MC_VERSIONS_CACHE_TTL ? 1 : 0;
}

# Parse Mojang version_manifest_v2.json → release IDs only (exclude snapshots).
# Manifest order is newest-first; keep that order.
sub mc_parse_mojang_release_ids {
    my ($manifest) = @_;
    return () unless ref($manifest) eq 'HASH';
    my $versions = $manifest->{'versions'};
    return () unless ref($versions) eq 'ARRAY';
    my @ids;
    for my $entry (@$versions) {
        next unless ref($entry) eq 'HASH';
        next unless ($entry->{'type'} // '') eq 'release';
        my $id = $entry->{'id'} // '';
        next unless $id =~ /^[0-9.]+$/;
        push @ids, $id;
    }
    return @ids;
}

sub mc_parse_mojang_version_urls {
    my ($manifest) = @_;
    return {} unless ref($manifest) eq 'HASH';
    my $versions = $manifest->{'versions'};
    return {} unless ref($versions) eq 'ARRAY';
    my %urls;
    for my $entry (@$versions) {
        next unless ref($entry) eq 'HASH';
        next unless ($entry->{'type'} // '') eq 'release';
        my $id  = $entry->{'id'}  // '';
        my $url = $entry->{'url'} // '';
        next unless $id =~ /^[0-9.]+$/;
        next unless $url =~ m|^https://|;
        $urls{$id} = $url;
    }
    return \%urls;
}

sub mc_parse_java_major_from_version_json {
    my ($ver) = @_;
    return undef unless ref($ver) eq 'HASH';
    my $jv = $ver->{'javaVersion'};
    return undef unless ref($jv) eq 'HASH';
    my $maj = $jv->{'majorVersion'};
    return undef unless defined $maj && $maj =~ /^\d+$/;
    return int($maj);
}

# Fetch release IDs from Mojang; on success refresh cache (releases + urls).
# Network miss → empty list (caller falls back to cache / static compat).
sub mc_fetch_mojang_release_ids {
    my $manifest = _mc_fetch_json($_MC_MOJANG_MANIFEST_URL, $_MC_MOJANG_FETCH_TIMEOUT);
    return () unless ref($manifest) eq 'HASH';
    my @ids = mc_parse_mojang_release_ids($manifest);
    return () unless @ids;
    my $urls = mc_parse_mojang_version_urls($manifest);
    my $cache = mc_versions_cache_load() || {};
    $cache = {} unless ref($cache) eq 'HASH';
    $cache->{'fetched_at'}   = time();
    $cache->{'releases'}     = \@ids;
    $cache->{'version_urls'} = $urls;
    $cache->{'java_majors'}  = ref($cache->{'java_majors'}) eq 'HASH'
        ? $cache->{'java_majors'} : {};
    mc_versions_cache_save($cache);
    return @ids;
}

# Resolve Java major for one MC id via cache URL map + Mojang version JSON.
# Updates cache java_majors on success. Network miss → undef (caller falls back).
sub mc_fetch_java_major_for_mc {
    my ($id) = @_;
    return undef unless defined $id;
    $id =~ s/[^0-9.]//g;
    return undef unless $id =~ /^[0-9.]+$/;

    my $cache = mc_versions_cache_load() || {};
    if (ref($cache) eq 'HASH'
        && ref($cache->{'java_majors'}) eq 'HASH'
        && defined $cache->{'java_majors'}{$id}
        && $cache->{'java_majors'}{$id} =~ /^\d+$/)
    {
        return int($cache->{'java_majors'}{$id});
    }

    my $url;
    if (ref($cache) eq 'HASH' && ref($cache->{'version_urls'}) eq 'HASH') {
        $url = $cache->{'version_urls'}{$id};
    }
    if (!defined $url || $url !~ m|^https://|) {
        # Ensure we have URL map from a fresh/stale manifest or live fetch
        my @ids = mc_fetch_mojang_release_ids();
        $cache = mc_versions_cache_load() || {};
        if (ref($cache) eq 'HASH' && ref($cache->{'version_urls'}) eq 'HASH') {
            $url = $cache->{'version_urls'}{$id};
        }
        # If fetch returned ids but still no url for this id, give up
        return undef unless defined $url && $url =~ m|^https://|;
    }

    my $ver = _mc_fetch_json($url, $_MC_MOJANG_FETCH_TIMEOUT);
    my $maj = mc_parse_java_major_from_version_json($ver);
    return undef unless defined $maj;

    $cache = mc_versions_cache_load() || {};
    $cache = {} unless ref($cache) eq 'HASH';
    $cache->{'java_majors'} = {} unless ref($cache->{'java_majors'}) eq 'HASH';
    $cache->{'java_majors'}{$id} = $maj;
    $cache->{'fetched_at'} //= time();
    mc_versions_cache_save($cache);
    return $maj;
}

# Effective release list: fresh cache → live fetch → stale cache → empty.
# Static mc_compat fallback is applied by mc_list_mc_versions() in mc_profile.pl.
sub mc_versions_effective_releases {
    my $cache = mc_versions_cache_load();
    if (ref($cache) eq 'HASH' && mc_versions_cache_is_fresh($cache)
        && ref($cache->{'releases'}) eq 'ARRAY' && @{ $cache->{'releases'} })
    {
        return @{ $cache->{'releases'} };
    }

    my @live = mc_fetch_mojang_release_ids();
    return @live if @live;

    if (ref($cache) eq 'HASH' && ref($cache->{'releases'}) eq 'ARRAY'
        && @{ $cache->{'releases'} })
    {
        return @{ $cache->{'releases'} };
    }
    return ();
}

# Java major from cache only (no network). Undef if unknown.
sub mc_versions_cached_java_major {
    my ($id) = @_;
    return undef unless defined $id;
    $id =~ s/[^0-9.]//g;
    return undef unless $id =~ /^[0-9.]+$/;
    my $cache = mc_versions_cache_load();
    return undef unless ref($cache) eq 'HASH';
    my $jm = $cache->{'java_majors'};
    return undef unless ref($jm) eq 'HASH';
    return undef unless defined $jm->{$id} && $jm->{$id} =~ /^\d+$/;
    return int($jm->{$id});
}

# Fetch selectable loader versions for wizard UI (network; may return empty list).
sub mc_fetch_loader_versions {
    my ($loader, $mc_version) = @_;
    return () unless mc_loader_is_modded($loader);
    $mc_version =~ s/[^0-9.]//g;
    return () unless $mc_version =~ /^[0-9.]+$/;

    if ($loader eq 'neoforge') {
        my $raw = _mc_fetch_url(
            'https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml');
        return () unless defined $raw && $raw =~ /<versions>/;
        my @versions = $raw =~ /<version>([^<]+)<\/version>/g;
        my $list = mc_filter_neoforge_versions_for_mc($mc_version, \@versions);
        return @$list;
    }

    if ($loader eq 'forge') {
        my $raw = _mc_fetch_url(
            'https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml');
        return () unless defined $raw && $raw =~ /<versions>/;
        my @versions = $raw =~ /<version>([^<]+)<\/version>/g;
        my $list = mc_filter_forge_versions_for_mc($mc_version, \@versions);
        return @$list if @$list;
        my $promos = _mc_fetch_json(
            'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json');
        my $map = ref($promos) eq 'HASH' ? ($promos->{'promos'} // {}) : {};
        my @out;
        for my $key (mc_forge_promo_key_candidates($mc_version)) {
            next unless ref($map) eq 'HASH' && exists $map->{$key};
            my $v = $map->{$key};
            push @out, $v if defined $v && $v =~ /^[0-9.]+$/;
        }
        my @uniq = do { my %s; grep { !$s{$_}++ } @out };
        return @uniq;
    }

    if ($loader eq 'fabric') {
        my $loaders = _mc_fetch_json(
            "https://meta.fabricmc.net/v2/versions/loader/$mc_version");
        my $list = mc_filter_fabric_loader_versions($loaders);
        return @$list;
    }

    return ();
}

# Validate pinned loader version against live version list (undef = ok).
sub mc_validate_loader_version_pin {
    my ($loader, $mc_version, $pin) = @_;
    my $clean = mc_sanitize_loader_version_pin($loader, $pin);
    return undef unless defined $clean;
    my @avail = mc_fetch_loader_versions($loader, $mc_version);
    return undef if grep { $_ eq $clean } @avail;
    return undef if mc_loader_version_matches_mc($loader, $mc_version, $clean);
    return 'invalid';
}

# Format/prefix check when live version list is unavailable (wizard manual entry).
sub mc_loader_version_matches_mc {
    my ($loader, $mc_version, $pin) = @_;
    $pin = mc_sanitize_loader_version_pin($loader, $pin);
    return 0 unless defined $pin;
    if ($loader eq 'neoforge') {
        my $prefix = mc_neoforge_version_prefix($mc_version);
        return 0 unless $prefix;
        # Pin must be on the prefix line (3- or 4-part NeoForge builds).
        return _mc_neoforge_version_matches_prefix($prefix, $pin) ? 1 : 0;
    }
    return $pin =~ /^[0-9.]+$/ ? 1 : 0;
}

# Resolve installer URL + version; optional $pinned selects a specific loader build.
sub mc_resolve_loader_install {
    my ($loader, $mc_version, $pinned) = @_;
    return undef unless mc_loader_is_modded($loader);
    $mc_version =~ s/[^0-9.]//g;
    return undef unless $mc_version =~ /^[0-9.]+$/;
    $pinned = mc_sanitize_loader_version_pin($loader, $pinned);

    if ($loader eq 'fabric') {
        my $loaders = _mc_fetch_json(
            "https://meta.fabricmc.net/v2/versions/loader/$mc_version");
        return undef unless ref($loaders) eq 'ARRAY';
        my $installers = _mc_fetch_json('https://meta.fabricmc.net/v2/versions/installer');
        my $fabric_loader = mc_fabric_pick_loader_version($loaders, $pinned)
            // (!$pinned ? mc_fabric_pick_loader_version($loaders) : undef);
        return undef unless $fabric_loader;
        my $installer_url = mc_fabric_pick_installer_url($installers);
        return undef unless $installer_url;
        return {
            installer_url         => $installer_url,
            loader_version        => $fabric_loader,
            fabric_loader_version => $fabric_loader,
        };
    }

    if ($loader eq 'forge') {
        my $forge_ver = $pinned;
        if (!$forge_ver) {
            my $promos = _mc_fetch_json(
                'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json');
            my $map = ref($promos) eq 'HASH' ? ($promos->{'promos'} // {}) : {};
            for my $key (mc_forge_promo_key_candidates($mc_version)) {
                next unless ref($map) eq 'HASH'
                    && exists $map->{$key}
                    && $map->{$key} =~ /^[0-9.]+$/;
                $forge_ver = $map->{$key};
                last;
            }
        } else {
            my @avail = mc_fetch_loader_versions('forge', $mc_version);
            return undef unless grep { $_ eq $forge_ver } @avail;
        }
        return undef unless $forge_ver;
        my $url = mc_forge_installer_url($mc_version, $forge_ver);
        return undef unless $url;
        return {
            installer_url  => $url,
            loader_version => $forge_ver,
        };
    }

    if ($loader eq 'neoforge') {
        my $raw = _mc_fetch_url(
            'https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml');
        return undef unless defined $raw && $raw =~ /<versions>/;
        my @versions = $raw =~ /<version>([^<]+)<\/version>/g;
        my $neo_ver = $pinned;
        if (!$neo_ver) {
            $neo_ver = mc_pick_neoforge_version($mc_version, \@versions);
        } else {
            my $list = mc_filter_neoforge_versions_for_mc($mc_version, \@versions);
            return undef unless grep { $_ eq $neo_ver } @$list;
        }
        return undef unless $neo_ver;
        my $url = mc_neoforge_installer_url($neo_ver);
        return undef unless $url;
        return {
            installer_url  => $url,
            loader_version => $neo_ver,
        };
    }

    return undef;
}

# Pending setup steps for manage UI (java / loader / install). Empty = ready.
sub mc_pending_setup_steps {
    my ($profile, $server_dir) = @_;
    return [] unless ref($profile) eq 'HASH' && defined $server_dir && $server_dir ne '';
    my @pending;
    my $java_home = $profile->{'java_home'} // '';
    my $java_bin  = $java_home ? "$server_dir/$java_home/bin/java" : '';
    push @pending, 'java' unless ($java_bin && -x $java_bin);

    my $loader = $profile->{'loader'} // '';
    if (mc_loader_is_modded($loader)) {
        my $lcfg = mc_loader_config($loader);
        my $exe  = ref($lcfg) eq 'HASH' ? ($lcfg->{'lgsm_executable'} // '') : '';
        $exe =~ s/^\.\///;
        push @pending, 'loader' unless ($exe && -e "$server_dir/serverfiles/$exe");
    }
    elsif (mc_loader_phase1_ready($loader)) {
        my $jar = ($loader eq 'paper') ? 'paperclip.jar' : 'minecraft_server.jar';
        push @pending, 'install' unless (-f "$server_dir/serverfiles/$jar");
    }
    return \@pending;
}

# Mod browser / modpack UI: java + loader ready; game jar install may still be pending.
sub mc_mod_ui_ready {
    my ($profile, $server_dir) = @_;
    return 0 unless ref($profile) eq 'HASH' && defined $server_dir && $server_dir ne '';
    my $loader = $profile->{'loader'} // '';
    return 0 unless $loader eq 'paper' || mc_loader_is_modded($loader);
    my @pending = @{ mc_pending_setup_steps($profile, $server_dir) };
    return 0 if grep { $_ eq 'java' || $_ eq 'loader' } @pending;
    return 1;
}

# Map pending setup steps + LGSM script presence to instance_status phase.
sub mc_infer_setup_status {
    my ($lgsm_script_ready, $pending_ref) = @_;
    my @pending = ref($pending_ref) eq 'ARRAY' ? @$pending_ref : ();
    return 'installed' unless @pending;
    my %need = map { $_ => 1 } @pending;
    if ($need{'java'}) {
        return $lgsm_script_ready ? 'lgsm_ready' : 'fresh';
    }
    if ($need{'loader'} || $need{'install'}) {
        return 'mc_ready';
    }
    return 'installed';
}

my %_mc_setup_status_rank = (
    fresh       => 0,
    lgsm_ready  => 1,
    mc_ready    => 2,
    installed   => 3,
);

sub mc_pick_setup_status {
    my (@candidates) = @_;
    my $best;
    for my $c (@candidates) {
        next unless defined $c && $c ne '';
        next unless exists $_mc_setup_status_rank{$c};
        if (!defined $best || $_mc_setup_status_rank{$c} > $_mc_setup_status_rank{$best}) {
            $best = $c;
        }
    }
    return $best;
}

1;
