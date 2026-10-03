# LinuxGSM-WebCore - Game metadata database
#
# Provides field definitions and display names per LGSM script name.
# Data sources (merged in order, later entries override earlier):
#   1. $module_root/lib/games_meta.json      — static, shipped with module
#   2. $config_directory/games_meta_local.json — admin-editable local overrides
#
# JSON format (each top-level key is an LGSM script name):
#   {
#     "mcserver": {
#       "name": "Minecraft (Vanilla)",
#       "live_log_path": "optional/relative/to/script_dir.log",
#       "fields": [
#         {"key":"port","type":"port","label_de":"Port","label_en":"Port","default":"25565"},
#         ...
#       ]
#     }
#   }
use strict;
use warnings;

our ($module_root, $config_directory);

# Module-level cache — valid for the lifetime of one CGI request.
my %_meta_cache;
my $_meta_loaded = 0;

# Return merged hash of all game metadata (script_name -> hashref).
sub load_games_meta {
    unless ($_meta_loaded) {
        my $base_file  = defined $module_root  ? "$module_root/lib/games_meta.json"             : undef;
        my $local_file = defined $config_directory ? "$config_directory/games_meta_local.json"  : undef;
        _merge_meta(\%_meta_cache, $base_file)  if defined $base_file  && -f $base_file;
        _merge_meta(\%_meta_cache, $local_file) if defined $local_file && -f $local_file;
        $_meta_loaded = 1;
    }
    return %_meta_cache;
}

