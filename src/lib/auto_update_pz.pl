# LinuxGSM-WebCore — Project Zomboid auto-update adapter (detect + broadcast + players)
use strict;
use warnings;

return 1 if defined &auto_update_adapter_for_script;

use constant PZ_GAME_APPID     => 380870;
use constant PZ_WORKSHOP_APPID => 108600;

# Test hooks — override network/Steam fetches in unit tests.
our $AUTO_UPDATE_PZ_REMOTE_BUILD_FETCH   = undef;  # () => ($buildid, $err)
our $AUTO_UPDATE_PZ_STEAM_DETAILS_FETCH  = undef;  # ($ids_aref) => \%details

sub auto_update_adapter_for_script {
    my ($script) = @_;
    return '' unless defined $script && $script =~ /\S/;
    $script =~ s/[^a-zA-Z0-9_-]//g;
    return '' unless $script ne '';

    my $canon = defined &_resolve_meta_key ? &_resolve_meta_key($script) : $script;
    return '' unless $canon eq 'pzserver' || $script =~ /^pz/i;

    if (defined &game_has_workshop_support) {
        return &game_has_workshop_support($script) ? 'pz' : '';
    }
    return 'pz';
}

sub _auto_update_pz_appmanifest_paths {
    my ($server_dir) = @_;
    return () unless defined $server_dir && $server_dir ne '';
    my $name = 'appmanifest_' . PZ_GAME_APPID . '.acf';
    return (
        "$server_dir/serverfiles/steamapps/$name",
        "$server_dir/steamapps/$name",
        "$server_dir/serverfiles/steamcmd/steamapps/$name",
    );
}

sub _auto_update_pz_parse_buildid_from_acf {
    my ($path) = @_;
    return '' unless defined $path && -f $path;
    open(my $fh, '<', $path) or return '';
    local $/;
    my $body = <$fh> // '';
    close($fh);
    return '' unless $body =~ /\S/;
    if ($body =~ /"buildid"\s+"(\d+)"/) {
        return $1;
    }
    return '';
}

sub auto_update_pz_game_build_local {
    my ($server_dir) = @_;
    return '' unless defined $server_dir && $server_dir ne '';
    for my $path (_auto_update_pz_appmanifest_paths($server_dir)) {
        my $build = _auto_update_pz_parse_buildid_from_acf($path);
        return $build if $build ne '';
    }
    return '';
}

# Remote dedicated build via SteamCMD +app_info_print (public branch buildid).
# Chosen over a Steam Web API call: no dedicated "latest build" endpoint in-repo;
# steamcmd is already the LGSM update source of truth. Soft-fails on error.
sub _auto_update_pz_remote_build_steamcmd {
    my $steamcmd = defined &detect_steamcmd ? detect_steamcmd() : undef;
    return ('', 'steamcmd_missing') unless defined $steamcmd && -x $steamcmd;

    my @cmd = (
        $steamcmd,
        '+@sSteamCmdForcePlatformType', 'linux',
        '+login', 'anonymous',
        '+app_info_print', PZ_GAME_APPID,
        '+quit',
    );
    my $out = '';
    {
        local $SIG{__WARN__} = sub { };
        open(my $fh, '-|', @cmd) or return ('', 'steamcmd_failed');
        local $/;
        $out = <$fh> // '';
        close($fh);
        return ('', 'steamcmd_failed') if $? != 0;
    }
    my $build = _auto_update_pz_parse_app_info_public_build($out);
    return ($build, $build ne '' ? undef : 'parse_failed');
}

sub _auto_update_pz_parse_app_info_public_build {
    my ($text) = @_;
    return '' unless defined $text && $text =~ /\S/;
    if ($text =~ /"public"[\s\S]*?"buildid"\s+"(\d+)"/) {
        return $1;
    }
    return '';
}

sub _auto_update_pz_require_steam {
    return if defined &detect_steamcmd;
    my $lib = __FILE__;
    $lib =~ s{/[^/]+$}{};
    require "$lib/steam.pl" if -f "$lib/steam.pl";
}

