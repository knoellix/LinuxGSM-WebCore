# LinuxGSM-WebCore - Minecraft instance profile (.mcprofile.json)
use strict;
use warnings;

our ($module_root, %text);

my $_compat_cache;
my $_compat_loaded = 0;

sub _load_mc_compat {
    return $_compat_cache if $_compat_loaded && $_compat_cache;
    $_compat_loaded = 1;
    my @candidates;
    if (defined $module_root && $module_root =~ /\S/) {
        push @candidates, "$module_root/lib/mc_compat.json";
    }
    (my $libdir = __FILE__) =~ s{/[^/]+$}{};
    push @candidates, "$libdir/mc_compat.json";
    my $file;
    for my $c (@candidates) {
        if (-f $c) { $file = $c; last; }
    }
    return $_compat_cache = {} unless defined $file;
    open(my $fh, '<', $file) or return $_compat_cache = {};
    local $/;
    my $raw = <$fh>;
    close($fh);
    eval {
        require JSON::PP;
        $_compat_cache = JSON::PP::decode_json($raw);
    };
    $_compat_cache = {} if $@ || ref($_compat_cache) ne 'HASH';
    return $_compat_cache;
}

sub _reset_mc_compat_cache {
    $_compat_loaded = 0;
    $_compat_cache  = undef;
}

sub load_mc_compat { return _load_mc_compat() }

# Wizard step 1 uses LGSM CSV shortnames (e.g. mc, pmc); registry uses script names (mcserver, pmcserver).
sub normalize_mc_game_key {
    my ($game) = @_;
    return '' unless defined $game && $game =~ /\S/;
    my $compat = _load_mc_compat();
    my $map = $compat->{'game_to_loader'} // {};
    return $game if exists $map->{$game};
    # Resolve shortname via cached LGSM serverlist when available.
    if (defined &resolve_lgsm_game_script) {
        my $script = &resolve_lgsm_game_script($game);
        return $script if $script && exists $map->{$script};
    }
    return $game;
}