# Resolve a script name to its canonical metadata key.
# Handles direct matches first, then checks the 'variants' arrays.
# Returns the canonical key if found, or the original name as fallback.
sub _resolve_meta_key {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    return $script_name if exists $meta{$script_name};
    # LGSM wizard passes CSV shortnames (mc, pmc) — resolve to script (mcserver, pmcserver).
    if (defined &resolve_lgsm_game_script) {
        my $resolved = &resolve_lgsm_game_script($script_name);
        if ($resolved ne $script_name && exists $meta{$resolved}) {
            return $resolved;
        }
        $script_name = $resolved if $resolved ne $script_name;
    }
    for my $key (keys %meta) {
        my $entry = $meta{$key};
        next unless ref($entry) eq 'HASH';
        my @variants = @{ $entry->{'variants'} // [] };
        return $key if grep { $_ eq $script_name } @variants;
    }
    return $script_name;
}

# Return array of field-definition hashes for the given script name.
# Each hash: { key, type, label_de, label_en, default }
# Returns empty list for unknown scripts.
# Resolves variant names to their canonical entry automatically.
sub get_game_fields {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key   = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return ();
    return @{ $entry->{'fields'} // [] };
}

# Return game config field definitions (for the actual game server config file,
# e.g. server.properties for Minecraft). Falls back to empty list.
sub get_game_config_fields {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key   = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return ();
    return @{ $entry->{'game_config_fields'} // [] };
}

# Return game config format string ('properties', 'ini_option_settings',
# 'json', or '').
sub get_game_config_format {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key   = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return '';
    return $entry->{'game_config_format'} // '';
}

# Return the path of the game-server's primary config file relative to the
# instance's $script_dir (or unix home when get_game_config_path_base eq 'home').
# Empty string means "no static hint, fall back to LGSM resolution".
sub get_game_config_path {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key   = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return '';
    return $entry->{'game_config_path'} // '';
}

# Where get_game_config_path is rooted: 'home' (unix home) or 'script' (default).
# Project Zomboid stores server INI under $HOME/Zomboid/Server/, not $script_dir.
sub get_game_config_path_base {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key   = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return 'script';
    my $base = $entry->{'game_config_path_base'} // 'script';
    return ($base eq 'home') ? 'home' : 'script';
}

# Resolve unix home for game-config paths rooted at home.
# Prefer getpwnam($unix_user); fall back to parent of $script_dir (/home/user/srv → /home/user).
sub resolve_game_config_home {
    my ($unix_user, $script_dir) = @_;
    if (defined $unix_user && $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/) {
        my @pw = getpwnam($unix_user);
        if (@pw && defined $pw[7] && $pw[7] =~ m|^/|) {
            (my $h = $pw[7]) =~ s{/\z}{};
            return $h;
        }
    }
    if (defined $script_dir && $script_dir =~ m|^(/home/[^/]+)/|) {
        return $1;
    }
    return '';
}

# Optional UI label for the game-config tab (e.g. Palworld "World settings").
sub get_game_config_label {
    my ($script_name, $lang) = @_;
    my %meta = load_games_meta();
    my $key = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return '';
    $lang = ($lang // '') eq 'de' ? 'de' : 'en';
    my $k = "game_config_label_$lang";
    return $entry->{$k} // '';
}

# Relative path of SandboxVars.lua (PZ world settings), same base as game_config_path.
sub get_game_sandbox_path {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key   = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return '';
    my $p = $entry->{'game_sandbox_path'} // '';
    return $p if $p =~ /\S/;
    # Derive from game_config_path: foo.ini → foo_SandboxVars.lua
    my $ini = $entry->{'game_config_path'} // '';
    return '' unless $ini =~ /\.ini\z/i;
    (my $derived = $ini) =~ s/\.ini\z/_SandboxVars.lua/i;
    return $derived;
}

sub get_game_sandbox_label {
    my ($script_name, $lang) = @_;
    my %meta = load_games_meta();
    my $key = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return '';
    $lang = ($lang // '') eq 'de' ? 'de' : 'en';
    my $k = "game_sandbox_label_$lang";
    return $entry->{$k} // '';
}

# Return mod_support string from games_meta (e.g. workshop), or ''.
sub get_game_mod_support {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return '';
    my $ms = $entry->{'mod_support'} // '';
    $ms =~ s/[^a-z0-9_]//g;
    return $ms;
}

# Return path of the primary live server log file, relative to the instance
# script_dir (same convention as game_config_path). Used by manage.cgi
# monitor view so UE/Wine games can prefer R5.log over wrapper server.log.
# Empty string if unset or unsafe (absolute path, ..).
sub get_game_live_log_path {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key  = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return '';
    my $p = $entry->{'live_log_path'} // '';
    return '' unless $p =~ /\S/;
    $p =~ s/^\s+|\s+$//g;
    return '' if $p =~ m{(?:^|/)\.\.(?:/|$)};
    return '' if $p =~ m{^/};
    return $p;
}

# Return human-readable display name for the given script name.
# Falls back to the script name itself if not found in metadata.
# Resolves variant names to their canonical entry automatically.
sub get_game_display_name {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key   = _resolve_meta_key($script_name);
    return $meta{$key}{'name'} // $script_name;
}

# Return 1 if the game requires a Steam login to download, 0 otherwise.
# Unknown games return 0 (safe default).
sub game_requires_steam {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key  = _resolve_meta_key($script_name);
    return 0 unless defined $key && exists $meta{$key};
    return $meta{$key}{'steam_required'} ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

sub _merge_meta {
    my ($meta_ref, $file) = @_;
    open(my $fh, '<', $file) or return;
    local $/;
    my $json = <$fh>;
    close($fh);
    my $data = _parse_json_object($json);
    return unless $data;
    # Shallow merge per entry: a local override should refine specific fields
    # (name, fields, default port, …) without erasing base attributes the
    # admin UI doesn't even know about (game_config_path, game_config_format,
    # launch_candidates, runtime, apt_deps, …). Without this, Wizard-saved
    # custom games would silently lose the new editor metadata on every
    # release that ships extra static fields.
    for my $key (keys %$data) {
        my $local = $data->{$key};
        if (ref($local) eq 'HASH'
            && exists $meta_ref->{$key}
            && ref($meta_ref->{$key}) eq 'HASH')
        {
            for my $field (keys %$local) {
                $meta_ref->{$key}{$field} = $local->{$field};
            }
        } else {
            $meta_ref->{$key} = $local;
        }
    }
}

# Minimal JSON decoder using JSON::PP (Perl core since 5.14).
# Falls back to empty hashref on parse error.
sub _parse_json_object {
    my ($json) = @_;
    my $data = eval {
        require JSON::PP;
        JSON::PP::decode_json($json);
    };
    return (ref $data eq 'HASH') ? $data : {};
}

# Return the default port for the given game script name.
# Searches the fields array for a port-type field with a default value.
# Falls back to 27015 (Source engine default) if not found.
sub get_game_default_port {
    my ($script_name) = @_;
    my @fields = get_game_fields($script_name);
    for my $f (@fields) {
        return int($f->{'default'}) if ($f->{'type'} // '') eq 'port' && defined $f->{'default'};
    }
    return 27015;
}

# Returns sorted list of non-LGSM games from games_meta.json.
# Each entry: { shortname, name, source }
# Only games with an explicit 'source' field (e.g. 'steamcmd') are included.
sub get_custom_game_list {
    my %meta = load_games_meta();
    my @games;
    for my $script (sort keys %meta) {
        my $entry  = $meta{$script};
        my $source = $entry->{'source'} // '';
        next unless $source && $source ne 'lgsm';
        push @games, {
            shortname => $script,
            name      => $entry->{'name'} // $script,
            source    => $source,
        };
    }
    return sort { $a->{'name'} cmp $b->{'name'} } @games;
}

# Returns the installation source for a game script.
# Returns 'lgsm' for unknown / LGSM games, otherwise the value from games_meta.json.
sub get_game_source {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key  = _resolve_meta_key($script_name);
    return $meta{$key}{'source'} if defined $meta{$key} && defined $meta{$key}{'source'};
    return 'lgsm';
}

# Returns a hashref { field_key => { de => "...", en => "..." } } for a game's field hints.
# Hints live at the game entry level (not inside the fields array) so local overrides
# of `fields` do not erase them. Returns empty hashref for unknown games.
sub get_game_field_hints {
    my ($script) = @_;
    my %meta = load_games_meta();
    my $key  = _resolve_meta_key($script);
    return {} unless defined $meta{$key};
    return $meta{$key}{'field_hints'} // {};
}

# Canonical LGSM startparameters for PZ when adminpassword is set.
# Inner quotes must be backslash-escaped so fn_reload_startparameters eval works.
sub pz_lgsm_startparameters_with_admin {
    return '-servername ${selfname} -adminpassword \"${adminpassword}\"';
}

# Project Zomboid: LGSM _default.cfg defines adminpassword but startparameters
# is only "-servername ${selfname}" — the game never sees -adminpassword unless
# we add it here. Returns 1 if startparameters was changed.
sub ensure_pz_lgsm_startparameters {
    my ($script_name, $vals) = @_;
    return 0 unless ref($vals) eq 'HASH';
    return 0 unless defined $script_name && $script_name =~ /\S/;
    my $canon = defined &_resolve_meta_key ? &_resolve_meta_key($script_name) : $script_name;
    return 0 unless $canon eq 'pzserver' || $script_name =~ /^pz/i;

    my $ap = $vals->{'adminpassword'} // '';
    $ap =~ s/^\s+|\s+$//g;
    return 0 if $ap eq '' || $ap eq 'CHANGE_ME';

    my $want = pz_lgsm_startparameters_with_admin();
    my $sp   = $vals->{'startparameters'} // '';
    return 0 if $sp eq $want;
    $vals->{'startparameters'} = $want;
    return 1;
}

# Session-only monitor (querymode=1). GameDig often false-fails on PZ and
# LGSM monitor then stop→start loops while the world is still healthy.
sub ensure_pz_lgsm_querymode {
    my ($script_name, $vals) = @_;
    return 0 unless ref($vals) eq 'HASH';
    return 0 unless defined $script_name && $script_name =~ /\S/;
    my $canon = defined &_resolve_meta_key ? &_resolve_meta_key($script_name) : $script_name;
    return 0 unless $canon eq 'pzserver' || $script_name =~ /^pz/i;

    my $qm = $vals->{'querymode'} // '';
    return 0 if $qm eq '1';
    $vals->{'querymode'} = '1';
    return 1;
}

# Sync instance cfg on disk before PZ start (worker / standalone script).
# Returns 1 if file was rewritten.
sub sync_pz_lgsm_instance_cfg {
    my ($server_dir, $script_name) = @_;
    return 0 unless defined $server_dir && $server_dir =~ m|^/|;
    $script_name =~ s/[^a-zA-Z0-9_-]//g;
    return 0 unless $script_name ne '';

    my $cfg_path = "$server_dir/lgsm/config-lgsm/$script_name/$script_name.cfg";
    return 0 unless -f $cfg_path;

    my $root = $module_root // '';
    return 0 unless $root ne '' && -f "$root/lib/config_editor.pl";
    require "$root/lib/config_editor.pl";
    return 0 unless defined &read_config_file;

    my ($vals, $order, $raw) = &read_config_file($cfg_path);
    my $changed = 0;
    $changed |= &ensure_pz_lgsm_startparameters($script_name, $vals);
    $changed |= &ensure_pz_lgsm_querymode($script_name, $vals);
    return 0 unless $changed;

    push @$order, 'startparameters' unless grep { $_ eq 'startparameters' } @$order;
    push @$order, 'querymode'     unless grep { $_ eq 'querymode' } @$order;
    my $content = join('', map { exists $vals->{$_} ? "$_=\"$vals->{$_}\"\n" : () } @$order);
    open(my $fh, '>:raw', $cfg_path) or return 0;
    print {$fh} $content;
    close($fh) or return 0;
    return (-f $cfg_path) ? 1 : 0;
}

# Return start-ready log polling config for a game script.
# Empty/missing meta → { log => '', regex => '', secs => 0 }.
sub get_start_ready_config {
    my ($script) = @_;
    $script //= '';
    $script =~ s/[^a-zA-Z0-9_\-]//g;
    my %meta = load_games_meta();
    my $g = $meta{$script} // {};
    my $log = $g->{start_ready_log} // '';
    my $re  = $g->{start_ready_regex} // '';
    my $secs = int($g->{start_ready_secs} // 0);
    $secs = 0 if $secs < 0;
    $secs = 3600 if $secs > 3600;
    return { log => "$log", regex => "$re", secs => $secs };
}

# Find parent meta key that lists $script in variants[] (for stubs without ready fields).
# Returns '' when no parent found.
sub _lifecycle_parent_key {
    my ($script, $meta_ref) = @_;
    $script //= '';
    return '' unless length($script) && ref($meta_ref) eq 'HASH';
    for my $key (sort keys %$meta_ref) {
        next if $key eq $script;
        my $entry = $meta_ref->{$key};
        next unless ref($entry) eq 'HASH';
        my @variants = @{ $entry->{'variants'} // [] };
        return $key if grep { $_ eq $script } @variants;
    }
    return '';
}

# Full start/stop lifecycle config (ready + stall + phases + stop grace).
# Variant stubs without start_ready_regex inherit from the parent that lists them
# in variants[] (e.g. mc-neoforge → mcserver).
# Defaults: stall 120/300, stop grace/force 120/180, empty phase arrays.
# Clamps secs to 0..3600; raises stall_fail to stall (and force to grace) when inverted.
sub get_lifecycle_config {
    my ($script) = @_;
    my $base = get_start_ready_config($script);
    $script //= '';
    $script =~ s/[^a-zA-Z0-9_\-]//g;
    my %meta = load_games_meta();
    my $g = $meta{$script} // {};

    # Stub variants exist as own keys but lack ready/lifecycle — inherit from parent.
    if (!length($g->{start_ready_regex} // '')) {
        my $parent = _lifecycle_parent_key($script, \%meta);
        if (!length($parent)) {
            my $resolved = eval { _resolve_meta_key($script) } || $script;
            $parent = $resolved if $resolved ne $script && exists $meta{$resolved};
        }
        if (length($parent) && exists $meta{$parent}) {
            $g = $meta{$parent} // {};
            $base = get_start_ready_config($parent);
        }
    }

    my $stall = int($g->{start_stall_secs} // 120);
    my $stall_fail = int($g->{start_stall_fail_secs} // 300);
    $stall = 0 if $stall < 0; $stall = 3600 if $stall > 3600;
    $stall_fail = 0 if $stall_fail < 0; $stall_fail = 3600 if $stall_fail > 3600;
    if ($stall > 0 && $stall_fail > 0 && $stall_fail < $stall) {
        $stall_fail = $stall;
    }
    my $sg = int($g->{stop_grace_secs} // 120);
    my $sf = int($g->{stop_force_secs} // 180);
    $sg = 0 if $sg < 0; $sg = 3600 if $sg > 3600;
    $sf = 0 if $sf < 0; $sf = 3600 if $sf > 3600;
    if ($sf > 0 && $sg > 0 && $sf < $sg) { $sf = $sg; }

    my @sp = ();
    if (ref($g->{start_phases}) eq 'ARRAY') {
        for my $p (@{ $g->{start_phases} }) {
            next unless ref($p) eq 'HASH';
            my $id = $p->{id} // '';
            $id =~ s/[^a-zA-Z0-9_\-]//g;
            next unless length($id);
            push @sp, {
                id => $id,
                label_de => '' . ($p->{label_de} // $id),
                label_en => '' . ($p->{label_en} // $id),
                match => '' . ($p->{match} // ''),
            };
        }
    }
    my @stp = ();
    if (ref($g->{stop_phases}) eq 'ARRAY') {
        for my $p (@{ $g->{stop_phases} }) {
            next unless ref($p) eq 'HASH';
            my $id = $p->{id} // '';
            $id =~ s/[^a-zA-Z0-9_\-]//g;
            next unless length($id);
            push @stp, {
                id => $id,
                label_de => '' . ($p->{label_de} // $id),
                label_en => '' . ($p->{label_en} // $id),
                match => '' . ($p->{match} // ''),
            };
        }
    }

    my $live = '' . ($g->{live_log_path} // $base->{live_log_path} // '');
    $live =~ s/^\s+|\s+$//g;
    $live = '' if $live =~ m{(?:^|/)\.\.(?:/|$)};
    $live = '' if $live =~ m{^/};

    return {
        %$base,
        stall_secs => $stall,
        stall_fail_secs => $stall_fail,
        start_phases => \@sp,
        stop_grace_secs => $sg,
        stop_force_secs => $sf,
        stop_phases => \@stp,
        live_log_path => $live,
    };
}

# Map workshop item count → ready/stall tier (replaces meta for that start).
# Tiers: 0–9 / 10–29 / 30–49 / ≥50.
sub workshop_start_scale_tier {
    my ($tier_n) = @_;
    $tier_n = int($tier_n // 0);
    $tier_n = 0 if $tier_n < 0;
    if ($tier_n <= 9) {
        return { ready_secs => 900, stall_secs => 120, stall_fail_secs => 300 };
    }
    if ($tier_n <= 29) {
        return { ready_secs => 1200, stall_secs => 180, stall_fail_secs => 420 };
    }
    if ($tier_n <= 49) {
        return { ready_secs => 1500, stall_secs => 240, stall_fail_secs => 480 };
    }
    return { ready_secs => 1800, stall_secs => 300, stall_fail_secs => 600 };
}

# Workshop start scale for games with mod_support=workshop (v1: PZ via pz_workshop.pl).
# Returns undef for non-workshop games. Tier from max(configured INI items, pending vs disk).
sub get_workshop_start_scale {
    my ($script_name, $unix_user, $server_dir) = @_;
    $script_name //= '';
    $script_name =~ s/[^a-zA-Z0-9_\-]//g;
    return undef unless length($script_name);
    return undef unless get_game_mod_support($script_name) eq 'workshop';

    unless (defined &pz_workshop_split_list) {
        my $pz_lib;
        if (defined $module_root && length($module_root) && -f "$module_root/lib/pz_workshop.pl") {
            $pz_lib = "$module_root/lib/pz_workshop.pl";
        }
        else {
            require File::Basename;
            my $here = File::Basename::dirname(__FILE__);
            $pz_lib = "$here/pz_workshop.pl" if -f "$here/pz_workshop.pl";
        }
        require $pz_lib if defined $pz_lib && length($pz_lib);
    }
    return undef unless defined &pz_workshop_split_list;

    my $n       = 0;
    my $pending = 0;
    my ($ok, $ini) = pz_workshop_resolve_ini_path($unix_user // '', $script_name);
    if ($ok) {
        my ($vals) = pz_workshop_read_ini($ini);
        $vals = {} unless ref($vals) eq 'HASH';
        my @ids = pz_workshop_split_list($vals->{WorkshopItems} // '');
        $n = scalar @ids;
        my $appid = get_workshop_appid($script_name);
        my $disk  = {};
        if (defined $server_dir && $server_dir =~ m{^/} && $appid > 0) {
            $disk = pz_workshop_scan_disk($unix_user // '', $server_dir, $appid) // {};
        }
        $disk = {} unless ref($disk) eq 'HASH';
        $pending = scalar grep { !exists $disk->{$_} } @ids;
    }
    my $tier_n = $pending > $n ? $pending : $n;
    my $tier   = workshop_start_scale_tier($tier_n);
    return {
        items           => $n,
        pending         => $pending,
        ready_secs      => $tier->{ready_secs},
        stall_secs      => $tier->{stall_secs},
        stall_fail_secs => $tier->{stall_fail_secs},
    };
}

# Returns the query port field name for A2S-capable games.
# For games that support A2S UDP queries, returns the LGSM config key holding the query port
# (typically 'queryport'). Returns empty string for non-A2S games (e.g. Minecraft).
sub get_game_query_port_field {
    my ($script) = @_;
    my %meta = load_games_meta();
    my $key  = _resolve_meta_key($script);
    return $meta{$key}{'query_port_field'} // '';
}

# Returns the set of script names that exist in games_meta_local.json.
sub local_game_scripts {
    return () unless defined $config_directory;
    my $file = "$config_directory/games_meta_local.json";
    return () unless -f $file;
    my %loc;
    _merge_meta(\%loc, $file);
    return keys %loc;
}

# Write or update one entry in games_meta_local.json.
# $entry_ref is a hashref with keys: name, source, steam_app_id, fields, etc.
# Returns 1 on verified write, 0 on failure.
sub save_local_game_meta {
    my ($script_name, $entry_ref) = @_;
    return 0 unless defined $config_directory;
    return 0 unless defined $script_name && $script_name =~ /\S/;
    my $file = "$config_directory/games_meta_local.json";
    my %local;
    _merge_meta(\%local, $file) if -f $file;
    $local{$script_name} = $entry_ref;
    _write_local_meta($file, \%local) or return 0;
    my %verify;
    _merge_meta(\%verify, $file);
    return exists $verify{$script_name} ? 1 : 0;
}

# Remove one entry from games_meta_local.json. Returns 1 on verified delete.
sub delete_local_game_meta {
    my ($script_name) = @_;
    return 0 unless defined $config_directory;
    return 0 unless defined $script_name && $script_name =~ /\S/;
    my $file = "$config_directory/games_meta_local.json";
    return 1 unless -f $file;
    my %local;
    _merge_meta(\%local, $file);
    return 1 unless exists $local{$script_name};
    delete $local{$script_name};
    _write_local_meta($file, \%local) or return 0;
    my %verify;
    _merge_meta(\%verify, $file) if -f $file;
    return exists $verify{$script_name} ? 0 : 1;
}

sub _write_local_meta {
    my ($file, $data) = @_;
    my $ok = eval {
        require JSON::PP;
        my $json = JSON::PP->new->pretty->canonical->utf8;
        open(my $fh, '>', $file) or die "Cannot write $file: $!";
        print $fh $json->encode($data);
        close $fh;
        1;
    };
    if (!$ok) {
        warn "save_local_game_meta failed: $@" if $@;
        return 0;
    }
    _reset_meta_cache();
    return -f $file ? 1 : 0;
}

# Reset the module-level cache (used in tests to reload different fixtures).
sub _reset_meta_cache {
    %_meta_cache  = ();
    $_meta_loaded = 0;
}

1;