sub auto_update_pz_game_build_remote {
    if (ref($AUTO_UPDATE_PZ_REMOTE_BUILD_FETCH) eq 'CODE') {
        return $AUTO_UPDATE_PZ_REMOTE_BUILD_FETCH->();
    }
    _auto_update_pz_require_steam();
    return _auto_update_pz_remote_build_steamcmd();
}

sub _auto_update_pz_workshop_local_mtime {
    my ($roots, $wid) = @_;
    $wid =~ s/[^0-9]//g;
    return 0 unless length $wid;
    my $best = 0;
    for my $root (@{ $roots // [] }) {
        my $dir = "$root/$wid";
        next unless -d $dir;
        my $mtime = (stat($dir))[9] // 0;
        $best = $mtime if $mtime > $best;
    }
    return $best;
}

sub _auto_update_pz_fetch_steam_details {
    my ($ids) = @_;
    if (ref($AUTO_UPDATE_PZ_STEAM_DETAILS_FETCH) eq 'CODE') {
        return $AUTO_UPDATE_PZ_STEAM_DETAILS_FETCH->($ids);
    }
    return pz_workshop_steam_details($ids) if defined &pz_workshop_steam_details;
    return {};
}

sub auto_update_pz_workshop_diff {
    my ($unix_user, $server_dir, $script) = @_;
    my %out = (changed => [], err => '');

    my $key = defined &steam_web_api_key ? steam_web_api_key() : '';
    unless ($key =~ /\S/) {
        $out{err} = 'api_key_missing';
        return \%out;
    }

    my ($ini_ok, $ini) = pz_workshop_resolve_ini_path($unix_user, $script);
    unless ($ini_ok && defined $ini) {
        $out{err} = 'no_ini';
        return \%out;
    }

    my ($vals) = pz_workshop_read_ini($ini);
    my @ids = pz_workshop_split_list($vals->{'WorkshopItems'} // '');
    return \%out unless @ids;

    my $appid = defined &get_workshop_appid ? get_workshop_appid($script) : 0;
    $appid = PZ_WORKSHOP_APPID unless $appid > 0;

    my @roots = pz_workshop_content_roots($unix_user, $server_dir, $appid);
    my $details = _auto_update_pz_fetch_steam_details(\@ids);
    unless (ref($details) eq 'HASH' && keys %$details) {
        $out{err} = 'api_failed';
        return \%out;
    }

    my @changed;
    for my $wid (@ids) {
        my $entry = $details->{$wid};
        next unless ref($entry) eq 'HASH';
        my $remote = int($entry->{'time_updated'} // 0);
        next unless $remote > 0;
        my $local = _auto_update_pz_workshop_local_mtime(\@roots, $wid);
        push @changed, $wid if $remote > $local;
    }
    $out{changed} = \@changed;
    return \%out;
}

sub _auto_update_pz_read_lgsm_kv {
    my ($path, $key) = @_;
    return '' unless defined $path && -f $path;
    open(my $fh, '<', $path) or return '';
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/\r//g;
        next if $line =~ /^\s*#/ || $line !~ /=/;
        my ($k, $v) = split /=/, $line, 2;
        $k =~ s/^\s+|\s+$//g;
        $v =~ s/^\s+|\s+$//g;
        $v =~ s/^["']|["']$//g;
        return $v if defined $k && $k eq $key;
    }
    close($fh);
    return '';
}

sub auto_update_pz_player_count {
    my ($server_dir, $script) = @_;
    return -1 unless auto_update_adapter_for_script($script) eq 'pz';
    return -1 unless defined $server_dir && $server_dir ne '';

    $script =~ s/[^a-zA-Z0-9_-]//g;
    return -1 unless $script ne '';

    my $qfield = defined &get_game_query_port_field ? get_game_query_port_field($script) : 'queryport';
    $qfield = 'queryport' unless defined $qfield && $qfield =~ /\S/;

    my $cfg = "$server_dir/lgsm/config-lgsm/$script/$script.cfg";
    my $qport = _auto_update_pz_read_lgsm_kv($cfg, $qfield);
    return -1 unless defined $qport && $qport =~ /^\d+$/ && int($qport) > 0;

    unless (defined &a2s_query) {
        my $lib = __FILE__;
        $lib =~ s{/[^/]+$}{};
        require "$lib/query.pl" if -f "$lib/query.pl";
    }
    return -1 unless defined &a2s_query;

    my $qdata = a2s_query('127.0.0.1', int($qport), 2);
    return -1 unless ref($qdata) eq 'HASH';
    return int($qdata->{players} // -1);
}

sub _auto_update_pz_escape_servermsg {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/[\r\n]+/ /g;
    $text =~ s/\\/\\\\/g;
    $text =~ s/"/\\"/g;
    $text =~ s/\$/\\\$/g;
    $text =~ s/`/\\`/g;
    return $text;
}

sub auto_update_pz_broadcast_cmd {
    my ($text) = @_;
    my $escaped = _auto_update_pz_escape_servermsg($text);
    return qq{servermsg "$escaped"};
}

# Single-quoted KEY='value' for safe bash eval (same idea as lifecycle_env.pl).
sub _auto_update_pz_bash_kv {
    my ($k, $v) = @_;
    $v = '' unless defined $v;
    $v =~ s/'/'\\''/g;
    return sprintf("%s='%s'", $k, $v);
}

# Run full detect pass. Returns hashref suitable for shell KEY=value output.
sub auto_update_pz_detect {
    my ($unix_user, $server_dir, $script, $opts) = @_;
    $opts = {} unless ref($opts) eq 'HASH';
    my $check_game     = ($opts->{check_game}     // 1) ? 1 : 0;
    my $check_workshop = ($opts->{check_workshop} // 1) ? 1 : 0;

    my %out = (
        need_game     => 0,
        need_workshop => 0,
        mods          => [],
        players       => -1,
        reason        => '',
        err           => '',
    );

    if (auto_update_adapter_for_script($script) eq '') {
        $out{err} = 'unsupported_game';
        return \%out;
    }

    my @reason_parts;
    my @errs;

    if ($check_game) {
        my $local = auto_update_pz_game_build_local($server_dir);
        my ($remote, $gerr) = auto_update_pz_game_build_remote();
        if ($gerr) {
            push @errs, "game:$gerr";
        } elsif ($remote ne '' && $local ne '' && $remote ne $local) {
            $out{need_game} = 1;
            push @reason_parts, 'Spiel-Update';
        } elsif ($remote ne '' && $local eq '') {
            $out{need_game} = 1;
            push @reason_parts, 'Spiel-Update';
        }
    }

    if ($check_workshop) {
        my $wd = auto_update_pz_workshop_diff($unix_user, $server_dir, $script);
        if (ref($wd) eq 'HASH') {
            if ($wd->{err}) {
                push @errs, 'workshop:' . $wd->{err};
            }
            if (ref($wd->{changed}) eq 'ARRAY' && @{ $wd->{changed} }) {
                $out{need_workshop} = 1;
                push @{ $out{mods} }, @{ $wd->{changed} };
                push @reason_parts, 'Workshop-Update';
            }
        }
    }

    $out{players} = auto_update_pz_player_count($server_dir, $script);
    $out{reason}  = join(' + ', @reason_parts);
    $out{reason} =~ s/[\r\n]+/ /g;
    $out{err}     = join(';', @errs) if @errs;
    return \%out;
}

sub auto_update_pz_detect_print {
    my ($result) = @_;
    $result = {} unless ref($result) eq 'HASH';
    my $mods = ref($result->{mods}) eq 'ARRAY' ? join(',', @{ $result->{mods} }) : '';
    print 'NEED_GAME=' . (($result->{need_game} // 0) ? 1 : 0) . "\n";
    print 'NEED_WORKSHOP=' . (($result->{need_workshop} // 0) ? 1 : 0) . "\n";
    print _auto_update_pz_bash_kv('MODS', $mods) . "\n";
    print 'PLAYERS=' . int($result->{players} // -1) . "\n";
    print _auto_update_pz_bash_kv('REASON', $result->{reason} // '') . "\n";
    my $err = $result->{err} // '';
    print _auto_update_pz_bash_kv('ERR', $err) . "\n" if $err ne '';
    return 1;
}

1;
