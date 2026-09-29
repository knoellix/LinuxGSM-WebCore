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
# Never allows _default.cfg. Canonicalizes via realpath when possible.
# Calls error() on failure; returns resolved path on success.
sub validate_config_target {
    my ($path) = @_;
    our %text;

    # Must be an absolute path
    &error($text{'err_invalid_input'}) unless defined $path && $path =~ m|^/|;
    &error($text{'err_invalid_input'}) if $path =~ /\.\./;

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

    my $resolved = _config_editor_realpath($path);
    &error($text{'err_invalid_input'}) unless defined $resolved && $resolved ne '';
    if ($resolved =~ /_default\.cfg\z/) {
        &error($text{'err_invalid_input'});
    }
    unless ($resolved =~ m|/lgsm/config-lgsm/|) {
        &error($text{'err_invalid_input'});
    }
    unless (
        $resolved =~ m|^/[a-zA-Z0-9_./()\- ]+/lgsm/config-lgsm/common\.cfg$| ||
        $resolved =~ m|^/[a-zA-Z0-9_./()\- ]+/lgsm/config-lgsm/[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+\.cfg$|
    ) {
        &error($text{'err_invalid_input'});
    }

    return $resolved;
}

# Resolve path; walk missing parents so Quick Fix can create
# …/lgsm/config-lgsm/<script>/<script>.cfg before the <script>/ dir exists.
# Returns undef only when no ancestor can be realpath'd.
sub _config_editor_realpath {
    my ($path) = @_;
    return undef unless defined $path && $path ne '';
    require Cwd;
    my $resolved = Cwd::realpath($path);
    return $resolved if defined $resolved && $resolved ne '';

    my @missing;
    my $cur = $path;
    while (1) {
        (my $parent = $cur) =~ s|/[^/]+$||;
        last if !defined $parent || $parent eq '' || $parent eq $cur;
        my $leaf = $cur;
        $leaf =~ s|.*/||;
        unshift @missing, $leaf;
        my $base = Cwd::realpath($parent);
        if (defined $base && $base ne '') {
            return join('/', $base, @missing);
        }
        $cur = $parent;
    }
    return undef;
}

# Soft check for game-server config paths (no &error — safe during GET render).
# Returns resolved path or undef when the path is missing/unsafe/outside the tree.
# Webmin &error() exits the process; eval cannot catch it, so manage.cgi must
# use this for page display and only call validate_game_config_path on POST.
#
# Optional 3rd arg $home: also allow paths under the game user's home when they
# match a safe relative pattern (used for Project Zomboid $HOME/Zomboid/Server/*.ini).
sub check_game_config_path {
    my ($script_dir, $path, $home) = @_;
    return undef unless defined $path && $path =~ m|^/|;
    return undef if $path =~ /\.\./;
    return undef unless defined $script_dir && $script_dir =~ m|^/|;

    require Cwd;
    my $base = Cwd::realpath($script_dir) // $script_dir;
    $base =~ s{/\z}{};
    my $resolved = _config_editor_realpath($path);
    return undef unless defined $resolved && $resolved ne '';
    return $resolved if $resolved eq $base || index($resolved, "$base/") == 0;

    if (defined $home && $home =~ m|^/| && $home !~ /\.\./) {
        my $hbase = Cwd::realpath($home) // $home;
        $hbase =~ s{/\z}{};
        if ($hbase ne ''
            && ($resolved eq $hbase || index($resolved, "$hbase/") == 0)
            && $resolved =~ m{\Q$hbase\E/Zomboid/Server/[a-zA-Z0-9_-]+(?:\.ini|_SandboxVars\.lua)\z}) {
            return $resolved;
        }
    }
    return undef;
}

# Game-server config must stay under $script_dir (or optional $home for PZ).
# Fatal for POST/save paths — use check_game_config_path during GET render.
sub validate_game_config_path {
    my ($script_dir, $path, $home) = @_;
    our %text;
    my $resolved = check_game_config_path($script_dir, $path, $home);
    &error($text{'err_invalid_input'}) unless defined $resolved && $resolved ne '';
    return $resolved;
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

# Strip UTF-8 BOM and decode UTF-16 LE exports (rare, breaks OptionSettings regex).
sub _normalize_game_config_text {
    my ($raw) = @_;
    return '' unless defined $raw;
    $raw =~ s/^\x{FEFF}//;
    if (length($raw) >= 2 && substr($raw, 0, 2) eq "\xFF\xFE") {
        eval {
            require Encode;
            $raw = Encode::decode('UTF-16LE', substr($raw, 2));
        };
    }
    $raw =~ s/\r\n/\n/g;
    $raw =~ s/\r/\n/g;
    return $raw;
}

# Read game-server config as normalized UTF-8 text.
sub read_game_config_raw {
    my ($path) = @_;
    return '' unless defined $path && $path ne '' && -f $path;
    open(my $fh, '<:raw', $path) or return '';
    local $/;
    my $raw = <$fh>;
    close($fh);
    return _normalize_game_config_text($raw);
}

# Unified format pick:
#   1. OptionSettings=(...) content → Palworld-style (wins over wrong meta)
#   2. games_meta game_config_format (e.g. PZ .ini = properties)
#   3. Path / content heuristics
# Never treat every *.ini as OptionSettings — Project Zomboid uses key=value INI.
sub resolve_game_config_format {
    my ($script_name, $path, $raw) = @_;
    $raw = _normalize_game_config_text($raw // '');
    return 'ini_option_settings' if $raw =~ /OptionSettings\s*=\s*\(/;
    if (defined &get_game_config_format) {
        my $meta_fmt = &get_game_config_format($script_name);
        return $meta_fmt if defined $meta_fmt && $meta_fmt ne '';
    }
    if (defined $path && $path ne '') {
        return 'json'       if $path =~ /\.json$/i;
        return 'properties' if $path =~ /\.properties$/i;
        # Bare .ini without OptionSettings: prefer properties (PZ) over Palworld.
        # Palworld files always contain OptionSettings=( and are caught above.
        return 'properties' if $path =~ /\.ini$/i && $raw =~ /\S/
            && $raw !~ /OptionSettings\s*=\s*\(/;
        return 'ini_option_settings' if $path =~ /\.ini$/i;
    }
    return &detect_game_config_format($path, $raw);
}

# Parse game config into ($vals_href, $order_aref) using resolved format + fallbacks.
sub parse_game_config_values {
    my ($script_name, $path, $raw) = @_;
    $raw = _normalize_game_config_text($raw // '');
    my $fmt = resolve_game_config_format($script_name, $path, $raw);
    my ($vals, $order);
    if ($fmt eq 'json') {
        ($vals, $order) = parse_json_config($raw);
    }
    elsif ($fmt eq 'properties') {
        ($vals, $order) = parse_properties_file($raw);
        # Palworld .ini mis-tagged as properties: one OptionSettings= line only.
        if ($raw =~ /OptionSettings\s*=\s*\(/ && (!%$vals || (keys %$vals == 1 && exists $vals->{OptionSettings}))) {
            ($vals, $order) = parse_option_settings_from_ini($raw);
        }
    }
    else {
        ($vals, $order) = parse_option_settings_from_ini($raw);
    }
    return ($vals, $order, $fmt);
}

# Returns 'json' (Windrose & co.), 'ini_option_settings' (Palworld),
# 'properties', or 'unknown'.
sub detect_game_config_format {
    my ($path, $raw) = @_;
    # Path-driven shortcuts beat content heuristics so empty/templated files
    # still resolve to a sensible parser.
    if (defined $path) {
        return 'json'                if $path =~ /\.json$/i;
        return 'properties'          if $path =~ /\.properties$/i;
        return 'ini_option_settings' if $path =~ /\.ini$/i;
    }
    return 'unknown' unless defined $raw && length $raw;
    # Palworld / Unreal INI uses [Section] headers — not JSON arrays.
    return 'ini_option_settings' if $raw =~ /OptionSettings\s*=\s*\(/;
    return 'json'                if $raw =~ /\A\s*\{/;
    return 'json'                if $raw =~ /\A\s*\[\s*(?:\{|[\[\]\"]|true|false|null|-?\d)/;
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
#   1. Explicit static path hint (4th arg) — relative to $script_dir, or to
#      $opts{home} when games_meta game_config_path_base is "home" (PZ).
#   2. LGSM servercfgfullpath
#   3. LGSM servercfgdir + servercfg
#
# Optional 5th arg \%opts: home => unix home; selfname => LGSM script basename.
sub resolve_game_server_config_path {
    my ($script_dir, $script_name, $cfg_ref, $static_hint, $opts) = @_;
    my %cfg = %{$cfg_ref || {}};
    my %o = %{$opts || {}};
    my $home = $o{'home'} // '';
    $home =~ s{/\z}{} if $home ne '';

    if (defined $static_hint && length $static_hint) {
        return '' if $static_hint =~ /\.\./;

        my $base_home = ($home ne '' && $home =~ m|^/|
            && defined &get_game_config_path_base
            && &get_game_config_path_base($script_name) eq 'home');

        if ($static_hint !~ m|^/| && $base_home) {
            my $abs = "$home/$static_hint";
            $abs =~ s|//+|/|g;
            require Cwd;
            my $hbase = Cwd::realpath($home) // $home;
            $hbase =~ s{/\z}{};
            my $resolved = _config_editor_realpath($abs) // $abs;
            return '' unless $hbase ne ''
                && ($resolved eq $hbase || index($resolved, "$hbase/") == 0);
            return $resolved;
        }

        my $abs = ($static_hint =~ m|^/|) ? $static_hint : "$script_dir/$static_hint";
        $abs =~ s|//+|/|g;
        return $abs if $static_hint !~ m|^/|;
        return '' unless defined $script_dir && $script_dir =~ m|^/|;
        require Cwd;
        my $base = Cwd::realpath($script_dir) // $script_dir;
        $base =~ s{/\z}{};
        my $resolved = _config_editor_realpath($abs);
        return '' unless defined $resolved && $resolved ne '';
        return $resolved if $resolved eq $base || index($resolved, "$base/") == 0;
        if ($home ne '') {
            my $hbase = Cwd::realpath($home) // $home;
            $hbase =~ s{/\z}{};
            return $resolved if $hbase ne ''
                && ($resolved eq $hbase || index($resolved, "$hbase/") == 0);
        }
        return '';
    }

    $cfg{'rootdir'}     ||= $script_dir;
    $cfg{'serverfiles'} ||= "$script_dir/serverfiles";
    $cfg{'lgsmdir'}     ||= "$script_dir/lgsm";
    $cfg{'selfname'}    ||= ($o{'selfname'} // $script_name // '');
    if ($home ne '' && !defined $cfg{'HOME'}) {
        $cfg{'HOME'} = $home;
    }

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
# Used by tests; manage.cgi uses binmode(:raw) on the su pipe for the same fidelity.
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

# Extract inner text of OptionSettings=(...) using balanced-parenthesis scan.
sub _option_settings_inner {
    my ($raw) = @_;
    return '' unless defined $raw && $raw =~ /OptionSettings\s*=\s*\(/;
    my ($prefix) = $raw =~ /\A(.*?)OptionSettings\s*=\s*\(/s;
    $prefix = '' unless defined $prefix;
    my $pos = length($prefix) + (index(substr($raw, length($prefix)), '(') // -1);
    return '' if $pos < 0;
    $pos++;    # first char inside parens
    my $depth   = 1;
    my $in_quote = 0;
    my $quote_ch = '';
    my $len     = length($raw);
    my $start   = $pos;
    while ($pos < $len) {
        my $ch = substr($raw, $pos, 1);
        if ($in_quote) {
            if ($ch eq '\\' && $pos + 1 < $len) {
                $pos += 2;
                next;
            }
            $in_quote = 0 if $ch eq $quote_ch;
        }
        elsif ($ch eq '"' || $ch eq "'") {
            $in_quote = 1;
            $quote_ch = $ch;
        }
        elsif ($ch eq '(') {
            $depth++;
        }
        elsif ($ch eq ')') {
            $depth--;
            if ($depth == 0) {
                return substr($raw, $start, $pos - $start);
            }
        }
        $pos++;
    }
    # Truncated or malformed file: parse best-effort up to EOF (common on long Palworld lines).
    if ($depth > 0 && $pos > $start) {
        return substr($raw, $start);
    }
    return '';
}

# Parse Palworld-style OptionSettings=(...) line from INI.
# Returns hashref + ordered key list.
sub parse_option_settings_from_ini {
    my ($raw) = @_;
    my (%vals, @order);
    return (\%vals, \@order) unless defined $raw;
    my $inside = _option_settings_inner($raw);
    return (\%vals, \@order) unless length $inside;
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
# Design rationale: like the INI byte-preservation rule (.cursor/rules/lgsm-games-config.mdc), we
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
    if ($raw =~ /^([ \t]*)OptionSettings\s*=\s*\(/m) {
        my $indent = $1 // '';
        my $line_start = $-[0];
        my $inner = _option_settings_inner(substr($raw, $line_start));
        if (length $inner) {
            my $rest = substr($raw, $line_start);
            my $close_pos = index($rest, '(') + 1 + length($inner) + 1;
            my $suffix = substr($rest, $close_pos);
            my $replacement = $indent . $new_line . $suffix;
            return substr($raw, 0, $line_start) . $replacement;
        }
    }
    # Fallback: append at end without forcing newline normalization
    my $sep = ($raw =~ /\n\z/) ? '' : "\n";
    return $raw . $sep . $new_line . "\n";
}

# Palworld: after first world save, WorldOption.sav may override PalWorldSettings.ini.
# Returns first matching path under serverfiles/Pal/Saved/SaveGames, or ''.
sub find_palworld_world_option_sav {
    my ($script_dir) = @_;
    return '' unless defined $script_dir && $script_dir ne '';
    my $base = "$script_dir/serverfiles/Pal/Saved/SaveGames";
    return '' unless -d $base;
    opendir(my $dh, $base) or return '';
    my $found = '';
    while (my $e = readdir($dh)) {
        next if $e eq '.' || $e eq '..';
        for my $path (glob("$base/$e/*/WorldOption.sav")) {
            if (-f $path) {
                $found = $path;
                last;
            }
        }
        last if $found ne '';
    }
    closedir($dh);
    return $found;
}

# --- Project Zomboid SandboxVars.lua (nested Lua table) -----------------

# Parse SandboxVars = { ... } into flat dotted keys.
# Returns ($vals_href, $order_aref) where order is depth-first leaf paths.
sub parse_sandboxvars_lua {
    my ($raw) = @_;
    my (%vals, @order);
    $raw = heal_sandboxvars_lua_text(_normalize_game_config_text($raw // ''));
    return (\%vals, \@order) unless $raw =~ /SandboxVars\s*=\s*/;
    my $after = $+[0];
    my $eq = index($raw, '{', $after > 0 ? $after - 1 : 0);
    my $body = _sandboxvars_extract_table($raw, $eq);
    return (\%vals, \@order) unless defined $body && $body ne '';

    my $tree = _sandboxvars_parse_table($body);
    return (\%vals, \@order) unless ref($tree) eq 'HASH';
    _sandboxvars_flatten($tree, '', \%vals, \@order);
    return (\%vals, \@order);
}

# Apply flat dotted updates onto SandboxVars.lua text; re-serialize table.
sub update_sandboxvars_lua {
    my ($raw, $updates) = @_;
    $raw = heal_sandboxvars_lua_text(_normalize_game_config_text($raw // ''));
    my ($vals, $order) = parse_sandboxvars_lua($raw);
    return $raw unless ref($updates) eq 'HASH' && %$updates;

    for my $k (keys %$updates) {
        next unless defined $k && $k =~ /\S/;
        my $v = $updates->{$k};
        $v = '' unless defined $v;
        $v = normalize_config_form_value($v);
        if (!exists $vals->{$k}) {
            push @$order, $k;
        }
        $vals->{$k} = $v;
    }

    my $tree = _sandboxvars_unflatten($vals, $order);
    my $table = _sandboxvars_serialize_table($tree, $order, 1);
    if ($raw =~ /SandboxVars\s*=/s) {
        $raw =~ s/SandboxVars\s*=\s*\{.*\}\s*\z/SandboxVars = $table\n/s;
        return $raw;
    }
    return "SandboxVars = $table\n";
}

# Rewrite false\0true / "false true" artifacts left by Webmin checkbox multi-values.
sub heal_sandboxvars_lua_text {
    my ($raw) = @_;
    return '' unless defined $raw;
    # Walk and replace bool artifacts; keep logic out of s///e to avoid qr/$sep/ pitfalls.
    my $out = '';
    my $len = length($raw);
    my $i = 0;
    while ($i < $len) {
        my $ch = substr($raw, $i, 1);
        # Quoted string: maybe "false\0true"
        if ($ch eq '"') {
            my $j = $i + 1;
            my $inner = '';
            while ($j < $len) {
                my $c = substr($raw, $j, 1);
                if ($c eq '\\' && $j + 1 < $len) {
                    $inner .= substr($raw, $j, 2);
                    $j += 2;
                    next;
                }
                last if $c eq '"';
                $inner .= $c;
                $j++;
            }
            if ($j < $len && substr($raw, $j, 1) eq '"') {
                my $norm = normalize_config_form_value($inner);
                if ($norm =~ /^(?:true|false)$/i
                    && $inner =~ /(?:true|false)/i
                    && $inner =~ /[\0\s\x{EF}\x{BF}\x{BD}]/) {
                    $out .= $norm;    # bare true/false, drop quotes
                } else {
                    $out .= substr($raw, $i, $j - $i + 1);
                }
                $i = $j + 1;
                next;
            }
        }
        # Bare false\0true / true false
        if (($ch eq 't' || $ch eq 'T' || $ch eq 'f' || $ch eq 'F')
            && substr($raw, $i) =~ /^((?:true|false)(?:(?:\0|\s+|\xEF\xBF\xBD)+(?:true|false))+)\b/i) {
            my $tok = $1;
            $out .= normalize_config_form_value($tok);
            $i += length($tok);
            next;
        }
        $out .= $ch;
        $i++;
    }
    return $out;
}

sub _sandboxvars_extract_table {
    my ($raw, $open_pos) = @_;
    return '' if !defined $open_pos || $open_pos < 0;
    my $depth = 0;
    my $in_str = 0;
    my $q = '';
    my $len = length($raw);
    for (my $i = $open_pos; $i < $len; $i++) {
        my $ch = substr($raw, $i, 1);
        if ($in_str) {
            if ($ch eq '\\' && $i + 1 < $len) { $i++; next; }
            if ($ch eq $q) { $in_str = 0; }
            next;
        }
        # Skip Lua line comments — must run before quote detection so
        # apostrophes in comments (hasn't, player's) do not break brace depth.
        if ($ch eq '-' && $i + 1 < $len && substr($raw, $i + 1, 1) eq '-') {
            my $nl = index($raw, "\n", $i);
            $i = ($nl < 0) ? $len : $nl;
            next;
        }
        if ($ch eq '"' || $ch eq "'") { $in_str = 1; $q = $ch; next; }
        if ($ch eq '{') { $depth++; next; }
        if ($ch eq '}') {
            $depth--;
            if ($depth == 0) {
                return substr($raw, $open_pos, $i - $open_pos + 1);
            }
        }
    }
    return '';
}

# Parse a Lua table string "{ ... }" into a nested Perl hash.
# Leaf values are strings (numbers/bools kept as their Lua text form).
sub _sandboxvars_parse_table {
    my ($table) = @_;
    return {} unless defined $table && $table =~ /^\s*\{/;

    my $inner = $table;
    $inner =~ s/^\s*\{//;
    $inner =~ s/\}\s*\z//;

    my %out;
    my $pos = 0;
    my $len = length($inner);
    while ($pos < $len) {
        # skip whitespace, commas, comments
        while ($pos < $len) {
            my $ch = substr($inner, $pos, 1);
            if ($ch =~ /\s/ || $ch eq ',') { $pos++; next; }
            if ($ch eq '-' && substr($inner, $pos, 2) eq '--') {
                my $nl = index($inner, "\n", $pos);
                $pos = ($nl < 0) ? $len : $nl + 1;
                next;
            }
            last;
        }
        last if $pos >= $len;

        pos($inner) = $pos;
        unless ($inner =~ /\G([A-Za-z_][A-Za-z0-9_]*)\s*=\s*/gc) {
            last;
        }
        my $key = $1;
        $pos = pos($inner);

        my $ch = substr($inner, $pos, 1);
        if ($ch eq '{') {
            my $sub = _sandboxvars_extract_table($inner, $pos);
            last if $sub eq '';
            $out{$key} = _sandboxvars_parse_table($sub);
            $pos += length($sub);
        } elsif ($ch eq '"' || $ch eq "'") {
            my $q = $ch;
            $pos++;
            my $val = '';
            while ($pos < $len) {
                my $c = substr($inner, $pos, 1);
                if ($c eq '\\' && $pos + 1 < $len) {
                    $val .= substr($inner, $pos, 2);
                    $pos += 2;
                    next;
                }
                if ($c eq $q) { $pos++; last; }
                $val .= $c;
                $pos++;
            }
            $out{$key} = $val;
        } else {
            # bare token: number, true, false
            if ($inner =~ /\G(-?\d+(?:\.\d+)?|true|false)\b/gc) {
                $out{$key} = $1;
                $pos = pos($inner);
            } else {
                last;
            }
        }
    }
    return \%out;
}

sub _sandboxvars_flatten {
    my ($node, $prefix, $vals, $order) = @_;
    return unless ref($node) eq 'HASH';
    for my $k (sort keys %$node) {
        my $path = $prefix eq '' ? $k : "$prefix.$k";
        my $v = $node->{$k};
        if (ref($v) eq 'HASH') {
            _sandboxvars_flatten($v, $path, $vals, $order);
        } else {
            push @$order, $path unless exists $vals->{$path};
            my $leaf = defined $v ? "$v" : '';
            $leaf = normalize_config_form_value($leaf);
            $vals->{$path} = $leaf;
        }
    }
}

sub _sandboxvars_unflatten {
    my ($vals, $order) = @_;
    my %tree;
    my @keys = @$order;
    # Also include any update-only keys
    for my $k (keys %$vals) {
        push @keys, $k unless grep { $_ eq $k } @keys;
    }
    for my $path (@keys) {
        next unless exists $vals->{$path};
        my @parts = split /\./, $path;
        my $cur = \%tree;
        while (@parts > 1) {
            my $p = shift @parts;
            $cur->{$p} = {} unless ref($cur->{$p}) eq 'HASH';
            $cur = $cur->{$p};
        }
        $cur->{ $parts[0] } = $vals->{$path};
    }
    return \%tree;
}

# Serialize nested hash to Lua table text. $order guides leaf order when possible.
sub _sandboxvars_serialize_table {
    my ($tree, $order, $indent_level) = @_;
    $indent_level //= 1;
    my $pad = '    ' x $indent_level;
    my $pad0 = '    ' x ($indent_level - 1);

    # Group order into top-level keys sequence
    my (@top_order, %seen_top);
    for my $path (@{ $order || [] }) {
        my ($top) = split /\./, $path, 2;
        next unless defined $top && $top ne '';
        push @top_order, $top unless $seen_top{$top}++;
    }
    for my $k (sort keys %$tree) {
        push @top_order, $k unless $seen_top{$k}++;
    }

    my @lines = ('{');
    for my $k (@top_order) {
        next unless exists $tree->{$k};
        my $v = $tree->{$k};
        if (ref($v) eq 'HASH') {
            # nested order: paths under this key
            my @sub_order = map {
                /^\Q$k\E\.(.+)$/ ? $1 : ()
            } @{ $order || [] };
            my $inner = _sandboxvars_serialize_table($v, \@sub_order, $indent_level + 1);
            $inner =~ s/\A\{\s*\n?//;
            $inner =~ s/\n?[ \t]*\}\s*\z//;
            push @lines, "$pad$k = {";
            push @lines, $inner if $inner =~ /\S/;
            push @lines, "$pad},";
        } else {
            push @lines, "$pad$k = " . _sandboxvars_format_value($v) . ',';
        }
    }
    push @lines, "$pad0}";
    return join("\n", @lines);
}

sub _sandboxvars_format_value {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v = normalize_config_form_value($v);
    return $v if $v =~ /^(?:true|false)$/i;
    return $v if $v =~ /^-?\d+(?:\.\d+)?$/;
    $v =~ s/\\/\\\\/g;
    $v =~ s/"/\\"/g;
    return "\"$v\"";
}

# Webmin joins duplicate form names with \0 (hidden false + checkbox true).
# Also heals already-saved "false true" / "true false" artifacts.
sub normalize_config_form_value {
    my ($v) = @_;
    return '' unless defined $v;
    # Treat UTF-8 replacement (U+FFFD) like NUL/space separators
    $v =~ s/\xEF\xBF\xBD/\0/g;
    # NUL-separated multi-value from ReadParse
    if (index($v, "\0") >= 0) {
        my @parts = grep { $_ ne '' } split /\0/, $v;
        if (@parts && (grep { /^(?:true|false)$/i } @parts) == @parts) {
            return lc($parts[-1]);
        }
        $v = $parts[-1] if @parts;
    }
    # Space-joined bool artifact already written to disk / odd parsers
    if ($v =~ /^(?:true|false)(?:\s+(?:true|false))+$/i) {
        my @parts = split /\s+/, $v;
        return lc($parts[-1]);
    }
    # Quoted variant from a previous bad serialize
    if ($v =~ /^"(?:true|false)(?:\s+(?:true|false))+"$/i) {
        $v =~ s/^"|"$//g;
        my @parts = split /\s+/, $v;
        return lc($parts[-1]);
    }
    return $v;
}

*normalize_game_config_text = \&_normalize_game_config_text;

1;
