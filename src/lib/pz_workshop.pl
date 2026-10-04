# LinuxGSM-WebCore — Project Zomboid Steam Workshop helpers
use strict;
use warnings;
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);

our (%config, $module_root, $module_root_directory);

sub steam_web_api_key {
    our %config;
    my $key = $config{'steam_web_api_key'} // '';
    $key =~ s/[\t\n\r]//g;
    $key =~ s/^\s+|\s+$//g;
    $key =~ s/^["']+|["']+$//g;
    return $key;
}

# games_meta: mod_support eq 'workshop'
sub game_has_workshop_support {
    my ($script_name) = @_;
    return 0 unless defined $script_name && $script_name =~ /\S/;
    return 0 unless defined &get_game_mod_support;
    my $ms = &get_game_mod_support($script_name);
    return ($ms // '') eq 'workshop' ? 1 : 0;
}

sub get_workshop_appid {
    my ($script_name) = @_;
    return 0 unless defined &load_games_meta;
    my %meta = &load_games_meta();
    my $key = defined &_resolve_meta_key ? &_resolve_meta_key($script_name) : $script_name;
    my $entry = $meta{$key} or return 0;
    my $id = $entry->{'workshop_appid'} // 0;
    return ($id =~ /^\d+$/ && $id > 0) ? int($id) : 0;
}

sub get_workshop_ini_rel {
    my ($script_name) = @_;
    return '' unless defined &load_games_meta;
    my %meta = &load_games_meta();
    my $key = defined &_resolve_meta_key ? &_resolve_meta_key($script_name) : $script_name;
    my $entry = $meta{$key} or return '';
    my $p = $entry->{'workshop_ini_rel'} // '';
    $p =~ s/^\s+|\s+$//g;
    return '' if $p eq '' || $p =~ m{(?:^|/)\.\.(?:/|$)};
    return '' if $p =~ m{^/};
    return $p;
}

sub pz_workshop_unix_home {
    my ($unix_user) = @_;
    return undef unless defined $unix_user && $unix_user =~ /\S/;
    my @pw = getpwnam($unix_user);
    return undef unless @pw;
    my $home = $pw[7] // '';
    return undef unless $home =~ m{^/} && -d $home;
    require Cwd;
    return Cwd::realpath($home) // $home;
}

# Resolve server INI under the game user's home. Returns (ok, path, err).
sub pz_workshop_resolve_ini_path {
    my ($unix_user, $script_name) = @_;
    my $home = pz_workshop_unix_home($unix_user);
    return (0, undef, 'no_home') unless defined $home;
    my $rel = get_workshop_ini_rel($script_name);
    $rel = 'Zomboid/Server/servertest.ini' unless $rel =~ /\S/;
    my $path = "$home/$rel";
    require Cwd;
    my $resolved = _pz_workshop_realpath_allow_missing($path);
    return (0, undef, 'bad_path') unless defined $resolved;
    my $base = Cwd::realpath($home) // $home;
    $base =~ s{/\z}{};
    unless ($resolved eq $base || index($resolved, "$base/") == 0) {
        return (0, undef, 'outside_home');
    }
    return (1, $resolved, undef);
}

sub _pz_workshop_realpath_allow_missing {
    my ($path) = @_;
    return undef unless defined $path && $path =~ m{^/};
    require Cwd;
    my $r = Cwd::realpath($path);
    return $r if defined $r && $r ne '';
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

# Split WorkshopItems / Mods semicolon lists (PZ convention).
sub pz_workshop_split_list {
    my ($raw) = @_;
    $raw //= '';
    $raw =~ s/^\s+|\s+$//g;
    return () unless length $raw;
    my @out;
    my %seen;
    for my $p (split /;/, $raw) {
        $p =~ s/^\s+|\s+$//g;
        next unless length $p;
        next if $seen{$p}++;
        push @out, $p;
    }
    return @out;
}

sub pz_workshop_join_list {
    my (@items) = @_;
    my @out;
    my %seen;
    for my $p (@items) {
        next unless defined $p;
        $p =~ s/^\s+|\s+$//g;
        next unless length $p;
        next if $seen{$p}++;
        push @out, $p;
    }
    return join(';', @out);
}

# Read key=value lines from a PZ server .ini (loose; keeps other lines intact on write).
sub pz_workshop_read_ini {
    my ($path) = @_;
    my %vals;
    my @order;
    my $raw = '';
    return (\%vals, \@order, $raw) unless defined $path && -f $path;
    open(my $fh, '<', $path) or return (\%vals, \@order, $raw);
    local $/;
    $raw = <$fh> // '';
    close($fh);
    $raw =~ s/\r\n/\n/g;
    $raw =~ s/\r/\n/g;
    for my $line (split /\n/, $raw) {
        next if $line =~ /^\s*(?:#|;)/;
        if ($line =~ /^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$/) {
            my ($k, $v) = ($1, $2);
            push @order, $k unless exists $vals{$k};
            $vals{$k} = $v;
        }
    }
    return (\%vals, \@order, $raw);
}

# Patch WorkshopItems and/or Mods; preserves other content.
# $ops: { add_workshop => [...], remove_workshop => [...],
#         add_mods => [...], remove_mods => [...] }
# Returns (ok, err).
sub pz_workshop_patch_ini {
    my ($path, $ops) = @_;
    return (0, 'bad_path') unless defined $path && $path =~ m{^/};
    return (0, 'bad_ops') unless ref($ops) eq 'HASH';

    my ($vals, undef, $raw) = pz_workshop_read_ini($path);
    my @wi = pz_workshop_split_list($vals->{'WorkshopItems'} // '');
    my @mods = pz_workshop_split_list($vals->{'Mods'} // '');

    my %wi_set = map { $_ => 1 } @wi;
    my %mod_set = map { $_ => 1 } @mods;

    for my $id (@{ $ops->{'add_workshop'} // [] }) {
        $id =~ s/[^0-9]//g;
        next unless length $id;
        push @wi, $id unless $wi_set{$id}++;
    }
    for my $id (@{ $ops->{'remove_workshop'} // [] }) {
        $id =~ s/[^0-9]//g;
        next unless length $id;
        @wi = grep { $_ ne $id } @wi;
        delete $wi_set{$id};
    }
    for my $mid (@{ $ops->{'add_mods'} // [] }) {
        next unless defined $mid && $mid =~ /\S/;
        $mid =~ s/[;\r\n]//g;
        $mid =~ s/^\s+|\s+$//g;
        next unless length $mid;
        push @mods, $mid unless $mod_set{$mid}++;
    }
    for my $mid (@{ $ops->{'remove_mods'} // [] }) {
        next unless defined $mid && $mid =~ /\S/;
        $mid =~ s/[;\r\n]//g;
        @mods = grep { $_ ne $mid } @mods;
        delete $mod_set{$mid};
    }

    my $new_wi = pz_workshop_join_list(@wi);
    my $new_mods = pz_workshop_join_list(@mods);

    if ($raw eq '' && !-f $path) {
        my $dir = dirname($path);
        make_path($dir) unless -d $dir;
        $raw = "WorkshopItems=$new_wi\nMods=$new_mods\n";
    } else {
        $raw = _pz_workshop_set_ini_key($raw, 'WorkshopItems', $new_wi);
        $raw = _pz_workshop_set_ini_key($raw, 'Mods', $new_mods);
    }

    open(my $fh, '>', $path) or return (0, 'write_failed');
    print $fh $raw;
    close($fh);
    return (1, undef);
}

sub _pz_workshop_set_ini_key {
    my ($raw, $key, $value) = @_;
    $raw //= '';
    my $replaced = 0;
    my @out;
    for my $line (split /\n/, $raw, -1) {
        if ($line =~ /^\s*\Q$key\E\s*=/) {
            push @out, "$key=$value";
            $replaced = 1;
        } else {
            push @out, $line;
        }
    }
    unless ($replaced) {
        # Drop trailing empty line noise then append.
        while (@out && $out[-1] eq '') { pop @out; }
        push @out, "$key=$value", '';
    }
    return join("\n", @out);
}

sub pz_workshop_parse_mod_info {
    my ($item_dir) = @_;
    return () unless defined $item_dir && -d $item_dir;
    my @out;
    require File::Find;
    File::Find::find({
        wanted => sub {
            return unless -f $_ && lc(basename($_)) eq 'mod.info';
            open(my $fh, '<', $_) or return;
            my %f;
            while (my $line = <$fh>) {
                chomp $line; $line =~ s/\r//g;
                next unless $line =~ /^\s*([A-Za-z0-9_-]+)\s*=\s*(.*?)\s*$/;
                my ($k, $v) = (lc($1), $2);
                $f{$k} = $v;
            }
            close $fh;
            my $id = $f{id} // '';
            $id =~ s/[;\r\n]//g;
            return unless length $id;
            # Keep every mod.info (same id may appear in versioned subdirs, e.g.
            # AluminumBat root + AluminumBat/42.13/). Collapse later with server ver.
            my $req = $f{require} // $f{pzversion} // $f{'pz-version'} // '';
            push @out, {
                id         => $id,
                name       => $f{name} // '',
                modversion => $f{modversion} // $f{version} // '',
                pz_require => $req,
                authors    => $f{authors} // $f{author} // '',
            };
        },
        no_chdir => 1,
    }, $item_dir);
    return @out;
}

# Pick one mod.info per Mod-ID. Prefer require matching $server_ver; else empty
# require over a known-mismatched pin; else first versioned entry.
sub pz_workshop_pick_mod_info_variant {
    my ($variants, $server_ver) = @_;
    return undef unless ref($variants) eq 'ARRAY' && @$variants;
    return $variants->[0] if @$variants == 1;
    my $srv = pz_workshop_normalize_version($server_ver);
    my (@matching, @empty, @other);
    for my $mi (@$variants) {
        next unless ref($mi) eq 'HASH';
        my $req = pz_workshop_effective_pz_require($mi);
        if (length $srv && length $req && pz_workshop_version_matches($req, $srv)) {
            push @matching, $mi;
        }
        elsif ($req eq '') {
            push @empty, $mi;
        }
        else {
            push @other, $mi;
        }
    }
    return $matching[0] if @matching;
    return $empty[0] if @empty && length $srv;
    return $other[0] if @other;
    return $empty[0] if @empty;
    return $variants->[0];
}

# Collapse duplicate Mod-IDs from versioned mod.info trees for a server version.
sub pz_workshop_collapse_mod_infos {
    my ($infos, $server_ver) = @_;
    return () unless ref($infos) eq 'ARRAY';
    my %groups;
    my @order;
    for my $mi (@$infos) {
        next unless ref($mi) eq 'HASH';
        my $id = $mi->{'id'} // '';
        $id =~ s/[;\r\n]//g;
        next unless length $id;
        push @order, $id unless exists $groups{$id};
        push @{ $groups{$id} }, $mi;
    }
    my @out;
    for my $id (@order) {
        my $pick = pz_workshop_pick_mod_info_variant($groups{$id}, $server_ver);
        push @out, $pick if ref($pick) eq 'HASH';
    }
    return @out;
}

# Parse mod.info files under a workshop item directory. Returns list of mod ids.
sub pz_workshop_parse_mod_ids {
    my ($item_dir) = @_;
    return map { $_->{id} } pz_workshop_parse_mod_info($item_dir);
}

sub pz_workshop_content_roots {
    my ($unix_user, $server_dir, $appid) = @_;
    $appid = int($appid || 0);
    return () unless $appid > 0;
    my $home = pz_workshop_unix_home($unix_user) // '';
    my @cands;
    push @cands, "$home/Steam/steamapps/workshop/content/$appid" if $home ne '';
    push @cands, "$home/.steam/steam/steamapps/workshop/content/$appid" if $home ne '';
    push @cands, "$home/steamapps/workshop/content/$appid" if $home ne '';
    if (defined $server_dir && $server_dir ne '') {
        push @cands, "$server_dir/steamapps/workshop/content/$appid";
        push @cands, "$server_dir/serverfiles/steamapps/workshop/content/$appid";
    }
    my @out; my %seen;
    for my $r (@cands) {
        next unless -d $r;
        my $rp = _pz_workshop_realpath_allow_missing($r) // $r;
        next if $seen{$rp}++;
        push @out, $rp;
    }
    return @out;
}

sub pz_workshop_scan_disk_in_roots {
    my ($roots) = @_;
    my %map;
    for my $root (@{ $roots // [] }) {
        next unless defined $root && -d $root;
        opendir(my $dh, $root) or next;
        while (my $ent = readdir($dh)) {
            next unless $ent =~ /^\d{5,20}$/;
            my $dir = "$root/$ent";
            next unless -d $dir;
            $map{$ent} = {
                content_dir => $dir,
                mod_infos   => [ pz_workshop_parse_mod_info($dir) ],
            };
        }
        closedir($dh);
    }
    return \%map;
}

sub pz_workshop_scan_disk {
    my ($unix_user, $server_dir, $appid) = @_;
    my @roots = pz_workshop_content_roots($unix_user, $server_dir, $appid);
    return pz_workshop_scan_disk_in_roots(\@roots);
}

sub pz_workshop_path_under_content_roots {
    my ($path, $roots) = @_;
    return 0 unless defined $path && $path ne '';
    my $rp = _pz_workshop_realpath_allow_missing($path);
    return 0 unless defined $rp && -e $rp;
    for my $root (@{ $roots // [] }) {
        my $rr = _pz_workshop_realpath_allow_missing($root) // $root;
        return 1 if $rp eq $rr || index($rp, "$rr/") == 0;
    }
    return 0;
}

sub pz_workshop_normalize_item_id {
    my ($raw) = @_;
    $raw //= '';
    # Accept bare ID or steamcommunity workshop URL.
    if ($raw =~ /id=(\d{5,20})/i) {
        return $1;
    }
    $raw =~ s/[^0-9]//g;
    return ($raw =~ /^\d{5,20}$/) ? $raw : '';
}

# Normalize a PZ version string to dotted digits (e.g. "42.12.0").
sub pz_workshop_normalize_version {
    my ($raw) = @_;
    $raw //= '';
    $raw =~ s/[\t\n\r\0]//g;
    $raw =~ s/^\s+|\s+$//g;
    return '' unless $raw =~ /(\d+(?:\.\d+)*)/;
    return $1;
}

# Extract a deliberate PZ version hint from require/name/id text.
# Avoids treating dep lists / mod names like "BladesmithSystemB42" as versions
# (embedded digits without a dotted minor). Accepts "42.12", "B42.20", "[B42.20]".
sub pz_workshop_extract_version_hint {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/[\t\n\r\0]//g;
    $text =~ s/^\s+|\s+$//g;
    return '' unless length $text;
    if ($text =~ /\[?\s*B?(\d{2}(?:\.\d+)+)\s*\]?/i) {
        return $1;
    }
    if ($text =~ /^\s*(\d+\.\d+(?:\.\d+)*)\s*$/) {
        return $1;
    }
    if ($text =~ /^\s*(\d{2})\s*$/) {
        return $1;
    }
    return '';
}

# Effective require for match/display: mod.info require, else weak name/id fallback.
sub pz_workshop_effective_pz_require {
    my ($mi) = @_;
    return '' unless ref($mi) eq 'HASH';
    my $req = $mi->{'pz_require'} // '';
    $req =~ s/^\s+|\s+$//g;
    my $hint = pz_workshop_extract_version_hint($req);
    return $hint if length $hint;
    for my $key (qw(name id)) {
        my $t = $mi->{$key} // '';
        $hint = pz_workshop_extract_version_hint($t);
        return $hint if length $hint;
    }
    return '';
}

# Compare dotted version strings: -1 if $a < $b, 0 if equal, 1 if $a > $b.
sub pz_workshop_version_cmp {
    my ($a, $b) = @_;
    my $na = pz_workshop_normalize_version($a);
    my $nb = pz_workshop_normalize_version($b);
    return 0 if $na eq '' && $nb eq '';
    return -1 if $na eq '';
    return 1 if $nb eq '';
    my @aa = split /\./, $na;
    my @bb = split /\./, $nb;
    my $n = @aa > @bb ? scalar(@aa) : scalar(@bb);
    for my $i (0 .. $n - 1) {
        my $x = int($aa[$i] // 0);
        my $y = int($bb[$i] // 0);
        return -1 if $x < $y;
        return 1 if $x > $y;
    }
    return 0;
}

# True if mod.info require/pzversion is compatible with the server version.
# Empty require => no match (do not auto-enable). Unknown server => no match.
# Compatible = same major and require <= server (older/equal pin on newer game),
# or exact/prefix/major-only rules. Require newer than server (e.g. 42.13 on 42.12)
# is not compatible.
sub pz_workshop_version_matches {
    my ($require, $server) = @_;
    my $req = pz_workshop_normalize_version($require);
    my $srv = pz_workshop_normalize_version($server);
    return 0 unless length $req && length $srv;
    return 1 if $srv eq $req;
    return 1 if index($srv, "$req.") == 0;   # require 42.12 matches 42.12.0
    return 1 if index($req, "$srv.") == 0;   # server 42 matches require 42.12
    my @rp = split /\./, $req;
    my @sp = split /\./, $srv;
    return 0 unless @rp && @sp && $rp[0] eq $sp[0];
    # Major-only require ("42") matches any 42.x
    return 1 if @rp == 1;
    # Same major+minor (incl. patch differences via prefix above)
    return 1 if defined $rp[1] && defined $sp[1] && $rp[1] eq $sp[1];
    # Same major, require not newer than server (42.12/42.13 ok on 42.20)
    return 1 if pz_workshop_version_cmp($req, $srv) <= 0;
    return 0;
}

# Exact major.minor (or prefix) match — used to prefer auto-enable picks.
sub pz_workshop_version_exactish {
    my ($require, $server) = @_;
    my $req = pz_workshop_normalize_version($require);
    my $srv = pz_workshop_normalize_version($server);
    return 0 unless length $req && length $srv;
    return 1 if $srv eq $req;
    return 1 if index($srv, "$req.") == 0;
    return 1 if index($req, "$srv.") == 0;
    my @rp = split /\./, $req;
    my @sp = split /\./, $srv;
    return 0 unless @rp >= 2 && @sp >= 2;
    return 1 if $rp[0] eq $sp[0] && $rp[1] eq $sp[1];
    return 0;
}

# Inventory PZ-Version cell data: label + match badge hint.
# No extractable version (empty / dep names) => unbekannt/keine Angabe, match unknown|none.
# Real version + matching server => ok; mismatch => bad; unknown server => none.
# Optional $mi_or_fallback: hashref mod.info (name/id fallback) or plain fallback text.
sub pz_workshop_pz_version_cell {
    my ($pz_require, $server_ver, $mi_or_fallback) = @_;
    my $raw = defined $pz_require ? $pz_require : '';
    $raw =~ s/^\s+|\s+$//g;

    my $ver = '';
    my $from_fallback = 0;
    if (ref($mi_or_fallback) eq 'HASH') {
        my %tmp = %{$mi_or_fallback};
        $tmp{pz_require} = $raw if $raw ne '';
        $ver = pz_workshop_effective_pz_require(\%tmp);
        my $from_req = pz_workshop_extract_version_hint($raw);
        $from_fallback = 1 if length $ver && !length $from_req;
    } else {
        $ver = pz_workshop_extract_version_hint($raw);
        if (!length $ver && defined $mi_or_fallback && !ref($mi_or_fallback)) {
            $ver = pz_workshop_extract_version_hint($mi_or_fallback);
            $from_fallback = 1 if length $ver;
        }
    }

    if (!length $ver) {
        if ($raw eq '') {
            return { label => 'keine Angabe', match => 'none' };
        }
        # Dep lists / mod names in require — not a version pin.
        return { label => 'unbekannt', match => 'unknown' };
    }

    my $label = "PZ $ver";
    $label .= ' ~' if $from_fallback;
    my $srv = pz_workshop_normalize_version($server_ver);
    if (!length $srv) {
        return { label => $label, match => 'none' };
    }
    if (pz_workshop_version_matches($ver, $server_ver)) {
        return { label => $label, match => 'ok' };
    }
    return { label => $label, match => 'bad' };
}

# Select Mod IDs to auto-enable for a workshop item given $server_ver.
# Returns at most ONE id: best version match, else a single unconstrained mod,
# else none. Never auto-enables multiple Mod IDs for one workshop item.
sub pz_workshop_select_mod_ids_for_version {
    my ($mod_infos, $server_ver) = @_;
    my $srv = pz_workshop_normalize_version($server_ver);
    return () unless length $srv;
    my @infos = pz_workshop_collapse_mod_infos($mod_infos, $srv);
    return () unless @infos;
    my @exact;
    my @compatible;
    my @unconstrained;
    my $has_mismatch = 0;
    my %seen;
    my %req_for;
    for my $mi (@infos) {
        next unless ref($mi) eq 'HASH';
        my $id = $mi->{'id'} // '';
        $id =~ s/[;\r\n]//g;
        next unless length $id;
        next if $seen{$id}++;
        my $req = pz_workshop_effective_pz_require($mi);
        $req_for{$id} = $req;
        if ($req eq '') {
            push @unconstrained, $id;
            next;
        }
        if (pz_workshop_version_matches($req, $srv)) {
            push @compatible, $id;
            push @exact, $id if pz_workshop_version_exactish($req, $srv);
        } else {
            $has_mismatch = 1;
        }
    }
    if (@exact) {
        @exact = sort {
            pz_workshop_version_cmp($req_for{$b}, $req_for{$a})
              || ($a cmp $b)
        } @exact;
        return ($exact[0]);
    }
    if (@compatible) {
        @compatible = sort {
            pz_workshop_version_cmp($req_for{$b}, $req_for{$a})
              || ($a cmp $b)
        } @compatible;
        return ($compatible[0]);
    }
    return () if $has_mismatch;
    # Only auto-enable when exactly one unconstrained Mod ID exists.
    return @unconstrained == 1 ? ($unconstrained[0]) : ();
}

# True for PZ game builds used by mods (Build 41/42…), not OS/Java/modversion "1.3.0".
sub pz_workshop_looks_like_game_version {
    my ($raw) = @_;
    my $v = pz_workshop_normalize_version($raw);
    return 0 unless length $v;
    # Require major.minor (42.12 / 41.78.16). Major 40–49 covers current PZ eras.
    return 0 unless $v =~ /\A(\d{2})\.(\d+)/;
    my $major = int($1);
    return 0 unless $major >= 40 && $major <= 49;
    return 1;
}

# Pull a PZ game version out of one log/console line (strict patterns only).
sub pz_workshop_version_from_log_line {
    my ($line) = @_;
    $line = '' unless defined $line;
    # Dedicated/startup: versionNumber=42.12.0  or  version=42.20.3
    if ($line =~ /versionNumber\s*=\s*([0-9]+(?:\.[0-9]+)*)/i
        || $line =~ /(?:^|[^\w])version\s*=\s*([0-9]+(?:\.[0-9]+)*)/i)
    {
        my $v = pz_workshop_normalize_version($1);
        return $v if pz_workshop_looks_like_game_version($v);
    }
    # "Project Zomboid Build 42.20.x" / "LogVersion: … 42.20.3"
    if ($line =~ /(?:Project\s*Zomboid|LogVersion).*?\b(?:Build\s*)?([0-9]{2}\.[0-9]+(?:\.[0-9]+)*)/i) {
        my $v = pz_workshop_normalize_version($1);
        return $v if pz_workshop_looks_like_game_version($v);
    }
    return '';
}

# Best-effort PZ game version from serverfiles / recent logs. '' if unknown.
# Never treat OS/Java/mod "version: 1.3.0" as the game build — mods use 41.x/42.x.
sub pz_workshop_detect_server_version {
    my ($unix_user, $server_dir) = @_;
    $server_dir //= '';
    my $home = pz_workshop_unix_home($unix_user) // '';

    my @files;
    if ($server_dir ne '') {
        push @files,
            "$server_dir/serverfiles/media/gameversion",
            "$server_dir/serverfiles/media/gameversion.txt",
            "$server_dir/media/gameversion",
            "$server_dir/media/gameversion.txt";
    }
    for my $path (@files) {
        next unless -f $path && -r $path;
        open(my $fh, '<', $path) or next;
        local $/;
        my $body = <$fh> // '';
        close($fh);
        my $v = pz_workshop_normalize_version($body);
        return $v if pz_workshop_looks_like_game_version($v);
    }

    my @log_paths;
    push @log_paths, "$home/Zomboid/server-console.txt"
        if $home ne '' && -f "$home/Zomboid/server-console.txt";
    push @log_paths, "$home/Zomboid/console.txt"
        if $home ne '' && -f "$home/Zomboid/console.txt";
    my $logs = ($home ne '') ? "$home/Zomboid/Logs" : '';
    if ($logs ne '' && -d $logs) {
        my @candidates;
        if (opendir(my $dh, $logs)) {
            while (my $ent = readdir($dh)) {
                next unless $ent =~ /\.(txt|log)\z/i;
                next unless $ent =~ /DebugLog|console|server|LogVersion/i
                    || $ent =~ /\d{2}-\d{2}-\d{2}/;
                my $p = "$logs/$ent";
                next unless -f $p;
                push @candidates, $p;
            }
            closedir($dh);
        }
        push @log_paths, sort { (stat($b))[9] <=> (stat($a))[9] } @candidates;
    }

    my $seen = 0;
    for my $path (@log_paths) {
        last if $seen >= 8;
        next unless defined $path && -f $path;
        $seen++;
        open(my $fh, '<', $path) or next;
        my $found = '';
        while (my $line = <$fh>) {
            my $v = pz_workshop_version_from_log_line($line);
            $found = $v if length $v;  # keep last good PZ build in file
        }
        close($fh);
        return $found if length $found;
    }
    return '';
}

sub pz_workshop_normalize_mod_id {
    my ($raw) = @_;
    $raw //= '';
    $raw =~ s/[\t\n\r\0]//g;
    $raw =~ s/^\s+|\s+$//g;
    # PZ Mod IDs are free-form in mod.info (e.g. "[B42] 815Tatra"). Only ";" is
    # forbidden — it separates entries in the Mods= INI list.
    return '' if $raw eq '' || index($raw, ';') >= 0;
    return '' if length($raw) > 128;
    # Printable ASCII (space through ~); reject control / non-ASCII for INI safety.
    return ($raw =~ /\A[\x20-\x7E]+\z/ && $raw =~ /[A-Za-z0-9]/) ? $raw : '';
}

sub _pz_workshop_http_get_json {
    my ($url, $max_time) = @_;
    $max_time = 30 unless defined $max_time && $max_time =~ /^\d+$/;
    return undef unless defined $url && $url =~ m{\Ahttps://}i;
    my @cmd = (
        'curl', '-fsSL',
        '--connect-timeout', '15',
        '--max-time', "$max_time",
        '--proto-redir', '=https',
        $url,
    );
    my $out = '';
    {
        local $SIG{__WARN__} = sub { };
        open(my $fh, '-|', @cmd) or return undef;
        local $/;
        $out = <$fh> // '';
        close($fh);
        return undef if $? != 0;
    }
    return undef unless $out =~ /\S/;
    my $data;
    eval { $data = decode_json($out); 1 } or return undef;
    return $data;
}

sub _pz_workshop_urlencode {
    my ($value) = @_;
    $value //= '';
    $value =~ s/([^A-Za-z0-9_\-.~])/sprintf('%%%02X', ord($1))/ge;
    return $value;
}

# Search Steam Workshop. Returns (ok, results_aref, err).
# results: [ { id, title, description, creator, subscriptions, preview_url } ]
sub pz_workshop_search {
    my ($query, $appid, %opts) = @_;
    $query //= '';
    $query =~ s/[\t\n\r\0]//g;
    $query =~ s/^\s+|\s+$//g;
    return (0, [], 'empty_query') unless length $query;
    $query = substr($query, 0, 100);

    my $key = steam_web_api_key();
    return (0, [], 'api_key_missing') unless $key =~ /\S/;

    $appid = int($appid || 0);
    return (0, [], 'bad_appid') unless $appid > 0;

    my $page = int($opts{'page'} // 1);
    $page = 1 if $page < 1;
    my $per = int($opts{'per_page'} // 20);
    $per = 20 if $per < 1 || $per > 50;

    my $q = _pz_workshop_urlencode($query);
    my $k = _pz_workshop_urlencode($key);
    my $url = "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/"
        . "?key=$k"
        . "&query_type=1"
        . "&page=$page"
        . "&numperpage=$per"
        . "&appid=$appid"
        . "&search_text=$q"
        . "&return_short_description=true"
        . "&return_details=true";

    my $data = _pz_workshop_http_get_json($url, 45);
    return (0, [], 'api_failed') unless ref($data) eq 'HASH';
    my $resp = $data->{'response'};
    return (0, [], 'api_failed') unless ref($resp) eq 'HASH';

    my $list = $resp->{'publishedfiledetails'} // $resp->{'publishedfiledetails'};
    $list = [] unless ref($list) eq 'ARRAY';
    my @out;
    for my $it (@$list) {
        next unless ref($it) eq 'HASH';
        my $id = $it->{'publishedfileid'} // $it->{'fileid'} // '';
        $id =~ s/[^0-9]//g;
        next unless length $id;
        my $title = $it->{'title'} // '';
        my $desc = $it->{'file_description'} // $it->{'short_description'} // '';
        $desc =~ s/\s+/ /g;
        $desc = substr($desc, 0, 280) if length $desc > 280;
        push @out, {
            id            => $id,
            title         => $title,
            description   => $desc,
            creator       => $it->{'creator'} // '',
            subscriptions => $it->{'subscriptions'} // 0,
            preview_url   => $it->{'preview_url'} // '',
        };
    }
    return (1, \@out, undef);
}

# Parse search fixture (tests / offline). Same shape as API response.publishedfiledetails.
sub pz_workshop_parse_search_fixture {
    my ($json_text) = @_;
    return () unless defined $json_text && $json_text =~ /\S/;
    my $data;
    eval { $data = decode_json($json_text); 1 } or return ();
    my $list;
    if (ref($data) eq 'HASH') {
        if (ref($data->{'response'}) eq 'HASH') {
            $list = $data->{'response'}{'publishedfiledetails'};
        } else {
            $list = $data->{'publishedfiledetails'} // $data->{'results'};
        }
    } elsif (ref($data) eq 'ARRAY') {
        $list = $data;
    }
    return () unless ref($list) eq 'ARRAY';
    my @out;
    for my $it (@$list) {
        next unless ref($it) eq 'HASH';
        my $id = $it->{'publishedfileid'} // $it->{'id'} // '';
        $id =~ s/[^0-9]//g;
        next unless length $id;
        push @out, {
            id            => $id,
            title         => $it->{'title'} // '',
            description   => $it->{'file_description'} // $it->{'description'} // '',
            creator       => $it->{'creator'} // '',
            subscriptions => $it->{'subscriptions'} // 0,
            preview_url   => $it->{'preview_url'} // '',
        };
    }
    return @out;
}

sub _pz_workshop_parse_details_children {
    my ($children) = @_;
    return () unless ref($children) eq 'ARRAY';
    my @out;
    my %seen;
    for my $c (@$children) {
        my $cid = '';
        if (ref($c) eq 'HASH') {
            $cid = $c->{'publishedfileid'} // $c->{'fileid'} // '';
        } elsif (defined $c) {
            $cid = $c;
        }
        $cid =~ s/[^0-9]//g;
        next unless length $cid;
        next if $seen{$cid}++;
        push @out, $cid;
    }
    return @out;
}

sub _pz_workshop_parse_details_entry {
    my ($it) = @_;
    return () unless ref($it) eq 'HASH';
    my $id = $it->{'publishedfileid'} // $it->{'fileid'} // '';
    $id =~ s/[^0-9]//g;
    return () unless length $id;

    my $desc = $it->{'file_description'} // $it->{'description'} // $it->{'short_description'} // '';
    $desc =~ s/\s+/ /g;
    $desc = substr($desc, 0, 280) if length $desc > 280;

    my $entry = {
        title        => $it->{'title'} // '',
        description  => $desc,
        preview_url  => $it->{'preview_url'} // '',
        time_updated => $it->{'time_updated'} // 0,
    };
    my @children = _pz_workshop_parse_details_children($it->{'children'});
    $entry->{'children'} = \@children if @children;
    return ($id, $entry);
}

sub _pz_workshop_details_from_list {
    my ($list) = @_;
    my %out;
    return \%out unless ref($list) eq 'ARRAY';
    for my $it (@$list) {
        my ($id, $entry) = _pz_workshop_parse_details_entry($it);
        next unless defined $id && ref($entry) eq 'HASH';
        $out{$id} = $entry;
    }
    return \%out;
}

# Parse GetPublishedFileDetails fixture JSON. Returns id => { title, description, preview_url, time_updated, children? }.
sub pz_workshop_parse_details_fixture {
    my ($json_text) = @_;
    return {} unless defined $json_text && $json_text =~ /\S/;
    my $data;
    eval { $data = decode_json($json_text); 1 } or return {};
    my $list;
    if (ref($data) eq 'HASH') {
        if (ref($data->{'response'}) eq 'HASH') {
            $list = $data->{'response'}{'publishedfiledetails'};
        } else {
            $list = $data->{'publishedfiledetails'};
        }
    } elsif (ref($data) eq 'ARRAY') {
        $list = $data;
    }
    return _pz_workshop_details_from_list($list);
}

sub _pz_workshop_http_post_json {
    my ($url, $form_fields, $max_time) = @_;
    $max_time = 30 unless defined $max_time && $max_time =~ /^\d+$/;
    return undef unless defined $url && $url =~ m{\Ahttps://}i;
    return undef unless ref($form_fields) eq 'ARRAY' && @$form_fields;
    my $post_data = join('&', @$form_fields);
    my @cmd = (
        'curl', '-fsSL',
        '--connect-timeout', '15',
        '--max-time', "$max_time",
        '--proto-redir', '=https',
        '-X', 'POST',
        '-H', 'Content-Type: application/x-www-form-urlencoded',
        '--data', $post_data,
        $url,
    );
    my $out = '';
    {
        local $SIG{__WARN__} = sub { };
        open(my $fh, '-|', @cmd) or return undef;
        local $/;
        $out = <$fh> // '';
        close($fh);
        return undef if $? != 0;
    }
    return undef unless $out =~ /\S/;
    my $data;
    eval { $data = decode_json($out); 1 } or return undef;
    return $data;
}

# Build IPublishedFileService/GetDetails URL (includechildren — RemoteStorage GetPublishedFileDetails does not return Required items).
sub pz_workshop_details_get_url {
    my ($key, $ids) = @_;
    return '' unless defined $key && $key =~ /\S/ && ref($ids) eq 'ARRAY' && @$ids;
    my $url = 'https://api.steampowered.com/IPublishedFileService/GetDetails/v1/'
        . '?key=' . _pz_workshop_urlencode($key)
        . '&includechildren=true'
        . '&return_children=true'
        . '&includetags=false'
        . '&includeadditionalpreviews=false'
        . '&includekvtags=false'
        . '&includevotes=false'
        . '&short_description=true'
        . '&includeforsaledata=false'
        . '&includemetadata=false'
        . '&strip_description_bbcode=true';
    for my $i (0 .. $#$ids) {
        $url .= '&publishedfileids%5B' . $i . '%5D=' . _pz_workshop_urlencode($ids->[$i]);
    }
    return $url;
}

# Parse Required items IDs from a Steam Workshop filedetails HTML page.
sub pz_workshop_parse_required_items_html {
    my ($html) = @_;
    return () unless defined $html && $html =~ /\S/;
    my $block = '';
    if ($html =~ /id=["']RequiredItems["'][^>]*>(.*?)<\/div>\s*<\/div>/si) {
        $block = $1;
    } elsif ($html =~ /requiredItemsContainer[^>]*>(.*?)(?:<\/div>\s*<\/div>\s*<!--|<\/div>\s*<\/div>\s*<div class="panel")/si) {
        $block = $1;
    } else {
        return ();
    }
    my @ids;
    my %seen;
    while ($block =~ /filedetails\/\?id=(\d{5,20})/gi) {
        my $id = $1;
        next if $seen{$id}++;
        push @ids, $id;
    }
    return @ids;
}

sub _pz_workshop_http_get_text {
    my ($url, $max_time) = @_;
    $max_time = 30 unless defined $max_time && $max_time =~ /^\d+$/;
    return undef unless defined $url && $url =~ m{\Ahttps://steamcommunity\.com/}i;
    my @cmd = (
        'curl', '-fsSL',
        '-A', 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        '--connect-timeout', '15',
        '--max-time', "$max_time",
        '--proto-redir', '=https',
        $url,
    );
    my $out = '';
    {
        local $SIG{__WARN__} = sub { };
        open(my $fh, '-|', @cmd) or return undef;
        local $/;
        $out = <$fh> // '';
        close($fh);
        return undef if $? != 0;
    }
    return ($out =~ /\S/) ? $out : undef;
}

# Scrape Steam Workshop "Required items" for one published file id (no API key).
sub pz_workshop_scrape_required_items {
    my ($workshop_id) = @_;
    $workshop_id = pz_workshop_normalize_item_id($workshop_id);
    return () unless length $workshop_id;
    my $url = 'https://steamcommunity.com/sharedfiles/filedetails/?id=' . $workshop_id;
    my $html = _pz_workshop_http_get_text($url, 45);
    return () unless defined $html;
    return pz_workshop_parse_required_items_html($html);
}

# Enrich details hash: fill missing children via HTML Required-items scrape.
sub pz_workshop_enrich_details_children {
    my ($details) = @_;
    return $details unless ref($details) eq 'HASH';
    for my $id (keys %$details) {
        my $entry = $details->{$id};
        next unless ref($entry) eq 'HASH';
        my @kids = _pz_workshop_parse_details_children($entry->{'children'});
        next if @kids;
        @kids = pz_workshop_scrape_required_items($id);
        $entry->{'children'} = \@kids if @kids;
    }
    return $details;
}

# Batch Steam published-file details (IPublishedFileService/GetDetails + children).
# Returns id => details hash; {} on missing key / API fail. May scrape HTML for Required items when children absent.
sub pz_workshop_steam_details {
    my ($ids) = @_;
    return {} unless ref($ids) eq 'ARRAY';

    my $key = steam_web_api_key();
    return {} unless $key =~ /\S/;

    my @clean;
    my %seen;
    for my $raw (@$ids) {
        my $id = $raw // '';
        $id =~ s/[^0-9]//g;
        next unless length $id;
        next if $seen{$id}++;
        push @clean, $id;
    }
    return {} unless @clean;

    my %merged;
    while (@clean) {
        my @chunk = splice @clean, 0, 50;
        my $url = pz_workshop_details_get_url($key, \@chunk);
        next unless length $url;
        my $data = _pz_workshop_http_get_json($url, 45);
        next unless ref($data) eq 'HASH';
        my $resp = $data->{'response'};
        next unless ref($resp) eq 'HASH';
        my $part = _pz_workshop_details_from_list($resp->{'publishedfiledetails'});
        next unless ref($part) eq 'HASH';
        @merged{keys %$part} = values %$part;
    }
    return pz_workshop_enrich_details_children(\%merged);
}

# Fetch children via HTML scrape only (used when Steam Web API key is missing).
sub pz_workshop_fetch_details_via_scrape {
    my ($ids) = @_;
    my %out;
    return \%out unless ref($ids) eq 'ARRAY';
    for my $raw (@$ids) {
        my $id = pz_workshop_normalize_item_id($raw);
        next unless length $id;
        my @kids = pz_workshop_scrape_required_items($id);
        $out{$id} = { children => \@kids };
    }
    return \%out;
}

# Resolve subscribe closure. With API key: GetDetails(+scrape enrich). Without: HTML Required-items scrape.
# Returns (ok, { ids => [...], err => ..., warn => ... }).
sub pz_workshop_subscribe_resolve_closure {
    my ($root_id) = @_;
    $root_id = pz_workshop_normalize_item_id($root_id);
    return (0, { err => 'bad_id', ids => [] }) unless length $root_id;

    my $key = steam_web_api_key();
    my ($ok, $res);
    if ($key =~ /\S/) {
        ($ok, $res) = pz_workshop_resolve_dependency_closure($root_id, max => 20);
    } else {
        ($ok, $res) = pz_workshop_resolve_dependency_closure($root_id,
            max => 20,
            fetch_details => \&pz_workshop_fetch_details_via_scrape,
        );
        $res = {} unless ref($res) eq 'HASH';
        $res->{'warn'} = 'api_key_missing';
    }
    $res = {} unless ref($res) eq 'HASH';
    return ($ok, $res);
}

# Collect mod ids from content dirs in workshop-id order (deps before root).
# Per item: version-matched prefer; unconstrained (empty require) if no mismatch.
sub pz_workshop_collect_subscribe_mod_ids {
    my ($ordered_ids, $content_dir_by_id, $server_ver) = @_;
    return () unless ref($ordered_ids) eq 'ARRAY' && ref($content_dir_by_id) eq 'HASH';
    my @mod_ids;
    my %seen;
    for my $wid (@$ordered_ids) {
        my $dir = $content_dir_by_id->{$wid} // next;
        my @infos = pz_workshop_parse_mod_info($dir);
        for my $mid (pz_workshop_select_mod_ids_for_version(\@infos, $server_ver)) {
            push @mod_ids, $mid unless $seen{$mid}++;
        }
    }
    return @mod_ids;
}

# Insert new mod ids before root mod ids when already present in INI; keep existing order.
sub _pz_workshop_merge_mods_subscribe {
    my ($existing_aref, $new_aref, $root_mods_aref) = @_;
    my @existing = @{ $existing_aref // [] };
    my %have = map { $_ => 1 } @existing;
    my @to_add = grep { defined $_ && $_ ne '' && !$have{$_}++ } @{ $new_aref // [] };
    return @existing unless @to_add;

    my $insert_at = scalar @existing;
    if (@{ $root_mods_aref // [] }) {
        my %root_set = map { $_ => 1 } @{ $root_mods_aref };
        for my $i (0 .. $#existing) {
            if ($root_set{ $existing[$i] }) {
                $insert_at = $i;
                last;
            }
        }
    }
    splice @existing, $insert_at, 0, @to_add;
    return @existing;
}

# Patch INI once for subscribe: all workshop ids + version-filtered mod ids (deps first).
# Returns (ok, err, { dep_count => N, total => T, ini => path, server_ver => ... }).
sub pz_workshop_subscribe_patch_ini {
    my ($unix_user, $script_name, $root_id, $ordered_ids, $content_dir_by_id, $server_dir) = @_;
    $root_id = pz_workshop_normalize_item_id($root_id);
    return (0, 'bad_id', undef) unless length $root_id;
    return (0, 'bad_ids', undef) unless ref($ordered_ids) eq 'ARRAY' && @$ordered_ids;
    return (0, 'bad_dirs', undef) unless ref($content_dir_by_id) eq 'HASH';

    my ($ok, $ini, $err) = pz_workshop_resolve_ini_path($unix_user, $script_name);
    return (0, $err // 'no_ini', undef) unless $ok;

    my $server_ver = pz_workshop_detect_server_version($unix_user, $server_dir);

    my ($vals, undef, $raw) = pz_workshop_read_ini($ini);
    my @wi = pz_workshop_split_list($vals->{'WorkshopItems'} // '');
    my %wi_set = map { $_ => 1 } @wi;
    for my $id (@$ordered_ids) {
        my $clean = pz_workshop_normalize_item_id($id);
        next unless length $clean;
        push @wi, $clean unless $wi_set{$clean}++;
    }

    my @existing_mods = pz_workshop_split_list($vals->{'Mods'} // '');
    my @all_mod_ids = pz_workshop_collect_subscribe_mod_ids(
        $ordered_ids, $content_dir_by_id, $server_ver);
    my @root_infos = pz_workshop_parse_mod_info($content_dir_by_id->{$root_id} // '');
    my @root_mod_ids = pz_workshop_select_mod_ids_for_version(\@root_infos, $server_ver);
    my @merged_mods = _pz_workshop_merge_mods_subscribe(\@existing_mods, \@all_mod_ids, \@root_mod_ids);

    my $new_wi = pz_workshop_join_list(@wi);
    my $new_mods = pz_workshop_join_list(@merged_mods);

    if ($raw eq '' && !-f $ini) {
        my $dir = dirname($ini);
        make_path($dir) unless -d $dir;
        $raw = "WorkshopItems=$new_wi\nMods=$new_mods\n";
    } else {
        $raw = _pz_workshop_set_ini_key($raw, 'WorkshopItems', $new_wi);
        $raw = _pz_workshop_set_ini_key($raw, 'Mods', $new_mods);
    }

    open(my $fh, '>', $ini) or return (0, 'write_failed', undef);
    print $fh $raw;
    close($fh);

    my ($vals3) = pz_workshop_read_ini($ini);
    my $wi_check = $vals3->{'WorkshopItems'} // '';
    return (0, 'verify_failed', undef) unless $wi_check =~ /(?:^|;)\Q$root_id\E(?:;|$)/;

    my $total = scalar @$ordered_ids;
    my $dep_count = $total > 0 ? ($total - 1) : 0;
    return (1, undef, {
        dep_count  => $dep_count,
        total      => $total,
        ini        => $ini,
        mods       => $new_mods,
        workshop   => $new_wi,
        server_ver => $server_ver,
        mods_auto  => scalar(@all_mod_ids),
    });
}

# Resolve transitive Steam required-item (children) closure for subscribe.
# Returns (ok, { ids => [...], err => ... }). Order: deps before dependents; root included.
sub pz_workshop_resolve_dependency_closure {
    my ($root_id, %opts) = @_;
    $root_id = pz_workshop_normalize_item_id($root_id);
    return (0, { err => 'bad_id', ids => [] }) unless length $root_id;

    my $max = int($opts{'max'} // 20);
    $max = 20 if $max < 1;

    my $fetch = $opts{'fetch_details'};
    my %in_closure = ($root_id => 1);
    my %visited;
    my @discover_order;
    my @queue = ($root_id);

    while (@queue) {
        my @batch;
        while (@queue) {
            my $id = shift @queue;
            next if $visited{$id}++;
            push @batch, $id;
            push @discover_order, $id;
        }
        last unless @batch;

        my $details;
        if (ref($fetch) eq 'CODE') {
            $details = $fetch->(\@batch) // {};
        } else {
            $details = pz_workshop_steam_details(\@batch) // {};
        }
        $details = {} unless ref($details) eq 'HASH';

        for my $id (@batch) {
            my $entry = $details->{$id};
            $entry = {} unless ref($entry) eq 'HASH';
            my @children = _pz_workshop_parse_details_children($entry->{'children'});
            for my $child (@children) {
                next if $in_closure{$child};
                if (scalar(keys %in_closure) >= $max) {
                    $in_closure{$child} = 1;
                    return (0, {
                        err => 'cap_exceeded',
                        ids => [ sort keys %in_closure ],
                    });
                }
                $in_closure{$child} = 1;
                push @queue, $child unless $visited{$child};
            }
        }
    }

    # BFS from root visits parents before children; reverse => deps before dependents.
    my @ordered = reverse @discover_order;
    return (1, { ids => \@ordered, err => undef });
}

# Merge disk scan with INI WorkshopItems. Returns arrayref of row hashes.
sub pz_workshop_merge_inventory {
    my ($ini_path, $disk_map) = @_;
    $disk_map //= {};
    my $vals = {};
    if (defined $ini_path && -f $ini_path) {
        ($vals) = pz_workshop_read_ini($ini_path);
    }
    my %in_ini = map { $_ => 1 } pz_workshop_split_list($vals->{'WorkshopItems'} // '');
    my %ids;
    $ids{$_} = 1 for keys %$disk_map;
    $ids{$_} = 1 for keys %in_ini;
    my @rows;
    for my $id (sort { $a cmp $b } keys %ids) {
        my $on_disk = exists $disk_map->{$id} ? 1 : 0;
        my $in = $in_ini{$id} ? 1 : 0;
        my $status = ($on_disk && $in) ? 'active'
                   : ($on_disk && !$in) ? 'inactive'
                   : 'orphan_ini';
        my $ent = $disk_map->{$id} // {};
        push @rows, {
            workshop_id => $id,
            on_disk     => $on_disk,
            in_ini      => $in,
            content_dir => $ent->{content_dir},
            mod_infos   => $ent->{mod_infos} // [],
            status      => $status,
        };
    }
    return \@rows;
}

sub pz_workshop_list_inventory {
    my ($unix_user, $script_name, $server_dir) = @_;
    my $appid = get_workshop_appid($script_name) || 108600;
    my $disk = pz_workshop_scan_disk($unix_user, $server_dir, $appid);
    my ($ok, $ini) = pz_workshop_resolve_ini_path($unix_user, $script_name);
    my $rows = pz_workshop_merge_inventory($ok ? $ini : undef, $disk);
    my $server_ver = pz_workshop_detect_server_version($unix_user, $server_dir);
    my %enabled;
    if ($ok && defined $ini && -f $ini) {
        my ($vals) = pz_workshop_read_ini($ini);
        %enabled = map { $_ => 1 } pz_workshop_split_list($vals->{'Mods'} // '');
    }
    for my $row (@{ $rows // [] }) {
        next unless ref($row) eq 'HASH';
        my @infos;
        my $any_mod_on = 0;
        my @collapsed = pz_workshop_collapse_mod_infos($row->{'mod_infos'}, $server_ver);
        for my $mi (@collapsed) {
            next unless ref($mi) eq 'HASH';
            my %copy = %$mi;
            my $id = $copy{'id'} // '';
            $copy{'enabled_in_ini'} = ($id ne '' && $enabled{$id}) ? 1 : 0;
            $any_mod_on = 1 if $copy{'enabled_in_ini'};
            push @infos, \%copy;
        }
        $row->{'mod_infos'} = \@infos;
        # In WorkshopItems but no Mod ID in Mods= → not "fully active".
        if (($row->{'status'} // '') eq 'active' && @infos && !$any_mod_on) {
            $row->{'status'} = 'workshop_only';
        }
    }
    return $rows;
}

sub pz_workshop_enable_item {
    my ($ini, $wid, $mod_ids) = @_;
    $wid = pz_workshop_normalize_item_id($wid);
    return (0, 'bad_id') unless length $wid;
    my ($ok, $err) = pz_workshop_patch_ini($ini, {
        add_workshop => [$wid],
        add_mods     => [ @{ $mod_ids // [] } ],
    });
    return (0, $err) unless $ok;
    my ($vals) = pz_workshop_read_ini($ini);
    my $wi = $vals->{WorkshopItems} // '';
    return (0, 'verify_failed') unless $wi =~ /(?:^|;)\Q$wid\E(?:;|$)/;
    return (1, undef);
}

sub pz_workshop_disable_item {
    my ($ini, $wid, $mod_ids) = @_;
    $wid = pz_workshop_normalize_item_id($wid);
    return (0, 'bad_id') unless length $wid;
    my ($ok, $err) = pz_workshop_patch_ini($ini, {
        remove_workshop => [$wid],
        remove_mods     => [ @{ $mod_ids // [] } ],
    });
    return (0, $err) unless $ok;
    my ($vals) = pz_workshop_read_ini($ini);
    my $wi = $vals->{WorkshopItems} // '';
    return (0, 'verify_failed') if $wi =~ /(?:^|;)\Q$wid\E(?:;|$)/;
    return (1, undef);
}

# Enable a single Mod ID (also ensures WorkshopItems contains $wid).
sub pz_workshop_enable_mod {
    my ($ini, $wid, $mod_id) = @_;
    $mod_id = pz_workshop_normalize_mod_id($mod_id);
    return (0, 'bad_mod_id') unless length $mod_id;
    return pz_workshop_enable_item($ini, $wid, [$mod_id]);
}

# Disable a single Mod ID in Mods= only (WorkshopItems unchanged).
sub pz_workshop_disable_mod {
    my ($ini, $mod_id) = @_;
    $mod_id = pz_workshop_normalize_mod_id($mod_id);
    return (0, 'bad_mod_id') unless length $mod_id;
    my ($ok, $err) = pz_workshop_patch_ini($ini, {
        remove_mods => [$mod_id],
    });
    return (0, $err) unless $ok;
    my ($vals) = pz_workshop_read_ini($ini);
    my $mods = $vals->{'Mods'} // '';
    return (0, 'verify_failed') if $mods =~ /(?:^|;)\Q$mod_id\E(?:;|$)/;
    return (1, undef);
}

sub _pz_workshop_rmtree_as_user {
    my ($unix_user, $dir) = @_;
    return 0 unless defined $dir && -d $dir;
    my $run_direct = 0;
    if (!defined $unix_user || $unix_user eq '') {
        $run_direct = 1;
    } else {
        my $uid = (getpwnam($unix_user))[2];
        $run_direct = 1 if defined $uid && $> == $uid;
    }
    if ($run_direct) {
        require File::Path;
        File::Path::rmtree($dir);
        return !-d $dir;
    }
    (my $safe = $dir) =~ s/'/'\\''/g;
    system('su', '-s', '/bin/bash', '-c', "rm -rf -- '$safe'", $unix_user);
    return ($? == 0 && !-d $dir) ? 1 : 0;
}

sub pz_workshop_delete_item {
    my ($unix_user, $ini, $workshop_id, $content_dir, $mod_ids, $roots) = @_;
    $workshop_id = pz_workshop_normalize_item_id($workshop_id);
    return (0, 'bad_id') unless length $workshop_id;

    # Build candidate dirs: every $root/$id (Steam may leave duplicates under
    # home Steam tree and serverfiles), plus the inventory content_dir if set.
    my @candidates;
    my %seen;
    for my $root (@{ $roots // [] }) {
        next unless defined $root && $root ne '';
        my $cand = "$root/$workshop_id";
        next unless -d $cand;
        my $key = _pz_workshop_realpath_allow_missing($cand) // $cand;
        next if $seen{$key}++;
        push @candidates, $cand;
    }
    if (defined $content_dir && $content_dir ne '' && -d $content_dir) {
        my $key = _pz_workshop_realpath_allow_missing($content_dir) // $content_dir;
        push @candidates, $content_dir unless $seen{$key}++;
    }

    for my $cand (@candidates) {
        unless (pz_workshop_path_under_content_roots($cand, $roots)) {
            return (0, 'path_rejected');
        }
    }

    my ($ok, $err) = pz_workshop_disable_item($ini, $workshop_id, $mod_ids // []);
    return (0, $err) unless $ok;

    for my $cand (@candidates) {
        next unless -d $cand;
        unless (_pz_workshop_rmtree_as_user($unix_user, $cand)) {
            return (0, 'delete_failed');
        }
        if (-d $cand) {
            return (0, 'verify_failed');
        }
    }

    my ($vals) = pz_workshop_read_ini($ini);
    my $wi = $vals->{WorkshopItems} // '';
    return (0, 'verify_failed') if $wi =~ /(?:^|;)\Q$workshop_id\E(?:;|$)/;
    return (1, undef);
}

# Back-compat alias — prefer pz_workshop_list_inventory for new callers.
sub pz_workshop_list_installed {
    my ($unix_user, $script_name, $server_dir) = @_;
    return pz_workshop_list_inventory($unix_user, $script_name, $server_dir);
}

sub pz_workshop_write_subscribe_job_meta {
    my ($job_dir, $meta, $unix_user) = @_;
    return 0 unless defined $job_dir && -d $job_dir && ref($meta) eq 'HASH';
    my $path = "$job_dir/pz_workshop_item.json";
    open(my $fh, '>', $path) or return 0;
    print $fh encode_json($meta);
    close($fh);
    chmod 0600, $path;
    if (defined $unix_user && $unix_user ne '') {
        my @pw = getpwnam($unix_user);
        chown($pw[2], $pw[3], $path) if @pw;
    }
    return 1;
}

1;
