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
# instance's $script_dir. Used by non-LGSM games (steamcmd/wine) where there
# is no LGSM cfg layer to drive servercfgfullpath.
# Empty string means "no static hint, fall back to LGSM resolution".
sub get_game_config_path {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key   = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return '';
    return $entry->{'game_config_path'} // '';
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
    open(my $fh, '<:encoding(UTF-8)', $file) or return;
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
sub save_local_game_meta {
    my ($script_name, $entry_ref) = @_;
    return unless defined $config_directory;
    my $file = "$config_directory/games_meta_local.json";
    my %local;
    _merge_meta(\%local, $file) if -f $file;
    $local{$script_name} = $entry_ref;
    _write_local_meta($file, \%local);
    _reset_meta_cache();
}

# Remove one entry from games_meta_local.json.
sub delete_local_game_meta {
    my ($script_name) = @_;
    return unless defined $config_directory;
    my $file = "$config_directory/games_meta_local.json";
    return unless -f $file;
    my %local;
    _merge_meta(\%local, $file);
    delete $local{$script_name};
    _write_local_meta($file, \%local);
    _reset_meta_cache();
}

sub _write_local_meta {
    my ($file, $data) = @_;
    eval {
        require JSON::PP;
        my $json = JSON::PP->new->pretty->canonical->utf8;
        open(my $fh, '>', $file) or die "Cannot write $file: $!";
        print $fh $json->encode($data);
        close $fh;
    };
    warn "save_local_game_meta failed: $@" if $@;
}

# Reset the module-level cache (used in tests to reload different fixtures).
sub _reset_meta_cache {
    %_meta_cache  = ();
    $_meta_loaded = 0;
}

1;
