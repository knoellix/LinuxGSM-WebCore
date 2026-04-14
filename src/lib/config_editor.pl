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

# Resolve game-server config path from LGSM variables.
# Prefers servercfgfullpath, then servercfgdir + servercfg.
sub resolve_game_server_config_path {
    my ($script_dir, $script_name, $cfg_ref) = @_;
    my %cfg = %{$cfg_ref || {}};
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
