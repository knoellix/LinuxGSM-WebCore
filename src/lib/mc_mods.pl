# LinuxGSM-WebCore — Minecraft mod API helpers, env filter, download whitelist
use strict;
use warnings;

our (%config, $module_root);

sub curseforge_api_key {
    our %config;
    my $key = $config{'curseforge_api_key'} // '';
    $key =~ s/[\t\n\r]//g;
    $key =~ s/^\s+|\s+$//g;
    $key =~ s/^["']+|["']+$//g;
    return $key;
}

# Hosts allowed for mod/modpack downloads (fixed + optional custom from config).
sub mc_download_default_hosts {
    return qw(
        cdn.modrinth.com
        api.modrinth.com
        edge.forgecdn.net
        mediafilez.forgecdn.net
        modfilez.forgecdn.net
        api.curseforge.com
        hangar.papermc.io
        api.adoptium.net
        github.com
        raw.githubusercontent.com
    );
}

sub mc_download_custom_hosts {
    my $raw = $config{'download_custom_hosts'} // '';
    $raw =~ s/[\t\n\r]//g;
    return grep { length $_ } split /\s*,\s*/, $raw;
}

sub mc_download_url_normalize {
    my ($url) = @_;
    return undef unless defined $url && $url =~ /\S/;
    $url =~ s/[\t\n\r]//g;
    # CurseForge CDN links are sometimes http:// — upgrade before curl/download checks.
    if ($url =~ m{\Ahttp://}i && $url =~ /forgecdn\.net/i) {
        $url =~ s{\Ahttp://}{https://}i;
    }
    return $url if $url =~ m{\Ahttps://}i;
    return undef;
}

sub mc_download_url_allowed {
    my ($url) = @_;
    $url = mc_download_url_normalize($url);
    return 0 unless defined $url;
    my ($host) = $url =~ m{\Ahttps://([^/:]+)}i;
    return 0 unless defined $host && $host ne '';
    $host = lc($host);
    for my $h (mc_download_default_hosts(), mc_download_custom_hosts()) {
        $h = lc($h);
        return 1 if $host eq $h || $host =~ /\.\Q$h\E\z/;
    }
    return 1 if &module_config_bool($config{'download_allow_custom_url'});
    return 0;
}

# Download URL to path; adds CurseForge API key for forgecdn hosts when configured.
sub mc_download_url_to_file {
    my ($url, $path, $max_time) = @_;
    $url = mc_download_url_normalize($url);
    return 0 unless defined $url && defined $path;
    $max_time = 900 unless defined $max_time && $max_time =~ /^\d+$/;
    my $host = mc_download_url_host($url) // '';
    if ($host ne '' && mc_download_url_host_is_ip($host)) {
        print "curl refused: download URL uses raw IP ($host) — check DNS/firewall\n";
        return 0;
    }
    my @cmd = (
        'curl', '-fsSL',
        '--connect-timeout', '30',
        '--max-time', "$max_time",
        '--proto-redir', '=https',
        '-o', $path,
    );
    if ($url =~ /forgecdn\.net/i) {
        my $key = curseforge_api_key();
        push @cmd, '-H', "x-api-key: $key" if $key =~ /\S/;
    }
    push @cmd, $url;
    my $ok;
    for my $attempt (0 .. 3) {
        system(@cmd);
        $ok = ($? == 0 && -f $path && -s $path);
        last if $ok;
        my $exit = $? >> 8;
        last if $exit != 22 || $attempt >= 3;
        sleep(1 + $attempt * 2);
    }
    if (!$ok) {
        my $host = mc_download_url_host($url) // '?';
        print "curl failed for host $host (exit=$?)\n";
    }
    return $ok ? 1 : 0;
}

sub mc_download_url_host {
    my ($url) = @_;
    $url = mc_download_url_normalize($url);
    return undef unless defined $url;
    my ($host) = $url =~ m{\Ahttps://([^/:]+)}i;
    return $host;
}

sub mc_download_url_host_is_ip {
    my ($host) = @_;
    return 0 unless defined $host && $host ne '';
    return $host =~ /^\d{1,3}(?:\.\d{1,3}){3}$/ ? 1 : 0;
}

# CurseForge mod file download via API URL + CDN (returns ok, err_code).
sub curseforge_download_file_to_path {
    my ($project_id, $file_id, $path, $max_time) = @_;
    $project_id =~ s/\D//g if defined $project_id;
    $file_id    =~ s/\D//g if defined $file_id;
    return (0, 'invalid') unless $project_id && $file_id && defined $path;
    my $key = curseforge_api_key();
    return (0, 'curseforge_key_missing') unless $key =~ /\S/;
    my $rec = curseforge_fetch_file_record($project_id, $file_id, $key, 120);
    my $url = ref($rec) eq 'HASH' ? ($rec->{'url'} // '') : '';
    my $err = ref($rec) eq 'HASH' ? ($rec->{'err'} // 'no_url') : 'api_failed';
    return (0, $err) unless $url;
    my $host = mc_download_url_host($url) // '?';
    print "CF download: project=$project_id file=$file_id host=$host\n";
    if (mc_download_url_host_is_ip($host)) {
        print "ERROR: CurseForge CDN URL uses raw IP ($host) — check DNS/firewall\n";
        return (0, 'invalid_cdn_url');
    }
    mc_download_url_to_file($url, $path, $max_time // 600)
        ? (1, undef)
        : (0, 'download_failed');
}

our %curseforge_file_cache;

sub _curseforge_disk_cache_dir {
    unless (defined &module_config_dir_path) {
        if (defined $module_root && $module_root =~ /\S/) {
            my $mp = "$module_root/lib/module_config.pl";
            eval { require $mp } if -f $mp; ## no critic
        }
    }
    my $base = eval { module_config_dir_path() } // '';
    return '' unless defined $base && $base =~ /\S/;
    my $dir = "$base/cf_file_cache";
    if (!-d $dir) {
        mkdir($dir, 0700) or return '';
    }
    return $dir;
}

sub _curseforge_disk_cache_path {
    my ($project_id, $file_id) = @_;
    my $dir = _curseforge_disk_cache_dir();
    return '' unless $dir;
    return "$dir/${project_id}_${file_id}.json";
}

sub _curseforge_load_disk_cache {
    my ($project_id, $file_id) = @_;
    my $path = _curseforge_disk_cache_path($project_id, $file_id);
    return undef unless $path && -f $path;
    return undef if -M $path > 14;
    require JSON::PP;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $raw = <$fh> // '';
    close($fh);
    my $rec = eval { JSON::PP::decode_json($raw) };
    return undef unless ref($rec) eq 'HASH';
    return $rec if defined $rec->{'url'} && $rec->{'url'} =~ /\S/;
    return undef;
}

sub _curseforge_save_disk_cache {
    my ($project_id, $file_id, $rec) = @_;
    return 0 unless ref($rec) eq 'HASH';
    my $path = _curseforge_disk_cache_path($project_id, $file_id);
    return 0 unless $path;
    require JSON::PP;
    my $json = JSON::PP::encode_json($rec);
    my $tmp = "$path.$$.tmp";
    open(my $fh, '>', $tmp) or return 0;
    print $fh $json or do { unlink($tmp); return 0; };
    close($fh) or do { unlink($tmp); return 0; };
    if (!rename($tmp, $path)) {
        unlink($path) if -e $path;
        rename($tmp, $path) or do { unlink($tmp); return 0; };
    }
    chmod(0600, $path) if -f $path;
    return 1;
}

# Cached CurseForge file meta + download URL (1–2 API calls, reused for resolve + download).
sub curseforge_fetch_file_record {
    my ($project_id, $file_id, $api_key, $max_time) = @_;
    $project_id =~ s/\D//g;
    $file_id    =~ s/\D//g;
    return { err => 'invalid' } unless $project_id && $file_id && defined $api_key && $api_key =~ /\S/;
    $max_time = 60 unless defined $max_time && $max_time =~ /^\d+$/;
    my $cache_key = "$project_id:$file_id";
    if (exists $curseforge_file_cache{$cache_key}) {
        return { %{ $curseforge_file_cache{$cache_key} }, from_cache => 1 };
    }

    my $disk = _curseforge_load_disk_cache($project_id, $file_id);
    if (ref($disk) eq 'HASH') {
        $curseforge_file_cache{$cache_key} = $disk;
        return { %$disk, from_cache => 1 };
    }

    my $headers = { 'x-api-key' => $api_key, 'Accept' => 'application/json' };
    my $meta_url = "https://api.curseforge.com/v1/mods/$project_id/files/$file_id";
    my $meta_resp = _mc_mods_http_get_json($meta_url, $headers, $max_time);
    my $meta = (ref($meta_resp) eq 'HASH' && ref($meta_resp->{'data'}) eq 'HASH')
        ? $meta_resp->{'data'} : undef;

    my $url = curseforge_extract_download_url($meta);
    if (!defined $url && ref($meta) eq 'HASH') {
        $url = curseforge_build_forgecdn_url(
            $project_id, $file_id, $meta->{'fileName'});
    }
    my $dl_resp;
    if (!defined $url) {
        my $dl_api = "https://api.curseforge.com/v1/mods/$project_id/files/$file_id/download-url";
        $dl_resp = _mc_mods_http_get_json($dl_api, $headers, $max_time);
        $url = curseforge_extract_download_url($dl_resp->{'data'}) if ref($dl_resp) eq 'HASH';
    }

    my $err;
    if (!defined $url) {
        if (!$meta) {
            $err = 'rate_limited';
        } elsif (!ref($dl_resp)) {
            # Meta fetched but download-url API failed (403/429 rate limit).
            $err = 'rate_limited';
        } else {
            $err = 'no_url';
        }
    } else {
        my $host = mc_download_url_host($url) // '';
        if ($host ne '' && mc_download_url_host_is_ip($host)) {
            $url = undef;
            $err = 'invalid_cdn_url';
        } elsif (!mc_download_url_allowed($url)) {
            $url = undef;
            $err = 'host_blocked';
        }
    }

    my $rec = { url => $url, meta => $meta, err => $err, from_cache => 0 };
    if (defined $url && $url =~ /\S/) {
        my %store = %$rec;
        delete $store{from_cache};
        $curseforge_file_cache{$cache_key} = \%store;
        _curseforge_save_disk_cache($project_id, $file_id, \%store);
    }
    return $rec;
}

sub curseforge_clear_file_cache {
    %curseforge_file_cache = ();
    return 1;
}

sub modrinth_user_agent {
    my $contact = $config{'modrinth_contact'} // '';
    $contact =~ s/[\t\n\r]//g;
    $contact = substr($contact, 0, 200);
    return $contact if $contact =~ /\S/;
    return 'LinuxGSM-WebCore/0.1 (set modrinth_contact in Integrations)';
}

# Map Modrinth env block to internal: server | client | both | unknown
sub normalize_mod_env {
    my ($env) = @_;
    return 'unknown' unless ref($env) eq 'HASH';
    my $norm = sub {
        my ($v) = @_;
        return 'unsupported' unless defined $v;
        $v = lc($v);
        return 'required'  if $v eq 'required';
        return 'optional'  if $v eq 'optional';
        return 'unsupported' if $v eq 'unsupported';
        return 'unknown';
    };
    my $s = $norm->($env->{'server'});
    my $c = $norm->($env->{'client'});
    return 'server' if $s eq 'required' && ($c eq 'unsupported' || $c eq 'unknown');
    return 'client' if $c eq 'required' && ($s eq 'unsupported' || $s eq 'unknown');
    return 'both'   if ($s eq 'required' || $s eq 'optional')
                    && ($c eq 'required' || $c eq 'optional');
    return 'server' if $s eq 'required' || $s eq 'optional';
    return 'client' if $c eq 'required' || $c eq 'optional';
    return 'unknown';
}

# target: server | client | export_server | export_client | import_server
# import_server: allow unknown (CurseForge has no reliable per-file env; FTB etc.
# must still install). Only explicit client is blocked.
sub mod_env_allowed {
    my ($env, $target) = @_;
    $env    //= 'unknown';
    $target //= 'server';
    $env    =~ s/[^a-z]//g;
    $target =~ s/[^a-z_]//g;
    if ($target eq 'server' || $target eq 'import_server') {
        return 1 if $env eq 'server' || $env eq 'both' || $env eq 'unknown';
        return 0 if $env eq 'client';
        return 0;
    }
    if ($target eq 'export_server') {
        return 1 if $env eq 'server' || $env eq 'both';
        return 0;
    }
    if ($target eq 'export_client' || $target eq 'client') {
        return 1 if $env eq 'both';
        return 0;
    }
    return 0;
}

# Modrinth loader dependency key → internal loader name
sub modrinth_dep_to_loader {
    my ($deps) = @_;
    return undef unless ref($deps) eq 'HASH';
    return 'fabric'   if exists $deps->{'fabric-loader'} || exists $deps->{'fabric'};
    return 'neoforge' if exists $deps->{'neoforge'};
    return 'forge'    if exists $deps->{'forge'};
    return 'quilt'    if exists $deps->{'quilt-loader'};
    return undef;
}

sub modrinth_dep_mc_version {
    my ($deps) = @_;
    return undef unless ref($deps) eq 'HASH';
    my $v = $deps->{'minecraft'} // $deps->{'minecraft-version'};
    return $v if defined $v && $v =~ /^[0-9.]+$/;
    return undef;
}

# Internal loader → Modrinth loader slug for search API
sub mc_loader_modrinth_slug {
    my ($loader) = @_;
    my %map = (
        fabric   => 'fabric',
        forge    => 'forge',
        neoforge => 'neoforge',
        quilt    => 'quilt',
    );
    return $map{$loader // ''};
}

sub mc_mods_index_path {
    my ($server_dir) = @_;
    return "$server_dir/.mc_mods_index.json";
}

sub read_mc_mods_index {
    my ($server_dir) = @_;
    my $path = mc_mods_index_path($server_dir);
    return {} unless -f $path;
    open(my $fh, '<', $path) or return {};
    local $/;
    my $raw = <$fh>;
    close($fh);
    my $data;
    eval {
        require JSON::PP;
        $data = JSON::PP::decode_json($raw);
        1;
    } or return {};
    return ref($data) eq 'HASH' ? $data : {};
}

sub write_mc_mods_index {
    my ($server_dir, $index_ref) = @_;
    return 0 unless ref($index_ref) eq 'HASH';
    require JSON::PP;
    my $json = JSON::PP::encode_json($index_ref);
    my $path = mc_mods_index_path($server_dir);
    open(my $fh, '>', $path) or return 0;
    print $fh $json;
    close($fh);
    return 1;
}

sub _mc_mods_sanitize_mod_dir {
    my ($mod_dir) = @_;
    $mod_dir //= 'mods';
    $mod_dir =~ s/[^a-zA-Z0-9_-]//g;
    return $mod_dir if $mod_dir =~ /\S/;
    return 'mods';
}

sub mod_basename_sanitize {
    my ($name) = @_;
    return '' unless defined $name && $name =~ /\S/;
    $name =~ s/[\t\n\r\0]//g;
    $name =~ s/^\s+|\s+$//g;
    return '' if $name =~ /\// || $name =~ /\.\./;
    $name =~ s/\.disabled\z//i;
    return '' unless $name =~ /\A[\w.\-]+\.jar\z/;
    return $name;
}

sub mod_file_paths {
    my ($server_dir, $mod_dir, $basename) = @_;
    $basename = mod_basename_sanitize($basename // '');
    return (undef, undef) unless $basename;
    $mod_dir = _mc_mods_sanitize_mod_dir($mod_dir);
    $server_dir =~ s{/\z}{};
    my $base = "$server_dir/serverfiles/$mod_dir";
    return ("$base/$basename", "$base/$basename.disabled");
}

sub _mc_mods_realpath {
    my ($path) = @_;
    return undef unless defined $path && $path ne '';
    require Cwd;
    return Cwd::realpath($path);
}

sub _mc_mods_path_under_root {
    my ($resolved, $root) = @_;
    return 0 unless defined $resolved && $resolved ne '';
    return 0 unless defined $root && $root ne '';
    my $base = _mc_mods_realpath($root) // $root;
    $base =~ s{/\z}{};
    return 1 if $resolved eq $base;
    return 1 if index($resolved, "$base/") == 0;
    return 0;
}

sub mod_validate_under_mod_dir {
    my ($server_dir, $mod_dir, $abs_path) = @_;
    return 0 unless defined $abs_path && $abs_path ne '';
    return 0 if $abs_path =~ /\.\./;
    $mod_dir = _mc_mods_sanitize_mod_dir($mod_dir);
    $server_dir =~ s{/\z}{};
    my $root = "$server_dir/serverfiles/$mod_dir";
    my $resolved = _mc_mods_realpath($abs_path);
    return 0 unless defined $resolved && $resolved ne '';
    return _mc_mods_path_under_root($resolved, $root) ? 1 : 0;
}

sub _mc_mods_index_entry_has_update_meta {
    my ($source, $rec) = @_;
    return 0 unless defined $source && $source =~ /\S/;
    return 0 unless ref($rec) eq 'HASH';
    if ($source eq 'modrinth') {
        my $pid = $rec->{'modrinth_project'} // $rec->{'project_id'} // '';
        return ($pid =~ /\S/) ? 1 : 0;
    }
    if ($source eq 'curseforge') {
        my $pid = $rec->{'project_id'} // '';
        return ($pid =~ /\S/) ? 1 : 0;
    }
    if ($source eq 'hangar') {
        my $owner = $rec->{'hangar_owner'} // '';
        my $slug = $rec->{'hangar_slug'} // '';
        return ($owner =~ /\S/ && $slug =~ /\S/) ? 1 : 0;
    }
    return 0;
}

sub _mc_mods_index_entry_fields {
    my ($rec, $basename) = @_;
    $rec = {} unless ref($rec) eq 'HASH';
    my $source = $rec->{'source'} // '';
    my %out = (
        title           => $rec->{'title'} // $basename,
        source          => $source,
        project_id      => '',
        version_id      => '',
        file_id         => $rec->{'file_id'} // '',
        hangar_owner    => $rec->{'hangar_owner'} // '',
        hangar_slug     => $rec->{'hangar_slug'} // '',
        has_update_meta => _mc_mods_index_entry_has_update_meta($source, $rec),
    );
    if ($source eq 'modrinth') {
        $out{'project_id'} = $rec->{'modrinth_project'} // $rec->{'project_id'} // '';
        $out{'version_id'} = $rec->{'modrinth_version'} // $rec->{'version_id'} // '';
    } elsif ($source eq 'curseforge') {
        $out{'project_id'} = $rec->{'project_id'} // '';
        $out{'version_id'} = $rec->{'version_id'} // '';
    } elsif ($source eq 'hangar') {
        $out{'version_id'} = $rec->{'version_id'} // '';
    }
    return \%out;
}

sub list_installed_mods {
    my ($server_dir, $profile) = @_;
    return [] unless defined $server_dir && $server_dir ne '';
    return [] unless ref($profile) eq 'HASH';
    my $mod_dir = _mc_mods_sanitize_mod_dir($profile->{'mod_dir'} // 'mods');
    $server_dir =~ s{/\z}{};
    my $scan_dir = "$server_dir/serverfiles/$mod_dir";
    return [] unless -d $scan_dir;
    my $index = read_mc_mods_index($server_dir);
    opendir(my $dh, $scan_dir) or return [];
    my @mods;
    while (my $entry = readdir($dh)) {
        next if $entry eq '.' || $entry eq '..';
        next if $entry =~ /\A\./;
        my $full = "$scan_dir/$entry";
        next unless -f $full;
        my ($enabled, $filename_on_disk, $basename);
        if ($entry =~ /\A(.+\.jar)\.disabled\z/i) {
            $basename = mod_basename_sanitize($1);
            next unless $basename;
            $enabled = 0;
            $filename_on_disk = $entry;
        } elsif ($entry =~ /\A(.+\.jar)\z/i) {
            $basename = mod_basename_sanitize($1);
            next unless $basename;
            $enabled = 1;
            $filename_on_disk = $entry;
        } else {
            next;
        }
        my $idx_key = "$mod_dir/$basename";
        my $fields = _mc_mods_index_entry_fields($index->{$idx_key}, $basename);
        push @mods, {
            basename          => $basename,
            enabled           => $enabled ? 1 : 0,
            filename_on_disk  => $filename_on_disk,
            %$fields,
        };
    }
    closedir($dh);
    @mods = sort { lc($a->{'basename'}) cmp lc($b->{'basename'}) } @mods;
    return \@mods;
}

sub _mc_mods_display_name {
    my ($mod) = @_;
    return '' unless ref($mod) eq 'HASH';
    my $title = $mod->{'title'} // '';
    return $title if $title =~ /\S/;
    return $mod->{'basename'} // '';
}

sub filter_installed_mods {
    my ($mods, $opts) = @_;
    $mods = [] unless ref($mods) eq 'ARRAY';
    $opts = {} unless ref($opts) eq 'HASH';
    my @out = @$mods;

    my $status = lc($opts->{'status'} // 'all');
    $status = 'all' unless $status =~ /\A(?:all|enabled|disabled)\z/;
    if ($status eq 'enabled') {
        @out = grep { ref($_) eq 'HASH' && ($_->{'enabled'} // 0) } @out;
    } elsif ($status eq 'disabled') {
        @out = grep { ref($_) eq 'HASH' && !($_->{'enabled'} // 0) } @out;
    }

    my $q = $opts->{'q'} // '';
    $q =~ s/[\t\n\r\0]//g;
    $q =~ s/^\s+|\s+$//g;
    if ($q ne '') {
        my $ql = lc($q);
        @out = grep {
            ref($_) eq 'HASH' && do {
                my $name = lc(_mc_mods_display_name($_));
                my $base = lc($_->{'basename'} // '');
                index($name, $ql) >= 0 || index($base, $ql) >= 0;
            };
        } @out;
    }

    return \@out;
}

sub sort_installed_mods {
    my ($mods, $key, $dir) = @_;
    $mods = [] unless ref($mods) eq 'ARRAY';
    $key = lc($key // 'name');
    $key = 'name' unless $key =~ /\A(?:name|status)\z/;
    $dir = lc($dir // 'asc');
    $dir = 'asc' unless $dir =~ /\A(?:asc|desc)\z/;
    my @sorted = @$mods;
    my $cmp = sub {
        my ($a, $b) = @_;
        return 0 unless ref($a) eq 'HASH' && ref($b) eq 'HASH';
        my $r;
        if ($key eq 'status') {
            my $ea = ($a->{'enabled'} // 0) ? 1 : 0;
            my $eb = ($b->{'enabled'} // 0) ? 1 : 0;
            $r = $ea <=> $eb;
            $r = lc($a->{'basename'} // '') cmp lc($b->{'basename'} // '') if $r == 0;
        } else {
            $r = lc(_mc_mods_display_name($a)) cmp lc(_mc_mods_display_name($b));
            $r = lc($a->{'basename'} // '') cmp lc($b->{'basename'} // '') if $r == 0;
        }
        return $dir eq 'desc' ? -$r : $r;
    };
    @sorted = sort { $cmp->($a, $b) } @sorted;
    return \@sorted;
}

sub paginate_installed_mods {
    my ($mods, $page, $per_page) = @_;
    $mods = [] unless ref($mods) eq 'ARRAY';
    $per_page = 50 unless defined $per_page && $per_page =~ /^\d+$/ && $per_page > 0;
    my $total = scalar @$mods;
    my $pages = $total > 0 ? int(($total + $per_page - 1) / $per_page) : 1;
    $pages = 1 if $pages < 1;
    $page = 1 unless defined $page && $page =~ /^\d+$/ && $page > 0;
    $page = $pages if $page > $pages;
    my $start = ($page - 1) * $per_page;
    my @slice;
    if ($total && $start <= $#$mods) {
        my $last = $start + $per_page - 1;
        $last = $#$mods if $last > $#$mods;
        @slice = @{$mods}[$start .. $last];
    }
    return (\@slice, $total, $pages);
}

sub _mc_mods_direct_as_user {
    my ($unix_user) = @_;
    return 1 if !defined $unix_user || $unix_user eq '';
    my $uid = (getpwnam($unix_user))[2];
    return 1 if defined $uid && $> == $uid;
    return 0;
}

sub _mc_mods_mv_as_user {
    my ($unix_user, $src, $dst) = @_;
    if (_mc_mods_direct_as_user($unix_user)) {
        return rename($src, $dst) ? 1 : 0;
    }
    (my $safe_src = $src) =~ s/'/'\\''/g;
    (my $safe_dst = $dst) =~ s/'/'\\''/g;
    system('su', '-s', '/bin/bash', '-c', "mv '$safe_src' '$safe_dst'", $unix_user);
    return $? == 0 ? 1 : 0;
}

sub _mc_mods_rm_as_user {
    my ($unix_user, @paths) = @_;
    @paths = grep { defined $_ && $_ ne '' && -e $_ } @paths;
    return 1 unless @paths;
    if (_mc_mods_direct_as_user($unix_user)) {
        my $ok = 1;
        for my $p (@paths) {
            $ok = 0 unless unlink($p);
        }
        return $ok;
    }
    my @quoted;
    for my $p (@paths) {
        (my $safe = $p) =~ s/'/'\\''/g;
        push @quoted, "'$safe'";
    }
    system('su', '-s', '/bin/bash', '-c', 'rm -f ' . join(' ', @quoted), $unix_user);
    return $? == 0 ? 1 : 0;
}

sub _mc_mods_write_text_as_user {
    my ($unix_user, $path, $content) = @_;
    if (_mc_mods_direct_as_user($unix_user)) {
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

sub mod_set_enabled {
    my ($server_dir, $unix_user, $mod_dir, $basename, $want_enabled) = @_;
    $basename = mod_basename_sanitize($basename // '');
    return (0, 'invalid') unless $basename;
    my ($en_path, $dis_path) = mod_file_paths($server_dir, $mod_dir, $basename);
    return (0, 'invalid') unless defined $en_path && defined $dis_path;
    for my $p ($en_path, $dis_path) {
        return (0, 'outside') unless mod_validate_under_mod_dir($server_dir, $mod_dir, $p);
    }

    if ($want_enabled) {
        return (1, undef) if -f $en_path && !-f $dis_path;
        return (0, 'missing') unless -f $dis_path;
        return (0, 'rename_failed') unless _mc_mods_mv_as_user($unix_user, $dis_path, $en_path);
        return (0, 'verify_failed') unless -f $en_path && !-f $dis_path;
        return (1, undef);
    }

    return (1, undef) if -f $dis_path && !-f $en_path;
    return (0, 'missing') unless -f $en_path;
    return (0, 'rename_failed') unless _mc_mods_mv_as_user($unix_user, $en_path, $dis_path);
    return (0, 'verify_failed') unless -f $dis_path && !-f $en_path;
    return (1, undef);
}

sub mod_delete_installed {
    my ($server_dir, $unix_user, $mod_dir, $basename) = @_;
    $basename = mod_basename_sanitize($basename // '');
    return (0, 'invalid') unless $basename;
    my ($en_path, $dis_path) = mod_file_paths($server_dir, $mod_dir, $basename);
    return (0, 'invalid') unless defined $en_path && defined $dis_path;
    for my $p ($en_path, $dis_path) {
        return (0, 'outside') unless mod_validate_under_mod_dir($server_dir, $mod_dir, $p);
    }

    return (0, 'missing') unless -f $en_path || -f $dis_path;
    return (0, 'rename_failed') unless _mc_mods_rm_as_user($unix_user, $en_path, $dis_path);
    return (0, 'verify_failed') if -e $en_path || -e $dis_path;

    $mod_dir = _mc_mods_sanitize_mod_dir($mod_dir);
    my $idx_key = "$mod_dir/$basename";
    my $index = read_mc_mods_index($server_dir);
    if (exists $index->{$idx_key}) {
        delete $index->{$idx_key};
        require JSON::PP;
        my $json = JSON::PP::encode_json($index);
        my $idx_path = mc_mods_index_path($server_dir);
        return (0, 'rename_failed') unless _mc_mods_write_text_as_user($unix_user, $idx_path, $json);
    }
    return (1, undef);
}

sub _mc_mods_urlencode {
    my ($s) = @_;
    $s //= '';
    $s =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge;
    return $s;
}

sub _mc_mods_http_get_json {
    my ($url, $headers, $max_time) = @_;
    $headers //= {};
    $max_time = 60 unless defined $max_time && $max_time =~ /^\d+$/;
    my @cmd = ('curl', '-fsSL', '--connect-timeout', '30', '--max-time', "$max_time");
    for my $k (keys %$headers) {
        push @cmd, '-H', "$k: $headers->{$k}";
    }
    push @cmd, $url;
    my ($out, $ok, $exit);
    for my $attempt (0 .. 2) {
        my $shell = join(' ', map {
            my $a = $_;
            $a =~ s/'/'\\''/g;
            "'$a'"
        } @cmd) . ' 2>/dev/null';
        open(my $fh, '-|', 'bash', '-c', $shell) or return undef;
        local $/;
        $out = <$fh> // '';
        close($fh);
        $ok   = ($? == 0);
        $exit = $? >> 8;
        last if $ok;
        last if $exit != 22 || $attempt >= 2;
        my $wait = $attempt == 0 ? 5 : ($attempt == 1 ? 45 : 90);
        sleep($wait);
    }
    return undef unless $ok;
    my $data;
    eval {
        require JSON::PP;
        $data = JSON::PP::decode_json($out);
    };
    return $@ ? undef : $data;
}

sub _modrinth_side_env {
    my ($server_side, $client_side) = @_;
    return normalize_mod_env({
        server => $server_side // 'unknown',
        client => $client_side // 'unknown',
    });
}

sub _modrinth_hit_server_visible {
    my ($hit) = @_;
    return 0 unless ref($hit) eq 'HASH';
    my $env = _modrinth_side_env($hit->{'server_side'}, $hit->{'client_side'});
    return mod_env_allowed($env, 'import_server');
}

# Modrinth version files use singular "url"; older docs mention "urls" / "downloads".
sub _modrinth_file_download_url {
    my ($f) = @_;
    return undef unless ref($f) eq 'HASH';
    if (my $u = $f->{'url'}) {
        return $u if mc_download_url_allowed($u);
    }
    for my $u (@{ $f->{'urls'} // $f->{'downloads'} // [] }) {
        return $u if defined $u && mc_download_url_allowed($u);
    }
    return undef;
}

sub curseforge_mod_loader_type {
    my ($loader) = @_;
    my %map = (
        forge    => 1,
        fabric   => 4,
        quilt    => 5,
        neoforge => 6,
    );
    return $map{$loader // ''};
}

sub _curseforge_api_headers {
    my $key = curseforge_api_key();
    return undef unless $key =~ /\S/;
    return {
        'x-api-key' => $key,
        'Accept'    => 'application/json',
    };
}

sub curseforge_extract_download_url {
    my ($data) = @_;
    return undef unless defined $data;
    if (!ref($data) && $data =~ m{\Ahttps?://}i) {
        return mc_download_url_normalize($data);
    }
    if (ref($data) eq 'HASH') {
        my $u = $data->{'downloadUrl'} // $data->{'url'};
        return mc_download_url_normalize($u) if defined $u && $u =~ m{\Ahttps?://}i;
    }
    return undef;
}

# CurseForge CDN path when meta.downloadUrl is null (avoids extra /download-url API call).
sub curseforge_forgecdn_path_id {
    my ($project_id) = @_;
    $project_id =~ s/\D//g;
    return 0 unless $project_id;
    return int($project_id / 100);
}

sub curseforge_build_forgecdn_url {
    my ($project_id, $file_id, $file_name) = @_;
    $project_id =~ s/\D//g;
    $file_id    =~ s/\D//g;
    return undef unless $project_id && $file_id;
    $file_name //= '';
    $file_name =~ s/[\x00-\x1f\x7f]//g;
    return undef unless $file_name =~ /\S/;
    my $path_id = curseforge_forgecdn_path_id($project_id);
    my $enc = $file_name;
    $enc =~ s/([^A-Za-z0-9._\-~])/sprintf('%%%02X', ord($1))/ge;
    my $url = "https://edge.forgecdn.net/files/$path_id/$file_id/$enc";
    return mc_download_url_allowed($url) ? mc_download_url_normalize($url) : undef;
}

sub mc_hash_value_is_sha1 {
    my ($v) = @_;
    return defined $v && $v =~ /^[0-9a-f]{40}$/i ? 1 : 0;
}

sub mc_hash_value_is_sha512 {
    my ($v) = @_;
    return defined $v && $v =~ /^[0-9a-f]{128}$/i ? 1 : 0;
}

# CurseForge API: hashes are [{ value, algo }] (algo 1=Sha1, 2=Md5); legacy flat hash also accepted.
sub curseforge_normalize_hashes {
    my ($raw) = @_;
    my %out;
    return \%out unless defined $raw;
    if (ref($raw) eq 'HASH') {
        $out{sha1}   = $raw->{'sha1'}   if mc_hash_value_is_sha1($raw->{'sha1'});
        $out{sha512} = $raw->{'sha512'} if mc_hash_value_is_sha512($raw->{'sha512'});
        $out{md5}    = $raw->{'md5'}    if defined $raw->{'md5'}    && $raw->{'md5'}    =~ /^[0-9a-f]{32}$/i;
        return \%out;
    }
    if (ref($raw) eq 'ARRAY') {
        for my $entry (@$raw) {
            next unless ref($entry) eq 'HASH';
            my $val = $entry->{'value'} // '';
            next unless $val =~ /\S/;
            my $algo = $entry->{'algo'};
            if (defined $algo && $algo =~ /^\d+$/) {
                $out{sha1} = $val if $algo == 1 && mc_hash_value_is_sha1($val);
                $out{md5}  = $val if $algo == 2 && $val =~ /^[0-9a-f]{32}$/i;
                next;
            }
            my $name = lc($entry->{'algoName'} // $entry->{'algorithm'} // '');
            $out{sha1} = $val if $name =~ /sha\s*1/ && mc_hash_value_is_sha1($val);
            $out{md5}  = $val if $name =~ /md5/ && $val =~ /^[0-9a-f]{32}$/i;
        }
    }
    return \%out;
}

# Returns ($url, $err) — err: api_failed | no_url | host_blocked
sub curseforge_fetch_file_download_url {
    my ($project_id, $file_id, $api_key, $max_time) = @_;
    my $rec = curseforge_fetch_file_record($project_id, $file_id, $api_key, $max_time);
    return (undef, $rec->{'err'} // 'api_failed') unless ref($rec) eq 'HASH' && $rec->{'url'};
    return ($rec->{'url'}, undef);
}

sub curseforge_mod_file_download_url {
    my ($project_id, $file_id) = @_;
    my $headers = _curseforge_api_headers() or return undef;
    my ($download, $err) = curseforge_fetch_file_download_url(
        $project_id, $file_id, $headers->{'x-api-key'});
    return $download;
}

sub curseforge_mod_file_meta {
    my ($project_id, $file_id) = @_;
    my $headers = _curseforge_api_headers() or return undef;
    $project_id =~ s/\D//g;
    $file_id    =~ s/\D//g;
    return undef unless $project_id && $file_id;
    my $url = "https://api.curseforge.com/v1/mods/$project_id/files/$file_id";
    my $resp = _mc_mods_http_get_json($url, $headers);
    return undef unless ref($resp) eq 'HASH' && ref($resp->{'data'}) eq 'HASH';
    return $resp->{'data'};
}

sub modrinth_search_mods {
    my ($query, $profile) = @_;
    return () unless defined $query && $query =~ /\S/;
    return () unless ref($profile) eq 'HASH';
    my $mc = $profile->{'mc_version'} // '';
    $mc =~ s/[^0-9.]//g;
    return () unless $mc =~ /\S/;
    my @facets = (['project_type:mod'], ["versions:$mc"]);
    if (my $slug = mc_loader_modrinth_slug($profile->{'loader'} // '')) {
        push @facets, ["categories:$slug"];
    }
    require JSON::PP;
    my $facets = _mc_mods_urlencode(JSON::PP::encode_json(\@facets));
    my $q = _mc_mods_urlencode($query);
    my $url = "https://api.modrinth.com/v2/search?query=$q&limit=20&index=downloads&facets=$facets";
    my $resp = _mc_mods_http_get_json($url, {
        'User-Agent' => modrinth_user_agent(),
    });
    return () unless ref($resp) eq 'HASH' && ref($resp->{'hits'}) eq 'ARRAY';
    my @out;
    for my $hit (@{ $resp->{'hits'} }) {
        next unless ref($hit) eq 'HASH';
        next unless _modrinth_hit_server_visible($hit);
        my $file = modrinth_resolve_version_file($hit->{'project_id'} // $hit->{'slug'}, $profile);
        next unless $file;
        push @out, {
            source       => 'modrinth',
            project_id   => $hit->{'project_id'} // '',
            version_id   => $file->{'version_id'} // '',
            slug         => $hit->{'slug'} // '',
            title        => $hit->{'title'} // $hit->{'slug'} // '',
            description  => substr($hit->{'description'} // '', 0, 200),
            downloads    => $hit->{'downloads'} // 0,
            env          => $file->{'env'} // 'unknown',
            filename     => $file->{'filename'} // '',
        };
    }
    return @out;
}

sub modrinth_list_compatible_versions {
    my ($project_id, $profile) = @_;
    return [] unless defined $project_id && $project_id =~ /\S/;
    return [] unless ref($profile) eq 'HASH';
    $project_id =~ s/[^a-zA-Z0-9_-]//g;
    return [] unless $project_id;
    my $mc = $profile->{'mc_version'} // '';
    $mc =~ s/[^0-9.]//g;
    my $loader = mc_loader_modrinth_slug($profile->{'loader'} // '');
    return [] unless $mc && $loader;
    require JSON::PP;
    my $loaders = _mc_mods_urlencode(JSON::PP::encode_json([$loader]));
    my $vers    = _mc_mods_urlencode(JSON::PP::encode_json([$mc]));
    my $url = "https://api.modrinth.com/v2/project/$project_id/version"
        . "?loaders=$loaders&game_versions=$vers";
    my $list = _mc_mods_http_get_json($url, {
        'User-Agent' => modrinth_user_agent(),
    });
    return [] unless ref($list) eq 'ARRAY' && @$list;
    my @out;
    for my $ver (@$list) {
        next unless ref($ver) eq 'HASH';
        my $env = 'unknown';
        if (ref($ver->{'env'}) eq 'HASH') {
            $env = normalize_mod_env($ver->{'env'});
            next unless mod_env_allowed($env, 'import_server');
        }
        for my $f (@{ $ver->{'files'} // [] }) {
            next unless ref($f) eq 'HASH';
            next unless $f->{'primary'};
            my $dl = _modrinth_file_download_url($f);
            next unless $dl;
            my $fname = $f->{'filename'} // 'mod.jar';
            $fname =~ s/[^a-zA-Z0-9._-]//g;
            $fname = 'mod.jar' unless $fname =~ /\S/;
            push @out, {
                version_id => $ver->{'id'} // '',
                name       => $ver->{'name'} // '',
                filename   => $fname,
                download_url => $dl,
                hashes     => $f->{'hashes'} // {},
                env        => $env,
                published  => $ver->{'date_published'} // '',
            };
            last;
        }
        last if @out >= 30;
    }
    return \@out;
}

sub modrinth_resolve_version_file {
    my ($project_id, $profile) = @_;
    my $list = modrinth_list_compatible_versions($project_id, $profile);
    return undef unless ref($list) eq 'ARRAY' && @$list;
    my $ver = $list->[0];
    return undef unless ref($ver) eq 'HASH';
    return {
        version_id   => $ver->{'version_id'} // '',
        filename     => $ver->{'filename'} // 'mod.jar',
        download_url => $ver->{'download_url'},
        hashes       => $ver->{'hashes'} // {},
        env          => $ver->{'env'} // 'unknown',
    };
}

sub curseforge_list_compatible_files {
    my ($project_id, $profile) = @_;
    my $headers = _curseforge_api_headers() or return [];
    $project_id =~ s/\D//g;
    return [] unless $project_id;
    return [] unless ref($profile) eq 'HASH';
    my $mc = $profile->{'mc_version'} // '';
    $mc =~ s/[^0-9.]//g;
    my $loader_type = curseforge_mod_loader_type($profile->{'loader'} // '');
    return [] unless $mc && defined $loader_type;
    my $url = "https://api.curseforge.com/v1/mods/$project_id/files"
        . "?gameVersion=$mc&modLoaderType=$loader_type&pageSize=30";
    my $resp = _mc_mods_http_get_json($url, $headers);
    return [] unless ref($resp) eq 'HASH' && ref($resp->{'data'}) eq 'ARRAY';
    my @out;
    for my $f (@{ $resp->{'data'} }) {
        next unless ref($f) eq 'HASH';
        next if ($f->{'isServerPack'} // 0);
        my $fid = $f->{'id'};
        next unless defined $fid;
        my $dl = curseforge_mod_file_download_url($project_id, $fid);
        next unless $dl;
        my $fname = $f->{'fileName'} // 'mod.jar';
        $fname =~ s/[^a-zA-Z0-9._-]//g;
        $fname = 'mod.jar' unless $fname =~ /\S/;
        my $norm = curseforge_normalize_hashes($f->{'hashes'});
        my %hashes = ref($norm) eq 'HASH' ? %$norm : ();
        push @out, {
            file_id      => $fid,
            display_name => $f->{'displayName'} // $f->{'fileName'} // '',
            filename     => $fname,
            download_url => $dl,
            hashes       => \%hashes,
            env          => 'both',
        };
    }
    return \@out;
}

sub curseforge_resolve_mod_file {
    my ($project_id, $profile) = @_;
    my $list = curseforge_list_compatible_files($project_id, $profile);
    return undef unless ref($list) eq 'ARRAY' && @$list;
    my $f = $list->[0];
    return undef unless ref($f) eq 'HASH';
    return {
        file_id      => $f->{'file_id'},
        filename     => $f->{'filename'} // 'mod.jar',
        download_url => $f->{'download_url'},
        hashes       => $f->{'hashes'} // {},
        env          => $f->{'env'} // 'both',
    };
}

sub hangar_list_compatible_versions {
    my ($owner, $slug, $profile) = @_;
    return [] unless defined $owner && defined $slug;
    $owner =~ s/[^a-zA-Z0-9_-]//g;
    $slug  =~ s/[^a-zA-Z0-9_-]//g;
    return [] unless $owner && $slug;
    return [] unless ref($profile) eq 'HASH';
    my $mc = $profile->{'mc_version'} // '';
    $mc =~ s/[^0-9.]//g;
    return [] unless $mc;
    my $vf = _mc_mods_urlencode($mc);
    my $url = "https://hangar.papermc.io/api/v1/projects/$owner/$slug/versions"
        . "?limit=30&sort=DATE&platform=PAPER&versionFilter=$vf";
    my $resp = _mc_mods_http_get_json($url, _hangar_api_headers());
    return [] unless ref($resp) eq 'HASH' && ref($resp->{'result'}) eq 'ARRAY';
    my @out;
    for my $ver (@{ $resp->{'result'} }) {
        next unless ref($ver) eq 'HASH';
        my $downloads = $ver->{'downloads'} // {};
        my $paper = ref($downloads) eq 'HASH' ? ($downloads->{'PAPER'} // {}) : {};
        next unless ref($paper) eq 'HASH';
        my $dl = $paper->{'downloadUrl'} // $paper->{'externalUrl'} // '';
        next unless $dl && mc_download_url_allowed($dl);
        my $fname = $paper->{'fileInfo'}{'name'} // ($slug . '.jar');
        $fname =~ s/[^a-zA-Z0-9._-]//g;
        $fname = "$slug.jar" unless $fname =~ /\S/;
        push @out, {
            version_id   => $ver->{'name'} // $ver->{'id'} // '',
            name         => $ver->{'name'} // '',
            filename     => $fname,
            download_url => $dl,
            hashes       => {},
            env          => 'server',
            published    => $ver->{'createdAt'} // '',
        };
    }
    return \@out;
}

sub hangar_resolve_plugin_file {
    my ($owner, $slug, $profile, $requested_version_id) = @_;
    my $list = hangar_list_compatible_versions($owner, $slug, $profile);
    return undef unless ref($list) eq 'ARRAY' && @$list;
    my $want = $requested_version_id // '';
    $want =~ s/[\t\n\r\0]//g;
    $want =~ s/^\s+|\s+$//g;
    $want =~ s/[^a-zA-Z0-9._-]//g;
    my $want_lc = lc($want);
    my $ver = $list->[0];
    if ($want_lc ne '') {
        CANDIDATE:
        for my $cand (@$list) {
            next unless ref($cand) eq 'HASH';
            my @keys = ($cand->{'version_id'} // '', $cand->{'name'} // '');
            for my $raw (@keys) {
                my $norm = $raw;
                $norm =~ s/[\t\n\r\0]//g;
                $norm =~ s/^\s+|\s+$//g;
                $norm =~ s/[^a-zA-Z0-9._-]//g;
                next unless $norm ne '';
                if (lc($norm) eq $want_lc) {
                    $ver = $cand;
                    last CANDIDATE;
                }
            }
        }
    }
    return undef unless ref($ver) eq 'HASH';
    return {
        version_id   => $ver->{'version_id'} // '',
        filename     => $ver->{'filename'} // "$slug.jar",
        download_url => $ver->{'download_url'},
        hashes       => $ver->{'hashes'} // {},
        env          => $ver->{'env'} // 'server',
    };
}

sub curseforge_search_mods {
    my ($query, $profile) = @_;
    return () unless defined $query && $query =~ /\S/;
    return () unless ref($profile) eq 'HASH';
    my $headers = _curseforge_api_headers() or return ();
    my $mc = $profile->{'mc_version'} // '';
    $mc =~ s/[^0-9.]//g;
    my $loader_type = curseforge_mod_loader_type($profile->{'loader'} // '');
    return () unless $mc && defined $loader_type;
    my $q = _mc_mods_urlencode($query);
    my $url = "https://api.curseforge.com/v1/mods/search?gameId=432&classId=6"
        . "&pageSize=20&sortField=2&sortOrder=desc&searchFilter=$q"
        . "&gameVersion=$mc&modLoaderType=$loader_type";
    my $resp = _mc_mods_http_get_json($url, $headers);
    return () unless ref($resp) eq 'HASH' && ref($resp->{'data'}) eq 'ARRAY';
    my @out;
    for my $mod (@{ $resp->{'data'} }) {
        next unless ref($mod) eq 'HASH';
        my $pid = $mod->{'id'};
        next unless defined $pid;
        my $file = curseforge_resolve_mod_file($pid, $profile);
        next unless $file;
        push @out, {
            source      => 'curseforge',
            project_id  => $pid,
            file_id     => $file->{'file_id'},
            title       => $mod->{'name'} // '',
            description => substr($mod->{'summary'} // '', 0, 200),
            downloads   => $mod->{'downloadCount'} // 0,
            env         => $file->{'env'} // 'unknown',
            filename    => $file->{'filename'} // '',
        };
    }
    return @out;
}

sub _hangar_api_headers {
    our %config;
    my $token = $config{'hangar_api_token'} // '';
    $token =~ s/[\t\n\r]//g;
    return {} unless $token =~ /\S/;
    return { Authorization => "Bearer $token" };
}

sub hangar_search_plugins {
    my ($query, $profile) = @_;
    return () unless defined $query && $query =~ /\S/;
    return () unless ref($profile) eq 'HASH';
    return () unless ($profile->{'loader'} // '') eq 'paper';
    my $q = _mc_mods_urlencode($query);
    my $url = "https://hangar.papermc.io/api/v1/projects?q=$q&limit=15&sort=stars";
    my $resp = _mc_mods_http_get_json($url, _hangar_api_headers());
    return () unless ref($resp) eq 'HASH' && ref($resp->{'result'}) eq 'ARRAY';
    my @out;
    for my $proj (@{ $resp->{'result'} }) {
        next unless ref($proj) eq 'HASH';
        my $ns = $proj->{'namespace'} // {};
        next unless ref($ns) eq 'HASH';
        my $owner = $ns->{'owner'} // '';
        my $slug  = $ns->{'slug'} // '';
        next unless $owner =~ /\S/ && $slug =~ /\S/;
        my $file = hangar_resolve_plugin_file($owner, $slug, $profile);
        next unless $file;
        push @out, {
            source       => 'hangar',
            hangar_owner => $owner,
            hangar_slug  => $slug,
            version_id   => $file->{'version_id'} // '',
            title        => $proj->{'name'} // $slug,
            description  => substr($proj->{'description'} // '', 0, 200),
            downloads    => $proj->{'stats'}{'downloads'} // 0,
            env          => 'server',
            filename     => $file->{'filename'} // '',
        };
    }
    return @out;
}

# Unified search — returns { ok => 1, results => [...], errors => [...] }
sub mc_mod_search {
    my ($query, $profile) = @_;
    my @errors;
    my @results;
    return { ok => 0, results => [], errors => ['empty_query'] }
        unless defined $query && $query =~ /\S/;
    return { ok => 0, results => [], errors => ['missing_profile'] }
        unless ref($profile) eq 'HASH';
    my $loader = $profile->{'loader'} // '';
    if ($loader eq 'paper') {
        push @results, hangar_search_plugins($query, $profile);
    } elsif (mc_loader_modrinth_slug($loader)) {
        push @results, modrinth_search_mods($query, $profile);
        if (_curseforge_api_headers()) {
            push @results, curseforge_search_mods($query, $profile);
        } else {
            push @errors, 'curseforge_key_missing';
        }
    } else {
        return { ok => 0, results => [], errors => ['unsupported_loader'] };
    }
    @results = sort { ($b->{'downloads'} // 0) <=> ($a->{'downloads'} // 0) } @results;
    @results = @results[0 .. 29] if @results > 30;
    return { ok => 1, results => \@results, errors => \@errors };
}

sub mod_install_already_present {
    my ($server_dir, $mod_dir, $meta) = @_;
    return (0, undef) unless ref($meta) eq 'HASH';
    my $fname = $meta->{'filename'} // '';
    return (0, undef) unless $fname =~ /\S/;
    my $path = "$server_dir/serverfiles/$mod_dir/$fname";
    return (1, 'file_exists') if -f $path;
    my $idx = read_mc_mods_index($server_dir);
    my $key = "$mod_dir/$fname";
    if (exists $idx->{$key}) {
        my $rec = $idx->{$key};
        if (ref($rec) eq 'HASH') {
            if (($meta->{'source'} // '') eq 'modrinth'
                && ($rec->{'modrinth_project'} // '') eq ($meta->{'project_id'} // '')) {
                return (1, 'index_project');
            }
            if (($meta->{'source'} // '') eq 'curseforge'
                && ($rec->{'project_id'} // '') eq ($meta->{'project_id'} // '')) {
                return (1, 'index_project');
            }
            if (($meta->{'source'} // '') eq 'hangar'
                && ($rec->{'hangar_slug'} // '') eq ($meta->{'hangar_slug'} // '')) {
                return (1, 'index_project');
            }
        }
    }
    return (0, undef);
}

sub prepare_mod_install_meta {
    my ($source, $ids, $profile, $server_dir, $opts) = @_;
    return (0, undef, 'invalid') unless ref($ids) eq 'HASH' && ref($profile) eq 'HASH';
    my $force_replace = ref($opts) eq 'HASH' && ($opts->{'force_replace'} // 0);
    $source =~ s/[^a-z]//g;
    my %meta;
    if ($source eq 'modrinth') {
        my $pid = $ids->{'project_id'} // '';
        $pid =~ s/[^a-zA-Z0-9_-]//g;
        return (0, undef, 'invalid_project') unless $pid;
        my $file = modrinth_resolve_version_file($pid, $profile);
        if ($ids->{'version_id'} && $ids->{'version_id'} =~ /^[a-zA-Z0-9]+$/) {
            my $vid = $ids->{'version_id'};
            my $url = "https://api.modrinth.com/v2/version/$vid";
            my $ver = _mc_mods_http_get_json($url, {
                'User-Agent' => modrinth_user_agent(),
            });
            if (ref($ver) eq 'HASH') {
                if (ref($ver->{'env'}) eq 'HASH') {
                    my $ven = normalize_mod_env($ver->{'env'});
                    next unless mod_env_allowed($ven, 'import_server');
                }
                for my $f (@{ $ver->{'files'} // [] }) {
                    next unless ref($f) eq 'HASH' && $f->{'primary'};
                    my $dl = _modrinth_file_download_url($f);
                    next unless $dl;
                    my $fname = $f->{'filename'} // 'mod.jar';
                    $fname =~ s/[^a-zA-Z0-9._-]//g;
                    $file = {
                        version_id   => $vid,
                        filename     => $fname,
                        download_url => $dl,
                        hashes       => $f->{'hashes'} // {},
                        env          => ref($ver->{'env'}) eq 'HASH'
                            ? normalize_mod_env($ver->{'env'}) : 'unknown',
                    };
                    last;
                }
            }
        }
        return (0, undef, 'resolve_failed') unless $file;
        %meta = (
            source       => 'modrinth',
            project_id   => $pid,
            version_id   => $file->{'version_id'},
            title        => $ids->{'title'} // $pid,
            filename     => $file->{'filename'},
            download_url => $file->{'download_url'},
            hashes       => $file->{'hashes'} // {},
            env          => $file->{'env'} // 'unknown',
            mod_dir      => $profile->{'mod_dir'} // 'mods',
            server_dir   => $server_dir,
        );
    } elsif ($source eq 'curseforge') {
        my $pid = $ids->{'project_id'} // '';
        $pid =~ s/\D//g;
        return (0, undef, 'invalid_project') unless $pid;
        my $file = curseforge_resolve_mod_file($pid, $profile);
        if ($ids->{'file_id'} && $ids->{'file_id'} =~ /^\d+$/) {
            my $fid = $ids->{'file_id'};
            my $cf = curseforge_mod_file_meta($pid, $fid);
            my $dl = curseforge_mod_file_download_url($pid, $fid);
            if ($cf && $dl) {
                my $fname = $cf->{'fileName'} // 'mod.jar';
                $fname =~ s/[^a-zA-Z0-9._-]//g;
                my $norm = curseforge_normalize_hashes($cf->{'hashes'});
                my %hashes = ref($norm) eq 'HASH' ? %$norm : ();
                $file = {
                    file_id      => $fid,
                    filename     => $fname,
                    download_url => $dl,
                    hashes       => \%hashes,
                    env          => 'both',
                };
            }
        }
        return (0, undef, 'resolve_failed') unless $file;
        return (0, undef, 'curseforge_key_missing') unless _curseforge_api_headers();
        %meta = (
            source       => 'curseforge',
            project_id   => $pid,
            file_id      => $file->{'file_id'},
            title        => $ids->{'title'} // $pid,
            filename     => $file->{'filename'},
            download_url => $file->{'download_url'},
            hashes       => $file->{'hashes'} // {},
            env          => $file->{'env'} // 'unknown',
            mod_dir      => $profile->{'mod_dir'} // 'mods',
            server_dir   => $server_dir,
        );
    } elsif ($source eq 'hangar') {
        my $owner = $ids->{'hangar_owner'} // '';
        my $slug  = $ids->{'hangar_slug'} // '';
        my $vid   = $ids->{'version_id'} // '';
        $owner =~ s/[^a-zA-Z0-9_-]//g;
        $slug  =~ s/[^a-zA-Z0-9_-]//g;
        $vid   =~ s/[^a-zA-Z0-9._-]//g;
        return (0, undef, 'invalid_project') unless $owner && $slug;
        my $file = hangar_resolve_plugin_file($owner, $slug, $profile, $vid);
        return (0, undef, 'resolve_failed') unless $file;
        %meta = (
            source       => 'hangar',
            hangar_owner => $owner,
            hangar_slug  => $slug,
            version_id   => $file->{'version_id'},
            title        => $ids->{'title'} // $slug,
            filename     => $file->{'filename'},
            download_url => $file->{'download_url'},
            hashes       => $file->{'hashes'} // {},
            env          => 'server',
            mod_dir      => $profile->{'mod_dir'} // 'plugins',
            server_dir   => $server_dir,
        );
    } else {
        return (0, undef, 'invalid_source');
    }
    return (0, undef, 'url_not_allowed')
        unless mc_download_url_allowed($meta{'download_url'});
    return (0, undef, 'client_only')
        unless mod_env_allowed($meta{'env'}, 'import_server');
    unless ($force_replace) {
        my ($dup, $dup_reason) = mod_install_already_present($server_dir, $meta{'mod_dir'}, \%meta);
        return (0, undef, $dup_reason) if $dup;
    }
    return (1, \%meta, undef);
}

sub write_mod_install_job_meta {
    my ($job_dir, $meta) = @_;
    return 0 unless defined $job_dir && -d $job_dir && ref($meta) eq 'HASH';
    require JSON::PP;
    my $json = JSON::PP::encode_json($meta);
    open(my $fh, '>', "$job_dir/mod_meta.json") or return 0;
    print $fh $json;
    close($fh);
    return 1;
}

1;
