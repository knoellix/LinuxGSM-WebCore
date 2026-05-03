# LinuxGSM-WebCore - Config file editor helpers
#
# Provides safe read/filter/validate helpers for the config editor in manage.cgi.
# Write operations stay in manage.cgi (require $unix_user + system_logged).
use strict;
use warnings;

# Validate that $path is a safe write target within lgsm/config-lgsm/.
# Allowed targets:
#   .../lgsm/config-lgsm/common.cfg
#   .../lgsm/config-lgsm/<script>/<script>.cfg
# Never allows _default.cfg.
# Calls error() on failure; returns 1 on success.
sub validate_config_target {
    my ($path) = @_;
    our %text;

    # Must be an absolute path
    &error($text{'err_invalid_input'}) unless defined $path && $path =~ m|^/|;

    # Never allow _default.cfg
    &error($text{'err_invalid_input'}) if $path =~ /_default\.cfg/;

    # Must be within lgsm/config-lgsm/
    unless ($path =~ m|/lgsm/config-lgsm/|) {
        &error($text{'err_invalid_input'});
    }

    # Must match one of the two allowed patterns
    unless (
        $path =~ m|^/[a-zA-Z0-9_./()\- ]+/lgsm/config-lgsm/common\.cfg$| ||
        $path =~ m|^/[a-zA-Z0-9_./()\- ]+/lgsm/config-lgsm/[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+\.cfg$|
    ) {
        &error($text{'err_invalid_input'});
    }

    return 1;
}

# Parse a LGSM config file.
# Returns: ($values_ref, $order_ref, $raw_scalar)
#   $values_ref — hashref: key => value (last-wins for duplicates)
#   $order_ref  — arrayref: keys in order of first appearance
#   $raw_scalar — full raw file content (empty string if file absent)
sub read_config_file {
    my ($path) = @_;
    my (%values, @order);
    my $raw = '';

    return (\%values, \@order, $raw) unless -f $path;

    open(my $fh, '<', $path) or return (\%values, \@order, $raw);
    while (<$fh>) {
        $raw .= $_;
        chomp(my $line = $_);
        next if $line =~ /^\s*#/;   # comment
        next if $line =~ /^\s*$/;   # blank
        next if $line =~ /^\[/;     # bash conditional
        if ($line =~ /^\s*(\w+)\s*=\s*["']?([^"'\n]*)["']?\s*$/) {
            my ($k, $v) = ($1, $2);
            push @order, $k unless exists $values{$k};
            $values{$k} = $v;
        }
    }
    close($fh);

    return (\%values, \@order, $raw);
}

# Filter raw config content: remove blank lines and dangerous bash constructs.
# Returns arrayref of valid lines (comments + key=value assignments only).
sub filter_raw_config {
    my ($content) = @_;
    my @out;

    for my $line (split /\n/, $content) {
        $line =~ s/\r$//;  # strip CR (Windows line endings)
        next if $line =~ /^\s*$/;   # blank line
        next if $line =~ /^\[/;     # bash conditional [
        # Reject bash control flow operators
        next if $line =~ /&&|\|\||\bif\b|\bfi\b|\bthen\b|\belse\b/;
        # Allow: comment lines and valid key="value" or key=value assignments
        if ($line =~ /^\s*#/ || $line =~ /^\s*\w+\s*=\s*["']?[^"'\n]*["']?\s*$/) {
            push @out, $line;
        }
    }

    return \@out;
}

# Split editable fields for config editor based on selected config file.
# Returns: ($editable_game_fields_ref, $unknown_keys_ref, $known_keys_ref)
# - instance view: game fields are editable
# - common view: game fields are hidden from editing; only non-game keys remain
sub split_editor_fields {
    my ($cfg_file_key, $game_fields_ref, $cur_vals_ref, $cur_order_ref) = @_;

    my @game_fields = @{$game_fields_ref || []};
    my %known_keys  = map { $_->{'key'} => $_ } @game_fields;

    my @editable_game_fields =
        ($cfg_file_key eq 'instance' || $cfg_file_key eq 'game') ? @game_fields : ();
    my @unknown_keys;
    if ($cfg_file_key eq 'instance') {
        @unknown_keys = grep { !$known_keys{$_} } @{$cur_order_ref || []};
    } elsif ($cfg_file_key eq 'game') {
        @unknown_keys = ();
    } else {
        @unknown_keys = grep { !$known_keys{$_} } @{$cur_order_ref || []};
    }

    return (\@editable_game_fields, \@unknown_keys, \%known_keys);
}

# ---------------------------------------------------------------------------
# Game config format detection and .properties support
# ---------------------------------------------------------------------------

# Detect the format of a game-server config file.
# Returns 'json' (Windrose & co.), 'ini_option_settings' (Palworld),
# 'properties', or 'unknown'.
sub detect_game_config_format {
    my ($path, $raw) = @_;
    return 'unknown' unless defined $raw && length $raw;
    # Path-driven shortcuts beat content heuristics so empty/templated files
    # still resolve to a sensible parser.
    if (defined $path) {
        return 'json'                if $path =~ /\.json$/i;
        return 'properties'          if $path =~ /\.properties$/i;
    }
    return 'json'                if $raw =~ /\A\s*[\{\[]/;
    return 'ini_option_settings' if $raw =~ /OptionSettings\s*=\s*\(/;
    return 'properties' if $raw =~ /^[a-zA-Z][a-zA-Z0-9_\-\.]*\s*=/m;
    return 'unknown';
}

# Parse a Java .properties file (key=value, hyphenated keys, # comments).
# Returns ($vals_href, $order_aref).
sub parse_properties_file {
    my ($raw) = @_;
    my (%vals, @order);
    return (\%vals, \@order) unless defined $raw;
    for my $line (split /\n/, $raw) {
        $line =~ s/\r$//;
        next if $line =~ /^\s*[#!]/;  # comment
        next if $line =~ /^\s*$/;     # blank
        if ($line =~ /^\s*([\w.\-]+)\s*=\s*(.*)$/) {
            my ($k, $v) = ($1, $2);
            $v =~ s/\s+$//;
            push @order, $k unless exists $vals{$k};
            $vals{$k} = $v;
        }
    }
    return (\%vals, \@order);
}

# Update values in a .properties string, preserving comments and structure.
# Only keys already present in $vals_ref are updated; new keys are not added.
sub update_properties_file {
    my ($raw, $vals_ref) = @_;
    my %vals = %{$vals_ref || {}};
    return $raw // '' unless %vals;
    my @out;
    for my $line (split /\n/, ($raw // '')) {
        (my $check = $line) =~ s/\r$//;
        if ($check =~ /^\s*([\w.\-]+)\s*=/ && exists $vals{$1}) {
            push @out, "$1=$vals{$1}";
        } else {
            push @out, $line;
        }
    }
    my $result = join("\n", @out);
    $result .= "\n" unless $result =~ /\n$/;
    return $result;
}

sub _expand_lgsm_vars {
    my ($value, $vars_ref) = @_;
    my $out = defined $value ? $value : '';
    my %vars = %{$vars_ref || {}};
    for (1 .. 10) {
        my $before = $out;
        $out =~ s/\$\{([A-Za-z_]\w*)\}/defined $vars{$1} ? $vars{$1} : ''/ge;
        last if $out eq $before;
    }
    return $out;
}

# Resolve game-server config path.
# Priority order:
#   1. Explicit static path hint (4th arg) — used by SteamCMD/Wine games
#      whose config sits at a known relative location inside serverfiles/.
#      The CGI looks up `get_game_config_path($script)` from games_meta and
#      passes the result here; we resolve relative paths against
#      $script_dir.
#   2. LGSM servercfgfullpath
#   3. LGSM servercfgdir + servercfg
sub resolve_game_server_config_path {
    my ($script_dir, $script_name, $cfg_ref, $static_hint) = @_;
    my %cfg = %{$cfg_ref || {}};

    if (defined $static_hint && length $static_hint) {
        my $abs = ($static_hint =~ m|^/|) ? $static_hint : "$script_dir/$static_hint";
        $abs =~ s|//+|/|g;
        return $abs;
    }

    $cfg{'rootdir'}     ||= $script_dir;
    $cfg{'serverfiles'} ||= "$script_dir/serverfiles";
    $cfg{'lgsmdir'}     ||= "$script_dir/lgsm";

    my $full = _expand_lgsm_vars($cfg{'servercfgfullpath'} // '', \%cfg);
    if ($full eq '') {
        my $dir  = _expand_lgsm_vars($cfg{'servercfgdir'} // '', \%cfg);
        my $file = _expand_lgsm_vars($cfg{'servercfg'} // '', \%cfg);
        if ($dir ne '' && $file ne '') {
            $full = "$dir/$file";
        }
    }
    $full =~ s|//+|/|g;
    return $full;
}

# Write file content exactly as provided (no normalization, no extra newline).
sub write_file_exact {
    my ($path, $content) = @_;
    open(my $fh, '>:raw', $path) or die "Cannot write file: $!";
    print {$fh} (defined $content ? $content : '');
    close($fh) or die "Cannot close file: $!";
    return 1;
}

sub _split_csv_preserving_quotes {
    my ($s) = @_;
    my @parts;
    my $cur = '';
    my $in_quote = 0;
    my $q = '';
    my @chars = split //, ($s // '');
    for my $ch (@chars) {
        if (($ch eq '"' || $ch eq "'")) {
            if (!$in_quote) {
                $in_quote = 1;
                $q = $ch;
            } elsif ($q eq $ch) {
                $in_quote = 0;
            }
            $cur .= $ch;
            next;
        }
        if ($ch eq ',' && !$in_quote) {
            push @parts, $cur;
            $cur = '';
            next;
        }
        $cur .= $ch;
    }
    push @parts, $cur if length($cur) || @parts;
    return @parts;
}

# Parse Palworld-style OptionSettings=(...) line from INI.
# Returns hashref + ordered key list.
sub parse_option_settings_from_ini {
    my ($raw) = @_;
    my (%vals, @order);
    return (\%vals, \@order) unless defined $raw;
    return (\%vals, \@order) unless $raw =~ /OptionSettings\s*=\s*\(([^)]*)\)/s;
    my $inside = $1 // '';
    for my $part (_split_csv_preserving_quotes($inside)) {
        $part =~ s/^\s+|\s+$//g;
        next unless $part =~ /^([A-Za-z_]\w*)\s*=\s*(.*)$/;
        my ($k, $v) = ($1, $2);
        $v =~ s/^\s+|\s+$//g;
        $v =~ s/^"(.*)"$/$1/;
        $v =~ s/^'(.*)'$/$1/;
        push @order, $k unless exists $vals{$k};
        $vals{$k} = $v;
    }
    return (\%vals, \@order);
}

sub _quote_option_value {
    my ($v) = @_;
    $v = '' unless defined $v;
    if ($v =~ /[,\s]/) {
        $v =~ s/"/\\"/g;
        return "\"$v\"";
    }
    return $v;
}

# ---------------------------------------------------------------------------
# JSON game config support (Windrose ServerDescription.json and similar)
#
# Design rationale: like the INI byte-preservation rule (CLAUDE.md §8.6), we
# keep JSON files byte-identical except for the values the user actually
# changed. JSON::PP would re-serialize the entire document and lose key order
# plus formatting, so we read with JSON::PP for the values and write via
# targeted regex substitutions on the original raw string.
#
# Keys are flattened to dot notation, e.g.
#   ServerDescription_Persistent.ServerName
# Arrays are skipped (no game we support edits arrays via the UI).
# ---------------------------------------------------------------------------

sub _flatten_json_node {
    my ($node, $prefix, $vals_ref, $order_ref) = @_;
    if (ref $node eq 'HASH') {
        for my $k (sort keys %$node) {
            my $key = $prefix eq '' ? $k : "$prefix.$k";
            _flatten_json_node($node->{$k}, $key, $vals_ref, $order_ref);
        }
    } elsif (ref $node eq 'ARRAY') {
        return;
    } else {
        my $v = $node;
        if (ref($v) eq 'JSON::PP::Boolean') {
            $v = $v ? 'true' : 'false';
        }
        $v = '' unless defined $v;
        push @$order_ref, $prefix unless exists $vals_ref->{$prefix};
        $vals_ref->{$prefix} = $v;
    }
}

# Parse a JSON game config and return ($vals_href, $order_aref) flattened.
sub parse_json_config {
    my ($raw) = @_;
    my (%vals, @order);
    return (\%vals, \@order) unless defined $raw && length $raw;
    my $obj;
    eval {
        require JSON::PP;
        $obj = JSON::PP::decode_json($raw);
        1;
    } or return (\%vals, \@order);
    _flatten_json_node($obj, '', \%vals, \@order);
    return (\%vals, \@order);
}

# Surgical in-place update of a JSON document.
# - Only keys present in $vals_ref are touched.
# - Whitespace, comments-as-strings, key order, and unknown keys are preserved.
# - Booleans, ints, floats, strings, and JSON null are detected and rewritten
#   with the matching JSON literal.
sub update_json_config {
    my ($raw, $vals_ref) = @_;
    my %vals = %{$vals_ref || {}};
    return $raw // '' unless %vals;
    return $raw // '' unless defined $raw && length $raw;
    for my $dotted (keys %vals) {
        my @parts = split /\./, $dotted;
        my $leaf  = $parts[-1];
        my $val   = $vals{$dotted};
        my $leaf_re = quotemeta($leaf);
        # Iterate matches: type detection per occurrence.
        # We only rewrite the FIRST occurrence of $leaf; if the same leaf name
        # appears in multiple objects, the user must use raw mode.
        if ($raw =~ /"$leaf_re"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            my $escaped = defined $val ? $val : '';
            $escaped =~ s/\\/\\\\/g;
            $escaped =~ s/"/\\"/g;
            $escaped =~ s/\r/\\r/g;
            $escaped =~ s/\n/\\n/g;
            $raw =~ s/"$leaf_re"(\s*:\s*)"(?:[^"\\]|\\.)*"/"$leaf"$1"$escaped"/;
        }
        elsif ($raw =~ /"$leaf_re"\s*:\s*(true|false)\b/) {
            my $b = ($val =~ /^\s*(?:1|true|on|yes|ja)\s*$/i) ? 'true' : 'false';
            $raw =~ s/"$leaf_re"(\s*:\s*)(?:true|false)\b/"$leaf"$1$b/;
        }
        elsif ($raw =~ /"$leaf_re"\s*:\s*null\b/) {
            my $n = (defined $val && length $val) ? $val : 'null';
            $raw =~ s/"$leaf_re"(\s*:\s*)null\b/"$leaf"$1$n/;
        }
        elsif ($raw =~ /"$leaf_re"\s*:\s*-?\d+(?:\.\d+)?/) {
            (my $num = (defined $val ? $val : '')) =~ s/[^0-9.\-]//g;
            $num = '0' if $num eq '' || $num eq '-' || $num eq '.';
            $raw =~ s/"$leaf_re"(\s*:\s*)-?\d+(?:\.\d+)?/"$leaf"$1$num/;
        }
        # else: leaf not found, silently skip (user removed the key in raw mode)
    }
    return $raw;
}

# Update OptionSettings line while preserving surrounding INI content.
sub update_option_settings_in_ini {
    my ($raw, $vals_ref, $order_ref) = @_;
    my %vals = %{$vals_ref || {}};
    my @order = @{$order_ref || []};
    my @pairs;
    for my $k (@order) {
        next unless exists $vals{$k};
        push @pairs, "$k=" . _quote_option_value($vals{$k});
    }
    my $new_line = "OptionSettings=(" . join(',', @pairs) . ")";

    return $raw unless defined $raw;
    if ($raw =~ /^([ \t]*)OptionSettings\s*=\s*\([^)]*\)([ \t]*)(\r?\n?)/m) {
        my ($indent, $trail, $eol) = ($1 // '', $2 // '', $3 // '');
        my $replacement = $indent . $new_line . $trail . $eol;
        $raw =~ s/^[ \t]*OptionSettings\s*=\s*\([^)]*\)[ \t]*(\r?\n?)/$replacement/m;
        return $raw;
    }
    # Fallback: append at end without forcing newline normalization
    my $sep = ($raw =~ /\n\z/) ? '' : "\n";
    return $raw . $sep . $new_line . "\n";
}

1;
