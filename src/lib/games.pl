# LinuxGSM-WebCore - LGSM game list fetching and caching
use strict;
use warnings;

our ($module_root, $module_root_directory, %text);

my $GAMES_URL = 'https://raw.githubusercontent.com/GameServerManagers/LinuxGSM/master/lgsm/data/serverlist.csv';
my $CACHE_TTL = 86400; # 24 hours in seconds

# Return list of all supported LGSM games.
# Uses cached CSV if fresh, otherwise fetches from GitHub.
# Each entry: {shortname, script, name, os}
sub get_game_list {
    my $cache = _cache_path();
    if (-f $cache && (-M $cache) * 86400 < $CACHE_TTL) {
        return _parse_csv(_read_cache($cache));
    }
    return refresh_game_list();
}

# Force re-fetch of the game list from GitHub.
sub refresh_game_list {
    my $content = _fetch_csv();
    if ($content) {
        _write_cache($content);
        return _parse_csv($content);
    }
    # Fallback: use stale cache if available
    my $cache = _cache_path();
    if (-f $cache) {
        return _parse_csv(_read_cache($cache));
    }
    &error($text{'games_fetch_error'});
}

sub _fetch_csv {
    my $content;
    eval {
        require LWP::Simple;
        $content = LWP::Simple::get($GAMES_URL);
    };
    if (!$content) {
        my $url = $GAMES_URL;
        $content = `curl -sf --max-time 10 '$url' 2>/dev/null`;
    }
    return $content || undef;
}

sub _parse_csv {
    my ($content) = @_;
    my @games;
    my $first = 1;
    for my $line (split /\n/, $content) {
        chomp $line;
        if ($first) { $first = 0; next; }   # skip header
        next unless $line =~ /\S/;
        my ($shortname, $script, $name, $os) = split /,/, $line, 4;
        next unless $shortname && $name;
        push @games, {
            shortname => $shortname,
            script    => $script // '',
            name      => $name,
            os        => $os // '',
        };
    }
    return sort { $a->{'name'} cmp $b->{'name'} } @games;
}

sub _cache_path {
    my $base = $module_root || $module_root_directory;
    if (!$base) {
        ($base = __FILE__) =~ s{/lib/games\.pl$}{};
    }
    my $dir = "$base/data";
    mkdir $dir unless -d $dir;
    return "$dir/serverlist.csv";
}

sub _read_cache {
    my ($path) = @_;
    open(my $fh, '<', $path) or return '';
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

sub _write_cache {
    my ($content) = @_;
    my $path = _cache_path();
    open(my $fh, '>', $path) or return;
    print $fh $content;
    close $fh;
}

1;
