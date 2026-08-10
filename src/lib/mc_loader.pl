# LinuxGSM-WebCore - Minecraft mod loader resolution (Fabric / Forge / NeoForge)
use strict;
use warnings;

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

# NeoForge version prefix from MC semver (1.21.1 -> 21.1, 1.20.4 -> 20.4).
sub mc_neoforge_version_prefix {
    my ($mc_version) = @_;
    return undef unless defined $mc_version && $mc_version =~ /^(\d+)\.(\d+)(?:\.(\d+))?$/;
    my ($maj, $min, $patch) = ($1, $2, $3);
    return defined $patch ? "$min.$patch" : "$min.0";
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

# Pick newest stable NeoForge version for an MC version from maven-metadata version list.
sub mc_pick_neoforge_version {
    my ($mc_version, $versions_ref) = @_;
    my $prefix = mc_neoforge_version_prefix($mc_version);
    return undef unless $prefix && ref($versions_ref) eq 'ARRAY';
    my @candidates = grep { /^\Q$prefix\E\.\d+(?:\.\d+)?$/ && !/-beta$/ } @$versions_ref;
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
    my @candidates = grep { /^\Q$prefix\E\.\d+(?:\.\d+)?$/ && !/-beta$/ } @$versions_ref;
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

sub _mc_fetch_url {
    my ($url) = @_;
    return undef unless defined $url && $url =~ m|^https://|;
    (my $safe = $url) =~ s/'/'\\''/g;
    my $raw = `curl -fsSL --max-time 120 '$safe' 2>/dev/null`;
    return undef if $? != 0 || !defined $raw || $raw !~ /\S/;
    return $raw;
}

sub _mc_fetch_json {
    my ($url) = @_;
    my $raw = _mc_fetch_url($url);
    return undef unless defined $raw;
    eval {
        require JSON::PP;
        return JSON::PP::decode_json($raw);
    };
    return undef;
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
        return $pin =~ /^\Q$prefix\E\./ ? 1 : 0;
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
