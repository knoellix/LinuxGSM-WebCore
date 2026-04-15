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

# Return game config format string ('properties', 'ini_option_settings', or '').
sub get_game_config_format {
    my ($script_name) = @_;
    my %meta = load_games_meta();
    my $key   = _resolve_meta_key($script_name);
    my $entry = $meta{$key} or return '';
    return $entry->{'game_config_format'} // '';
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
    for my $key (keys %$data) {
        $meta_ref->{$key} = $data->{$key};
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

# Reset the module-level cache (used in tests to reload different fixtures).
sub _reset_meta_cache {
    %_meta_cache  = ();
    $_meta_loaded = 0;
}

1;