sub _mc_java_mod_excluded {
    my ($game) = @_;
    my $compat = _load_mc_compat();
    my @ex = @{ $compat->{'java_mod_excluded'} // [] };
    my $key = normalize_mc_game_key($game);
    return 1 if grep { $_ eq $game || $_ eq $key } @ex;
    return 0;
}

# Return 1 if $game is a Minecraft Java LGSM game (wizard shortname or script).
sub is_minecraft_game {
    my ($game) = @_;
    return 0 unless defined $game && $game =~ /\S/;
    return 0 if _mc_java_mod_excluded($game);
    my $compat = _load_mc_compat();
    my $map = $compat->{'game_to_loader'} // {};
    my $key = normalize_mc_game_key($game);
    return exists $map->{$key} ? 1 : 0;
}

sub mc_loader_from_game {
    my ($game) = @_;
    my $compat = _load_mc_compat();
    my $map = $compat->{'game_to_loader'} // {};
    my $key = normalize_mc_game_key($game);
    return $map->{$key} if exists $map->{$key};
    return 'vanilla' if $key eq 'mcserver';
    return undef;
}

sub mc_loader_config {
    my ($loader) = @_;
    my $compat = _load_mc_compat();
    my $loaders = $compat->{'loaders'} // {};
    return $loaders->{$loader} if ref($loaders->{$loader}) eq 'HASH';
    return undef;
}

sub mc_list_loaders {
    my $compat = _load_mc_compat();
    my $loaders = $compat->{'loaders'} // {};
    return sort keys %$loaders;
}

sub mc_list_mc_versions {
    my $compat = _load_mc_compat();
    my @vers = @{ $compat->{'mc_versions'} // [] };
    return @vers;
}

sub mc_loader_phase1_ready {
    my ($loader) = @_;
    my $cfg = mc_loader_config($loader);
    return 0 unless $cfg;
    return ($cfg->{'phase'} // 1) == 1 ? 1 : 0;
}

sub resolve_java_major {
    my ($mc_version) = @_;
    my $compat = _load_mc_compat();
    my $vers = $compat->{'versions'} // {};
    my $entry = $vers->{$mc_version};
    return int($entry->{'java_major'}) if ref($entry) eq 'HASH' && defined $entry->{'java_major'};
    return 21;
}

sub mc_profile_path {
    my ($server_dir) = @_;
    return "$server_dir/.mcprofile.json";
}

sub mc_java_home_rel {
    my ($java_major) = @_;
    return ".java/temurin-$java_major";
}

# Build a default profile hash for loader + MC version.
sub build_mc_profile {
    my ($loader, $mc_version, $opts_ref) = @_;
    my %opts = %{ $opts_ref || {} };
    $loader     = lc($loader // '');
    $mc_version = $mc_version // '';
    $loader     =~ s/[^a-z]//g;
    $mc_version =~ s/[^0-9.]//g;

    my $lcfg = mc_loader_config($loader);
    return undef unless $lcfg;

    my @vers = mc_list_mc_versions();
    return undef unless grep { $_ eq $mc_version } @vers;

    my $java_major = resolve_java_major($mc_version);
    my $java_home  = mc_java_home_rel($java_major);

    my $profile = {
        loader      => $loader,
        mc_version  => $mc_version,
        java_major  => $java_major,
        java_home   => $java_home,
        lgsm_script => $lcfg->{'lgsm_script'},
        mod_dir     => $lcfg->{'mod_dir'},
        paper_build => $opts{'paper_build'} // 'latest',
    };
    if ($loader =~ /^(?:fabric|forge|neoforge)$/ && defined $opts{'loader_version'}) {
        my $lv = $opts{'loader_version'};
        $lv =~ s/[^0-9.]//g;
        $profile->{'loader_version'} = $lv if $lv =~ /^[0-9.]+$/;
    }
    return $profile;
}

sub validate_mc_profile {
    my ($profile) = @_;
    return 'missing profile' unless ref($profile) eq 'HASH';
    my $loader = $profile->{'loader'} // '';
    my $mc_version = $profile->{'mc_version'} // '';
    return 'missing loader' unless $loader =~ /^[a-z]+$/;
    return 'missing mc_version' unless $mc_version =~ /^[0-9.]+$/;
    my $built = build_mc_profile($loader, $mc_version);
    return 'invalid loader or version' unless $built;
    for my $k (qw(loader mc_version java_major java_home lgsm_script mod_dir)) {
        return "missing $k" unless defined $profile->{$k} && $profile->{$k} =~ /\S/;
    }
    return undef;
}

sub read_mc_profile {
    my ($server_dir) = @_;
    my $path = mc_profile_path($server_dir);
    return undef unless -f $path;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $raw = <$fh>;
    close($fh);
    my $data;
    eval {
        require JSON::PP;
        $data = JSON::PP::decode_json($raw);
    };
    return (ref($data) eq 'HASH') ? $data : undef;
}

sub encode_mc_profile {
    my ($profile) = @_;
    require JSON::PP;
    return JSON::PP->new->pretty->canonical->encode($profile);
}

# Write .mcprofile.json for the game Unix user.
# User-native worker (euid already == target user): write directly, no su.
# Root context (provisioning/adopt): dispatch via su to the game user.
sub write_mc_profile {
    my ($server_dir, $unix_user, $profile) = @_;
    my $verr = validate_mc_profile($profile);
    return 0 if $verr;
    my $content = encode_mc_profile($profile);
    my $path = mc_profile_path($server_dir);

    my $uid = (defined $unix_user && $unix_user ne '') ? (getpwnam($unix_user))[2] : undef;
    if (!defined $unix_user || $unix_user eq '' || (defined $uid && $> == $uid)) {
        open(my $fh, '>', $path) or return 0;
        print {$fh} $content or do { close($fh); return 0; };
        close($fh) or return 0;
        return 1;
    }

    (my $safe_path = $path) =~ s/'/'\\''/g;
    open(my $pipe, '|-', 'su', '-s', '/bin/bash', '-c', "cat > '$safe_path'", $unix_user)
        or return 0;
    print $pipe $content;
    close($pipe) or return 0;
    return 1;
}

sub lgsm_instance_cfg_path {
    my ($server_dir, $script_name) = @_;
    return "$server_dir/lgsm/config-lgsm/$script_name/$script_name.cfg";
}

sub _mc_cfg_escape {
    my ($v) = @_;
    $v //= '';
    $v =~ s/\\/\\\\/g;
    $v =~ s/"/\\"/g;
    return $v;
}

# Build preexecutable= value for a loader (java_jar | empty | java_home).
sub mc_lgsm_preexecutable_for_loader {
    my ($profile, $server_dir, $loader_cfg) = @_;
    return '' unless ref($profile) eq 'HASH' && ref($loader_cfg) eq 'HASH';
    my $mode = $loader_cfg->{'lgsm_preexecutable'} // 'java_jar';
    my $java_home = $profile->{'java_home'} // '';
    return '' if $mode eq 'empty';

    my $abs_java = "$server_dir/$java_home";
    (my $safe_java = $abs_java) =~ s/'/'\\''/g;

    if ($mode eq 'java_jar') {
        return qq{export JAVA_HOME='$safe_java'; export PATH="\$JAVA_HOME/bin:\$PATH"; java -Xmx\${javaram}M -jar};
    }
    return qq{export JAVA_HOME='$safe_java'; export PATH="\$JAVA_HOME/bin:\$PATH"};
}

# LGSM instance.cfg overrides derived from .mcprofile.json (Quick Fix + Java setup).
sub mc_lgsm_cfg_overrides {
    my ($profile, $server_dir) = @_;
    return {} unless ref($profile) eq 'HASH';
    my $loader = $profile->{'loader'} // '';
    my $lcfg   = mc_loader_config($loader);
    return {} unless $lcfg;

    my %o;
    my $mc_version = $profile->{'mc_version'} // '';
    if ($mc_version =~ /^[0-9.]+$/) {
        $o{'serverversion'} = $mc_version;
    }
    if (my $exe = $lcfg->{'lgsm_executable'}) {
        $o{'executable'} = $exe;
    }
    if (exists $lcfg->{'lgsm_preexecutable'}) {
        $o{'preexecutable'} = mc_lgsm_preexecutable_for_loader($profile, $server_dir, $lcfg);
    }
    return \%o;
}

# Merge profile overrides (serverversion, executable, preexecutable) into LGSM cfg content.
sub patch_lgsm_mc_cfg_content {
    my ($content, $profile, $server_dir) = @_;
    $content //= '';
    my $over = mc_lgsm_cfg_overrides($profile, $server_dir);
    return $content unless ref($over) eq 'HASH' && keys %$over;

    my %patch = %$over;
    my %seen;
    my @lines;
    for my $line (split /\n/, $content) {
        if ($line =~ /^(\w+)\s*=/) {
            my $k = $1;
            if ($k eq 'mcversion' && exists $patch{'serverversion'}) {
                push @lines, 'serverversion="' . _mc_cfg_escape($patch{'serverversion'}) . '"'
                    unless $seen{'serverversion'}++;
                next;
            }
            if (exists $patch{$k}) {
                push @lines, $k . '="' . _mc_cfg_escape($patch{$k}) . '"' unless $seen{$k}++;
                next;
            }
        }
        push @lines, $line;
    }
    for my $k (sort keys %patch) {
        next if $seen{$k};
        push @lines, $k . '="' . _mc_cfg_escape($patch{$k}) . '"';
    }

    my $out = join("\n", @lines);
    $out .= "\n" unless $out =~ /\n\z/;
    return $out;
}

sub mc_start_wrapper_content {
    my ($profile, $server_dir) = @_;
    my $java_home = $profile->{'java_home'} // '';
    my $java_major = $profile->{'java_major'} // '';
    return <<"EOF";
#!/bin/bash
# mc_start_wrapper.sh — generated by LinuxGSM-WebCore
set -euo pipefail
SERVER_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export JAVA_HOME="\$SERVER_DIR/$java_home"
export PATH="\$JAVA_HOME/bin:\$PATH"
if [ ! -x "\$JAVA_HOME/bin/java" ]; then
    echo "Java \$JAVA_HOME/bin/java not found (major $java_major)" >&2
    exit 1
fi
exec "\$@"
EOF
}

sub mc_loader_label {
    my ($loader, $lang) = @_;
    my $cfg = mc_loader_config($loader);
    return $loader unless $cfg;
    $lang //= 'de';
    return $lang eq 'de' ? ($cfg->{'label_de'} // $loader) : ($cfg->{'label_en'} // $loader);
}

sub mc_eula_path {
    my ($server_dir) = @_;
    return "$server_dir/serverfiles/eula.txt";
}

sub mc_eula_file_content {
    return "eula=true\n";
}

sub mc_profile_has_eula_acceptance {
    my ($profile) = @_;
    return 0 unless ref($profile) eq 'HASH';
    my $v = $profile->{'eula_accepted'};
    return 0 unless defined $v;
    return 1 if $v eq '1' || $v == 1;
    return 1 if lc("$v") eq 'true';
    return 0;
}

# Write serverfiles/eula.txt as the game Unix user when EULA was accepted in the wizard.
sub write_mc_eula_file {
    my ($server_dir, $unix_user) = @_;
    return 0 unless defined $server_dir && $server_dir =~ /\S/;
    return 0 unless defined $unix_user && $unix_user =~ /^[a-zA-Z0-9_.-]+$/;
    my $path = mc_eula_path($server_dir);
    my $dir  = "$server_dir/serverfiles";
    (my $safe_dir  = $dir)  =~ s/'/'\\''/g;
    (my $safe_path = $path) =~ s/'/'\\''/g;
    my $content = mc_eula_file_content();
    open(my $pipe, '|-', 'su', '-s', '/bin/bash', '-c', "mkdir -p '$safe_dir' && cat > '$safe_path'", $unix_user)
        or return 0;
    print $pipe $content;
    close($pipe) or return 0;
    return 1;
}

# Create eula.txt when profile records acceptance and the file is not present yet.
sub ensure_mc_eula_file {
    my ($server_dir, $unix_user) = @_;
    my $profile = read_mc_profile($server_dir);
    return 0 unless mc_profile_has_eula_acceptance($profile);
    return 1 if -f mc_eula_path($server_dir);
    return write_mc_eula_file($server_dir, $unix_user);
}

1;
