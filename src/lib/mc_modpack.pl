# LinuxGSM-WebCore — Modpack parse, validate (requires mc_mods.pl + mc_profile.pl loaded)
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);

sub _modpack_unzip_bin {
    return '/usr/bin/unzip' if -x '/usr/bin/unzip';
    return '/bin/unzip'    if -x '/bin/unzip';
    return undef;
}

sub _modpack_zip_has_member {
    my ($path, $member) = @_;
    my $unzip = _modpack_unzip_bin() or return 0;
    (my $safe = $path) =~ s/'/'\\''/g;
    (my $mem = $member) =~ s/'/'\\''/g;
    my @out = `$unzip -l '$safe' 2>/dev/null`;
    return 0 if $?;
    for my $line (@out) {
        return 1 if $line =~ /\Q$member\E/;
    }
    return 0;
}

sub _modpack_read_zip_member {
    my ($path, $member) = @_;
    my $unzip = _modpack_unzip_bin() or return undef;
    (my $safe = $path) =~ s/'/'\\''/g;
    (my $mem = $member) =~ s/'/'\\''/g;
    my $content = `$unzip -p '$safe' '$mem' 2>/dev/null`;
    return undef if $?;
    return $content;
}

# Returns: modrinth | curseforge | undef
sub detect_modpack_format {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    return 'modrinth' if $path =~ /\.mrpack\z/i;
    if ($path =~ /\.zip\z/i) {
        return 'curseforge' if _modpack_zip_has_member($path, 'manifest.json');
        return 'modrinth'   if _modpack_zip_has_member($path, 'modrinth.index.json');
    }
    return undef;
}

# Resolve path; returns undef if missing or realpath fails.
sub _modpack_realpath {
    my ($path) = @_;
    return undef unless defined $path && $path ne '';
    require Cwd;
    return Cwd::realpath($path);
}

# True when $resolved is $root or a path under $root (after realpath on root).
sub _modpack_path_under_root {
    my ($resolved, $root) = @_;
    return 0 unless defined $resolved && $resolved ne '';
    return 0 unless defined $root && $root ne '';
    my $base = _modpack_realpath($root) // $root;
    $base =~ s{/\z}{};
    return 1 if $resolved eq $base;
    return 1 if index($resolved, "$base/") == 0;
    return 0;
}

# Server-side modpack path import (manage.cgi modpack_import_path).
# Returns (ok, resolved_path, err) where err is empty|invalid|missing|outside|not_file.
sub validate_modpack_import_path {
    my ($path, $unix_user, $server_dir) = @_;
    $path //= '';
    $path =~ s/[\t\n\r\0]//g;
    $path =~ s/^\s+|\s+$//g;
    return (0, '', 'empty') unless $path =~ m{\A/};
    return (0, '', 'invalid') if $path =~ /\.\./;
    return (0, '', 'invalid') unless $path =~ /\.(mrpack|zip)\z/i;
    return (0, '', 'missing') unless -e $path;
    return (0, '', 'not_file') unless -f $path;

    my @pw = getpwnam($unix_user // '');
    my $home = (@pw && defined $pw[7] && $pw[7] ne '') ? $pw[7] : '';
    $home = "/home/$unix_user" if $home eq '' && defined $unix_user && $unix_user =~ /^[a-z][a-z0-9_-]{0,30}$/;

    my $resolved = _modpack_realpath($path);
    return (0, '', 'missing') unless defined $resolved && $resolved ne '';
    return (0, '', 'not_file') unless -f $resolved;

    my $allowed = 0;
    $allowed = 1 if $home ne '' && _modpack_path_under_root($resolved, $home);
    $allowed = 1 if !$allowed && defined $server_dir && $server_dir ne ''
        && _modpack_path_under_root($resolved, $server_dir);
    return (0, '', 'outside') unless $allowed;

    return (1, $resolved, '');
}

sub parse_modrinth_index_json {
    my ($raw) = @_;
    return undef unless defined $raw && $raw =~ /\S/;
    my $data;
    eval {
        $data = decode_json($raw);
    };
    return undef if $@ || ref($data) ne 'HASH';
    return $data;
}

sub parse_modrinth_mrpack {
    my ($path) = @_;
    my $raw = _modpack_read_zip_member($path, 'modrinth.index.json') or return undef;
    my $index = parse_modrinth_index_json($raw) or return undef;
    my @files;
    for my $f (@{ $index->{'files'} // [] }) {
        next unless ref($f) eq 'HASH';
        my $env = normalize_mod_env($f->{'env'});
        my @urls = grep { mc_download_url_allowed($_) } @{ $f->{'downloads'} // [] };
        my %entry = (
            path      => $f->{'path'} // '',
            downloads => \@urls,
            hashes    => $f->{'hashes'} // {},
            env       => $env,
            required  => 1,
        );
        if (@urls && $urls[0] =~ m{cdn\.modrinth\.com/data/([^/]+)/versions/([^/]+)/}i) {
            $entry{'modrinth_project'} = $1;
            $entry{'modrinth_version'} = $2;
        }
        push @files, \%entry;
    }
    my $deps = $index->{'dependencies'} // {};
    return {
        format         => 'modrinth',
        name           => $index->{'name'} // '',
        version_id     => $index->{'versionId'} // '',
        mc_version     => modrinth_dep_mc_version($deps),
        loader         => modrinth_dep_to_loader($deps),
        loader_version => _modrinth_loader_version($deps),
        files          => \@files,
        dependencies   => $deps,
    };
}

sub _modrinth_loader_version {
    my ($deps) = @_;
    return undef unless ref($deps) eq 'HASH';
    for my $k (qw(neoforge forge fabric-loader quilt-loader)) {
        return $deps->{$k} if defined $deps->{$k} && $deps->{$k} =~ /^[0-9.]+$/;
    }
    return undef;
}

sub parse_curseforge_manifest_json {
    my ($raw) = @_;
    return undef unless defined $raw && $raw =~ /\S/;
    my $data;
    eval {
        $data = decode_json($raw);
    };
    return undef if $@ || ref($data) ne 'HASH';
    return undef unless ($data->{'manifestType'} // '') eq 'minecraftModpack';
    return $data;
}

sub _curseforge_loader_from_id {
    my ($id) = @_;
    return undef unless defined $id && $id =~ /\S/;
    $id = lc($id);
    return 'neoforge' if $id =~ /neoforge/;
    return 'forge'    if $id =~ /forge/;
    return 'fabric'   if $id =~ /fabric/;
    return 'quilt'    if $id =~ /quilt/;
    return undef;
}

sub _parse_cf_loader_id {
    my ($id) = @_;
    return (undef, undef) unless defined $id;
    if ($id =~ /^([a-z]+)-([0-9.]+)$/i) {
        return (_curseforge_loader_from_id($1), $2);
    }
    return (_curseforge_loader_from_id($id), undef);
}

sub parse_curseforge_zip {
    my ($path) = @_;
    my $raw = _modpack_read_zip_member($path, 'manifest.json') or return undef;
    my $manifest = parse_curseforge_manifest_json($raw) or return undef;
    my $mc = $manifest->{'minecraft'} // {};
    my $loader;
    my $loader_version;
    for my $ld (@{ $mc->{'modLoaders'} // [] }) {
        next unless ref($ld) eq 'HASH';
        next unless $ld->{'primary'};
        ($loader, $loader_version) = _parse_cf_loader_id($ld->{'id'} // '');
        last;
    }
    my @files;
    for my $f (@{ $manifest->{'files'} // [] }) {
        next unless ref($f) eq 'HASH';
        my $pid = $f->{'projectID'} // $f->{'projectId'};
        my $fid = $f->{'fileID'} // $f->{'fileId'};
        next unless defined $pid && defined $fid;
        push @files, {
            project_id => $pid,
            file_id    => $fid,
            required   => ($f->{'required'} // 1) ? 1 : 0,
            # CurseForge manifest has no per-file env; listed mods are server-side.
            env        => 'server',
        };
    }
    return {
        format         => 'curseforge',
        name           => $manifest->{'name'} // '',
        version_id     => $manifest->{'version'} // '',
        mc_version     => $mc->{'version'},
        loader         => $loader,
        loader_version => $loader_version,
        overrides_dir  => $manifest->{'overrides'} // 'overrides',
        files          => \@files,
    };
}

sub parse_modpack_file {
    my ($path) = @_;
    my $fmt = detect_modpack_format($path);
    return undef unless $fmt;
    return parse_modrinth_mrpack($path) if $fmt eq 'modrinth';
    return parse_curseforge_zip($path)  if $fmt eq 'curseforge';
    return undef;
}

sub modpack_files_for_server_import {
    my ($pack) = @_;
    return ([], 0) unless ref($pack) eq 'HASH' && ref($pack->{'files'}) eq 'ARRAY';
    my @out;
    my $skipped_client = 0;
    for my $f (@{ $pack->{'files'} }) {
        my $env = $f->{'env'} // 'unknown';
        if (mod_env_allowed($env, 'import_server')) {
            push @out, $f;
        } elsif ($env eq 'client') {
            $skipped_client++;
        }
    }
    return (\@out, $skipped_client);
}

# $opts->{adopt}: pack is source of truth — loader/MC mismatches become warnings.
sub validate_modpack_against_profile {
    my ($pack, $profile, $opts) = @_;
    $opts = {} unless ref($opts) eq 'HASH';
    my $adopt = $opts->{'adopt'} ? 1 : 0;
    my @errors;
    my @warnings;
    return { ok => 0, errors => ['invalid pack'], warnings => [] }
        unless ref($pack) eq 'HASH';
    return { ok => 0, errors => ['missing profile'], warnings => [] }
        unless ref($profile) eq 'HASH';

    my $p_loader = $pack->{'loader'} // '';
    my $i_loader = $profile->{'loader'} // '';
    if ($p_loader && $i_loader && $p_loader ne $i_loader) {
        if ($adopt) {
            push @warnings, 'loader_mismatch';
        } else {
            push @errors, 'loader_mismatch';
        }
    }

    my $p_mc = $pack->{'mc_version'} // '';
    my $i_mc = $profile->{'mc_version'} // '';
    if ($p_mc && $i_mc && $p_mc ne $i_mc) {
        if ($adopt) {
            push @warnings, 'version_mismatch';
        } else {
            push @errors, 'version_mismatch';
        }
    }

    my $has_mod_files = @{ $pack->{'files'} // [] } > 0;
    if ($has_mod_files && $i_loader =~ /^(?:vanilla|paper)$/) {
        # Keep as hard error even in adopt: provisional wizard profiles for
        # modpacks should already be modded loaders; vanilla+mods is unsafe.
        push @errors, 'modded_pack_on_vanilla';
    }

    my $p_lv = $pack->{'loader_version'} // '';
    my $i_lv = $profile->{'loader_version'} // '';
    if ($p_lv && $i_lv && $p_lv ne $i_lv) {
        push @warnings, 'loader_version_mismatch';
    }

    my $need_java = resolve_java_major($p_mc || $i_mc);
    my $have_java = int($profile->{'java_major'} // 0);
    if ($need_java && $have_java && $need_java != $have_java) {
        push @warnings, 'java_mismatch';
    }

    return {
        ok       => @errors ? 0 : 1,
        errors   => \@errors,
        warnings => \@warnings,
    };
}

sub _modpack_http_get_json {
    my ($url, $headers) = @_;
    return _mc_mods_http_get_json($url, $headers, 15);
}

sub _modpack_http_get_json_import {
    my ($url, $headers) = @_;
    return _mc_mods_http_get_json($url, $headers, 60);
}

sub curseforge_file_download_url {
    my ($project_id, $file_id, $api_key) = @_;
    my ($download, $err) = curseforge_fetch_file_download_url(
        $project_id, $file_id, $api_key, 60);
    return $download;
}

# Returns ($file_hashref, $err_code, $detail_hashref)
sub _curseforge_build_modpack_file {
    my ($project_id, $file_id, $key, $filename) = @_;
    $project_id =~ s/\D//g;
    $file_id    =~ s/\D//g;
    return (undef, 'invalid_ids', { project_id => $project_id, file_id => $file_id })
        unless $project_id && $file_id && defined $key && $key =~ /\S/;
    my ($dl, $dl_err) = curseforge_fetch_file_download_url($project_id, $file_id, $key, 60);
    if ($dl_err) {
        my %detail = (project_id => $project_id, file_id => $file_id);
        if ($dl_err eq 'host_blocked' && defined $dl && $dl =~ m{\Ahttps://}i) {
            my ($host) = $dl =~ m{\Ahttps://([^/:]+)}i;
            $detail{'host'} = $host // '?';
            return (undef, 'curseforge_download_host_blocked', \%detail);
        }
        if ($dl_err eq 'no_url') {
            return (undef, 'curseforge_download_url_missing', \%detail);
        }
        return (undef, 'curseforge_api_failed', \%detail);
    }
    unless ($dl) {
        return (undef, 'curseforge_api_failed', {
            project_id => $project_id, file_id => $file_id,
        });
    }
    if (!$filename || $filename !~ /\.(?:zip|mrpack)\z/i) {
        my $meta = curseforge_file_meta($project_id, $file_id, $key);
        if (ref($meta) eq 'HASH' && ($meta->{'fileName'} // '') =~ /\S/) {
            $filename = $meta->{'fileName'};
        }
    }
    $filename //= 'pack.zip';
    $filename =~ s/[^a-zA-Z0-9._-]//g;
    $filename = 'pack.zip' unless $filename =~ /\.(?:zip|mrpack)\z/i;
    return ({
        file_id      => $file_id,
        filename     => $filename,
        download_url => $dl,
    }, undef, undef);
}

sub curseforge_file_meta {
    my ($project_id, $file_id, $api_key) = @_;
    $project_id =~ s/\D//g;
    $file_id    =~ s/\D//g;
    return undef unless $project_id && $file_id && defined $api_key && $api_key =~ /\S/;
    my $rec = curseforge_fetch_file_record($project_id, $file_id, $api_key, 60);
    return undef unless ref($rec) eq 'HASH' && ref($rec->{'meta'}) eq 'HASH';
    return $rec->{'meta'};
}

sub _curseforge_fetch_modpack_file_meta {
    my ($project_id, $profile) = @_;
    our %config;
    my $key = $config{'curseforge_api_key'} // '';
    return undef unless $key =~ /\S/;
    $project_id =~ s/\D//g;
    return undef unless $project_id && ref($profile) eq 'HASH';
    my $mc = $profile->{'mc_version'} // '';
    $mc =~ s/[^0-9.]//g;
    my $loader_type = curseforge_mod_loader_type($profile->{'loader'} // '');

    my @queries;
    if ($mc && defined $loader_type) {
        push @queries, "gameVersion=$mc&modLoaderType=$loader_type&pageSize=50";
    }
    push @queries, "gameVersion=$mc&pageSize=50" if $mc;
    push @queries, 'pageSize=50';

    my @all;
    my %seen_fid;
    for my $q (@queries) {
        my $url = "https://api.curseforge.com/v1/mods/$project_id/files?$q";
        my $resp = _modpack_http_get_json_import($url, { 'x-api-key' => $key });
        next unless ref($resp) eq 'HASH' && ref($resp->{'data'}) eq 'ARRAY';
        for my $f (@{ $resp->{'data'} }) {
            next unless ref($f) eq 'HASH';
            my $fid = $f->{'id'};
            next unless defined $fid;
            next if $seen_fid{$fid}++;
            $seen_fid{$fid} = 1;
            push @all, $f;
        }
        my $meta = _curseforge_pick_modpack_file_meta($profile, $resp->{'data'});
        return $meta if $meta;
    }
    return _curseforge_pick_modpack_file_meta($profile, \@all);
}

sub _modpack_read_job_meta_file {
    my ($job_dir) = @_;
    return undef unless defined $job_dir && $job_dir =~ /\S/;
    my $path = "$job_dir/pack_meta.json";
    return undef unless -f $path;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $raw = <$fh> // '';
    close($fh);
    my $meta = eval { decode_json($raw) };
    return ref($meta) eq 'HASH' ? $meta : undef;
}

*modpack_read_job_meta_file = \&_modpack_read_job_meta_file;

sub modpack_entry_basename {
    my ($entry) = @_;
    return '' unless ref($entry) eq 'HASH';
    my $path = $entry->{'path'} // '';
    $path = (split m{/}, $path)[-1];
    return $path if defined $path && $path =~ /\S/;
    my $pid = $entry->{'project_id'} // '';
    my $fid = $entry->{'file_id'} // '';
    $pid =~ s/\D//g;
    $fid =~ s/\D//g;
    return '' unless $pid && $fid;
    return "mod-$pid-$fid.jar";
}

sub _modpack_read_mc_mods_index {
    my ($server_dir) = @_;
    return {} unless defined $server_dir && $server_dir =~ /\S/;
    my $path = "$server_dir/.mc_mods_index.json";
    return {} unless -f $path;
    open(my $fh, '<', $path) or return {};
    local $/;
    my $raw = <$fh> // '';
    close($fh);
    my $idx = eval { decode_json($raw) };
    return ref($idx) eq 'HASH' ? $idx : {};
}

sub _modpack_index_basename_for_ids {
    my ($index, $mod_dir, $project_id, $file_id) = @_;
    return undef unless ref($index) eq 'HASH';
    $project_id =~ s/\D//g if defined $project_id;
    $file_id    =~ s/\D//g if defined $file_id;
    return undef unless $project_id && $file_id;
    my $prefix = "$mod_dir/";
    for my $key (keys %$index) {
        my $rec = $index->{$key};
        next unless ref($rec) eq 'HASH';
        my $pid = $rec->{'project_id'} // '';
        my $fid = $rec->{'file_id'} // '';
        $pid =~ s/\D//g;
        $fid =~ s/\D//g;
        next unless $pid eq $project_id && $fid eq $file_id;
        my $base = $key;
        $base =~ s/^\Q$mod_dir\E\/// if $mod_dir ne '';
        $base = (split m{/}, $base)[-1];
        return $base if defined $base && $base =~ /\S/;
    }
    return undef;
}

sub _modpack_file_sha1 {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    open(my $fh, '-|', 'sha1sum', $path) or return undef;
    my $line = <$fh> // '';
    close($fh);
    my ($got) = $line =~ /^([0-9a-fA-F]{40})/;
    return $got;
}

sub _modpack_build_sha1_index {
    my ($target_root) = @_;
    return {} unless defined $target_root && -d $target_root;
    opendir(my $dh, $target_root) or return {};
    my @names = grep { $_ !~ /^\./ && -f "$target_root/$_" } readdir($dh);
    closedir($dh);
    my %idx;
    for my $name (@names) {
        my $got = _modpack_file_sha1("$target_root/$name");
        next unless defined $got && $got =~ /^[0-9a-fA-F]{40}$/;
        my $key = lc($got);
        $idx{$key} = $name unless exists $idx{$key};
    }
    return \%idx;
}

sub _modpack_find_by_sha1_in_dir {
    my ($target_root, $sha1, $sha1_index) = @_;
    return undef unless defined $sha1 && $sha1 =~ /^[0-9a-fA-F]{40}$/;
    if (ref($sha1_index) eq 'HASH') {
        my $hit = $sha1_index->{lc($sha1)};
        return $hit if defined $hit && $hit ne '';
    }
    return undef unless defined $target_root && -d $target_root;
    opendir(my $dh, $target_root) or return undef;
    my @names = grep { $_ !~ /^\./ && -f "$target_root/$_" } readdir($dh);
    closedir($dh);
    for my $name (@names) {
        my $got = _modpack_file_sha1("$target_root/$name");
        next unless defined $got && lc($got) eq lc($sha1);
        return $name;
    }
    return undef;
}

sub _modpack_require_mc_mods {
    return 1 if defined &curseforge_fetch_file_record;
    my $root = $ENV{'MODULE_ROOT'} // '';
    return 0 unless $root =~ /\S/;
    push @INC, "$root/lib";
    eval { do "$root/lib/mc_mods.pl" }; ## no critic
    return defined &curseforge_fetch_file_record;
}

sub _modpack_entry_cf_ids {
    my ($entry) = @_;
    return ('', '') unless ref($entry) eq 'HASH';
    my $pid = $entry->{'project_id'} // $entry->{'projectID'} // $entry->{'projectId'} // '';
    my $fid = $entry->{'file_id'} // $entry->{'fileID'} // $entry->{'fileId'} // '';
    $pid =~ s/\D//g if defined $pid;
    $fid =~ s/\D//g if defined $fid;
    return ($pid // '', $fid // '');
}

sub _modpack_entry_sha1 {
    my ($entry, $use_cache) = @_;
    my $sha1 = '';
    if (ref($entry) eq 'HASH' && ref($entry->{'hashes'}) eq 'HASH') {
        $sha1 = $entry->{'hashes'}->{'sha1'} // '';
    }
    return $sha1 if $sha1 =~ /^[0-9a-fA-F]{40}$/;
    return '' unless $use_cache && _modpack_require_mc_mods();
    my ($pid, $fid) = _modpack_entry_cf_ids($entry);
    return '' unless $pid && $fid;
    my $key = curseforge_api_key();
    return '' unless $key =~ /\S/;
    my $rec = curseforge_fetch_file_record($pid, $fid, $key, 120);
    return '' unless ref($rec) eq 'HASH' && ref($rec->{'meta'}) eq 'HASH';
    my $norm = curseforge_normalize_hashes($rec->{'meta'}->{'hashes'});
    $sha1 = ref($norm) eq 'HASH' ? ($norm->{'sha1'} // '') : '';
    return $sha1 =~ /^[0-9a-fA-F]{40}$/ ? $sha1 : '';
}

sub _modpack_state_completed_basename {
    my ($job_dir, $idx) = @_;
    return undef unless defined $job_dir && $idx =~ /^\d+$/;
    my $st = modpack_read_install_state($job_dir);
    my $c = $st->{'completed'} // {};
    return undef unless ref($c) eq 'HASH';
    my $base = $c->{$idx};
    return (defined $base && $base =~ /\S/) ? $base : undef;
}

sub modpack_meta_install_ready {
    my ($meta) = @_;
    return 0 unless ref($meta) eq 'HASH';
    return 0 unless defined $meta->{'pack_file'} && -f $meta->{'pack_file'};
    return 0 unless ref($meta->{'files'}) eq 'ARRAY' && @{ $meta->{'files'} };
    for my $f (@{ $meta->{'files'} }) {
        return 0 unless _modpack_entry_has_download($f);
    }
    return 1;
}

sub modpack_merge_checkpoint_into_meta {
    my ($job_dir, $unix_user) = @_;
    my $cp = modpack_read_cf_resolve_checkpoint($job_dir);
    return 0 unless ref($cp) eq 'HASH' && ref($cp->{'resolved'}) eq 'ARRAY';
    my $meta = _modpack_read_job_meta_file($job_dir) or return 0;
    my $files = $meta->{'files'} // [];
    return 0 unless ref($files) eq 'ARRAY' && @$files;
    my @resolved = @{ $cp->{'resolved'} };
    return 0 unless @resolved == @$files;
    my $changed = 0;
    for my $i (0 .. $#$files) {
        next unless ref($resolved[$i]) eq 'HASH';
        next unless _modpack_entry_has_download($resolved[$i]);
        if (!_modpack_entry_has_download($files->[$i])) {
            $files->[$i] = { %{ $files->[$i] }, %{ $resolved[$i] } };
            $changed = 1;
        }
    }
    return 0 unless $changed;
    $meta->{'files'} = $files;
    return write_modpack_job_meta($job_dir, $meta, $unix_user);
}

# Match installed mod on disk via CF cache SHA1 (handles placeholder paths in pack_meta).
sub modpack_entry_match_on_disk_via_cache {
    my ($entry, $target_root, $sha1_index) = @_;
    return undef unless -d $target_root;
    my $sha1 = '';
    if (ref($entry) eq 'HASH' && ref($entry->{'hashes'}) eq 'HASH') {
        $sha1 = $entry->{'hashes'}->{'sha1'} // '';
    }
    if ($sha1 !~ /^[0-9a-fA-F]{40}$/ && _modpack_require_mc_mods()) {
        my ($pid, $fid) = _modpack_entry_cf_ids($entry);
        if ($pid && $fid) {
            my $key = curseforge_api_key();
            if ($key =~ /\S/) {
                my $rec = curseforge_fetch_file_record($pid, $fid, $key, 120);
                if (ref($rec) eq 'HASH' && ref($rec->{'meta'}) eq 'HASH') {
                    my $norm = curseforge_normalize_hashes($rec->{'meta'}->{'hashes'});
                    $sha1 = ref($norm) eq 'HASH' ? ($norm->{'sha1'} // '') : '';
                }
            }
        }
    }
    return undef unless $sha1 =~ /^[0-9a-fA-F]{40}$/;
    return _modpack_find_by_sha1_in_dir($target_root, $sha1, $sha1_index);
}

sub modpack_bootstrap_installed_from_disk {
    my ($job_dir, $server_dir, $unix_user) = @_;
    my $meta = _modpack_read_job_meta_file($job_dir) or return 0;
    my $files = $meta->{'files'} // [];
    return 0 unless ref($files) eq 'ARRAY' && @$files;
    $server_dir //= $meta->{'server_dir'} // '';
    return 0 unless $server_dir =~ /\S/;
    my $mod_dir = $meta->{'mod_dir'} // 'mods';
    my $target = "$server_dir/serverfiles/$mod_dir";
    my $st = modpack_read_install_state($job_dir);
    my $completed = $st->{'completed'} // {};
    $completed = {} unless ref($completed) eq 'HASH';
    my $index = _modpack_read_mc_mods_index($server_dir);
    my $sha1_index = _modpack_build_sha1_index($target);
    my $changed = 0;
    for my $i (0 .. $#$files) {
        my $e = $files->[$i];
        next unless ref($e) eq 'HASH';
        my ($ok, undef, $base) = modpack_entry_resolve_installed(
            $e, $target, $index, $mod_dir, $job_dir, $i, $sha1_index);
        if (!$ok) {
            my $by_cache = modpack_entry_match_on_disk_via_cache($e, $target, $sha1_index);
            if (defined $by_cache) {
                $ok = 1;
                $base = $by_cache;
            }
        }
        next unless $ok && defined $base && $base =~ /\S/;
        next if ($completed->{$i} // '') eq $base;
        $completed->{$i} = $base;
        modpack_index_add_installed_mod($server_dir, $mod_dir, $base, $e, $meta->{'format'});
        $changed = 1;
    }
    return 0 unless $changed;
    $st->{'completed'} = $completed;
    my $total = scalar @$files;
    my $done = scalar grep { defined $_ && $_ ne '' } values %$completed;
    my $resume_idx = $total;
    for my $i (0 .. $#$files) {
        unless (($completed->{$i} // '') =~ /\S/) {
            $resume_idx = $i;
            last;
        }
    }
    $st->{'total'}        = $total;
    $st->{'installed'}    = $done;
    $st->{'missing'}      = $total > $done ? ($total - $done) : 0;
    $st->{'resume_index'} = $resume_idx;
    return modpack_write_install_state($job_dir, $st);
}

# Worker: (skip, dest_base, dl_url, sha1) for one mod index.
sub modpack_worker_entry_plan {
    my ($job_dir, $server_dir, $idx) = @_;
    my $meta = _modpack_read_job_meta_file($job_dir) or return (0, '', '', '');
    my $files = $meta->{'files'} // [];
    return (0, '', '', '') unless $idx =~ /^\d+$/ && $idx < @$files;
    my $entry = $files->[$idx];
    return (0, '', '', '') unless ref($entry) eq 'HASH';
    $server_dir //= $meta->{'server_dir'} // '';
    return (0, '', '', '') unless $server_dir =~ /\S/;
    my $mod_dir = $meta->{'mod_dir'} // 'mods';
    my $target = "$server_dir/serverfiles/$mod_dir";
    my $index = _modpack_read_mc_mods_index($server_dir);

    my ($ok, undef, $base) = modpack_entry_resolve_installed(
        $entry, $target, $index, $mod_dir, $job_dir, $idx);
    if (!$ok) {
        my $by_cache = modpack_entry_match_on_disk_via_cache($entry, $target);
        if (defined $by_cache) {
            $ok = 1;
            $base = $by_cache;
        }
    }
    if ($ok) {
        return (1, $base // '', '', '');
    }

    my $dl = '';
    if (ref($entry->{'downloads'}) eq 'ARRAY' && @{ $entry->{'downloads'} }) {
        $dl = $entry->{'downloads'}[0] // '';
    }
    my $base_out = modpack_entry_basename($entry);
    if (_modpack_require_mc_mods()) {
        my ($pid, $fid) = _modpack_entry_cf_ids($entry);
        if ($pid && $fid) {
            my $key = curseforge_api_key();
            if ($key =~ /\S/) {
                my $rec = curseforge_fetch_file_record($pid, $fid, $key, 120);
                if (ref($rec) eq 'HASH' && ($rec->{'url'} // '') =~ /\S/) {
                    $dl = $rec->{'url'} unless $dl =~ /\S/;
                    if (ref($rec->{'meta'}) eq 'HASH') {
                        my $fn = $rec->{'meta'}->{'fileName'} // '';
                        $fn =~ s/[^a-zA-Z0-9._-]//g;
                        $base_out = $fn if $fn =~ /\S/ && $base_out =~ /^mod-\d+-\d+\./i;
                    }
                }
            }
        }
    }
    my $sha1 = _modpack_entry_sha1($entry, 1);
    return (0, $base_out, $dl, $sha1);
}

sub modpack_worker_bootstrap {
    my ($job_dir, $server_dir, $unix_user) = @_;
    modpack_merge_checkpoint_into_meta($job_dir, $unix_user);
    return modpack_bootstrap_installed_from_disk($job_dir, $server_dir, $unix_user);
}

# True when expand_remote_modpack_job_meta must run (remote pack / CF resolve not finished).
sub modpack_needs_expand_prepare {
    my ($job_dir) = @_;
    return 0 unless defined $job_dir && -d $job_dir;
    return 0 unless -f "$job_dir/pack_meta.json";
    my $meta = _modpack_read_job_meta_file($job_dir) or return 0;
    return 0 if modpack_meta_install_ready($meta);
    return 1 if ($meta->{'remote_pending'} // 0);
    return 1 if -f modpack_cf_resolve_checkpoint_path($job_dir);
    return 1 if defined _modpack_find_upload_pack($job_dir);
    my $pf = $meta->{'pack_file'} // '';
    return 1 if $pf =~ /\S/ && -f $pf;
    return 1 if ($meta->{'remote_download'} // '') =~ m{\Ahttps://}i;
    return 0;
}

# Returns (installed_bool, dest_path, display_basename)
sub modpack_entry_resolve_installed {
    my ($entry, $target_root, $index, $mod_dir, $job_dir, $idx, $sha1_index) = @_;
    return (0, undef, undef) unless ref($entry) eq 'HASH';
    $index //= {};
    $mod_dir //= 'mods';
    if (defined $job_dir && defined $idx && $idx =~ /^\d+$/) {
        my $from_state = _modpack_state_completed_basename($job_dir, $idx);
        if (defined $from_state && $from_state ne '') {
            my $dest = "$target_root/$from_state";
            if (-f $dest && (-s $dest) > 0) {
                return (1, $dest, $from_state);
            }
        }
    }
    my @candidates;
    my $base = modpack_entry_basename($entry);
    push @candidates, $base if $base ne '';
    my ($pid, $fid) = _modpack_entry_cf_ids($entry);
    if ($pid && $fid) {
        my $from_idx = _modpack_index_basename_for_ids($index, $mod_dir, $pid, $fid);
        push @candidates, $from_idx if defined $from_idx && $from_idx ne '';
        push @candidates, "mod-$pid-$fid.jar";
    }
    my %seen;
    for my $cand (@candidates) {
        next unless defined $cand && $cand ne '';
        next if $seen{$cand}++;
        my $dest = "$target_root/$cand";
        if (modpack_entry_installed($entry, $dest)) {
            return (1, $dest, $cand);
        }
    }
    my $sha1 = _modpack_entry_sha1($entry, 0);
    if ($sha1 =~ /^[0-9a-fA-F]{40}$/) {
        my $by_sha = _modpack_find_by_sha1_in_dir($target_root, $sha1, $sha1_index);
        if (defined $by_sha) {
            return (1, "$target_root/$by_sha", $by_sha);
        }
    }
    unless (ref($sha1_index) eq 'HASH') {
        my $by_cache = modpack_entry_match_on_disk_via_cache($entry, $target_root, $sha1_index);
        if (defined $by_cache) {
            return (1, "$target_root/$by_cache", $by_cache);
        }
    }
    return (0, undef, undef);
}

sub modpack_install_state_path {
    my ($job_dir) = @_;
    return "$job_dir/modpack_install.state.json";
}

sub modpack_read_install_state {
    my ($job_dir) = @_;
    my $path = modpack_install_state_path($job_dir);
    return {} unless -f $path;
    open(my $fh, '<', $path) or return {};
    local $/;
    my $raw = <$fh> // '';
    close($fh);
    my $st = eval { decode_json($raw) };
    return ref($st) eq 'HASH' ? $st : {};
}

sub modpack_write_install_state {
    my ($job_dir, $state) = @_;
    return 0 unless defined $job_dir && ref($state) eq 'HASH';
    return _modpack_atomic_write_json(
        modpack_install_state_path($job_dir),
        encode_json($state));
}

sub modpack_mod_installed_for_index {
    my ($job_dir, $server_dir, $idx) = @_;
    my $meta = _modpack_read_job_meta_file($job_dir) or return (0, '', '');
    my $files = $meta->{'files'} // [];
    return (0, '', '') unless $idx =~ /^\d+$/ && $idx < @$files;
    my $entry = $files->[$idx];
    return (0, '', '') unless ref($entry) eq 'HASH';
    $server_dir //= $meta->{'server_dir'} // '';
    return (0, '', '') unless $server_dir =~ /\S/;
    my $mod_dir = $meta->{'mod_dir'} // 'mods';
    my $target = "$server_dir/serverfiles/$mod_dir";
    my $index = _modpack_read_mc_mods_index($server_dir);
    my ($ok, $dest, $base) = modpack_entry_resolve_installed(
        $entry, $target, $index, $mod_dir, $job_dir, $idx);
    return ($ok ? 1 : 0, $dest // '', $base // '');
}

sub modpack_entry_installed {
    my ($entry, $dest) = @_;
    return 0 unless defined $dest && $dest ne '' && -f $dest;
    my $sha1 = '';
    if (ref($entry) eq 'HASH' && ref($entry->{'hashes'}) eq 'HASH') {
        $sha1 = $entry->{'hashes'}->{'sha1'} // '';
    }
    if (defined $sha1 && $sha1 =~ /^[0-9a-fA-F]{40}$/) {
        open(my $fh, '-|', 'sha1sum', $dest) or return 0;
        my $line = <$fh> // '';
        close($fh);
        my ($got) = $line =~ /^([0-9a-fA-F]{40})/;
        return 0 unless defined $got && lc($got) eq lc($sha1);
        return 1;
    }
    return (-s $dest) > 0 ? 1 : 0;
}

# Scan serverfiles/mods vs pack_meta.json — used for resume UI and worker skip logic.
sub modpack_update_install_state {
    my ($job_dir, $server_dir, $idx, $basename) = @_;
    return 0 unless defined $job_dir && $job_dir =~ /\S/;
    my $st = modpack_read_install_state($job_dir);
    $st->{'last_index'} = $idx if defined $idx && $idx =~ /^\d+$/;
    $st->{'last_basename'} = $basename if defined $basename && $basename =~ /\S/;
    $st->{'completed'} //= {};
    $st->{'completed'} = {} unless ref($st->{'completed'}) eq 'HASH';
    if (defined $idx && $idx =~ /^\d+$/ && defined $basename && $basename =~ /\S/) {
        $st->{'completed'}->{$idx} = $basename;
        $st->{'resume_index'} = $idx + 1;
    }
    my $meta = _modpack_read_job_meta_file($job_dir);
    my $total = (ref($meta) eq 'HASH' && ref($meta->{'files'}) eq 'ARRAY')
        ? scalar @{ $meta->{'files'} } : 0;
    my $done = scalar grep { defined $_ && $_ ne '' } values %{ $st->{'completed'} };
    $st->{'total'}     = $total;
    $st->{'installed'} = $done;
    $st->{'missing'}   = $total > $done ? ($total - $done) : 0;
    return modpack_write_install_state($job_dir, $st);
}

sub modpack_index_add_installed_mod {
    my ($server_dir, $mod_dir, $basename, $entry, $format) = @_;
    return 0 unless defined $server_dir && $server_dir =~ /\S/;
    return 0 unless defined $basename && $basename =~ /\S/;
    $mod_dir //= 'mods';
    my $idx_path = "$server_dir/.mc_mods_index.json";
    my $idx = _modpack_read_mc_mods_index($server_dir);
    my $key = "$mod_dir/$basename";
    my $rec = { env => (ref($entry) eq 'HASH' ? ($entry->{'env'} // 'unknown') : 'unknown') };
    if (ref($entry) eq 'HASH') {
        if (defined $entry->{'title'} && $entry->{'title'} =~ /\S/) {
            $rec->{'title'} = $entry->{'title'};
        } elsif (defined $entry->{'name'} && $entry->{'name'} =~ /\S/) {
            $rec->{'title'} = $entry->{'name'};
        }
        if ($entry->{'modrinth_project'}) {
            $rec->{'source'} = 'modrinth';
            $rec->{'modrinth_project'} = $entry->{'modrinth_project'};
            $rec->{'modrinth_version'} = $entry->{'modrinth_version'} if $entry->{'modrinth_version'};
        } elsif (($entry->{'project_id'} // '') =~ /\S/ && ($entry->{'file_id'} // '') =~ /\S/) {
            $rec->{'source'} = 'curseforge';
            $rec->{'project_id'} = $entry->{'project_id'};
            $rec->{'file_id'}    = $entry->{'file_id'};
        } elsif ($format) {
            $rec->{'source'} = $format;
        }
    }
    $idx->{$key} = $rec;
    return _modpack_atomic_write_json($idx_path, encode_json($idx));
}

sub modpack_install_progress {
    my ($job_dir, $server_dir) = @_;
    my $meta = _modpack_read_job_meta_file($job_dir) or return undef;
    my @files = @{ $meta->{'files'} // [] };
    my $mod_dir = $meta->{'mod_dir'} // 'mods';
    $server_dir //= $meta->{'server_dir'} // '';
    return undef unless $server_dir =~ /\S/;
    my $target = "$server_dir/serverfiles/$mod_dir";
    my $index = _modpack_read_mc_mods_index($server_dir);
    my $sha1_index = _modpack_build_sha1_index($target);
    my ($installed, $last_name, $resume_idx);
    my $idx = 0;
    for my $e (@files) {
        next unless ref($e) eq 'HASH';
        my ($ok, undef, $base) = modpack_entry_resolve_installed(
            $e, $target, $index, $mod_dir, $job_dir, $idx, $sha1_index);
        if ($ok) {
            $installed++;
            $last_name = $base if defined $base && $base ne '';
        } elsif (!defined $resume_idx) {
            $resume_idx = $idx;
        }
        $idx++;
    }
    my $total = scalar @files;
    return {
        total          => $total,
        installed      => $installed // 0,
        missing        => $total - ($installed // 0),
        last_installed => $last_name // '',
        resume_index   => defined $resume_idx ? $resume_idx : $total,
        pack_name      => $meta->{'pack_name'} // '',
        mod_dir        => $mod_dir,
    };
}

# Fast progress for Webmin UI — reads install state / jar count, no full SHA1 rescan.
sub modpack_install_progress_light {
    my ($job_dir, $server_dir) = @_;
    my $meta = _modpack_read_job_meta_file($job_dir) or return undef;
    my @files = @{ $meta->{'files'} // [] };
    my $total = scalar @files;
    return undef unless $total > 0;
    my $mod_dir = $meta->{'mod_dir'} // 'mods';
    $server_dir //= $meta->{'server_dir'} // '';
    return undef unless $server_dir =~ /\S/;

    my $st = modpack_read_install_state($job_dir);
    my $completed = ref($st->{'completed'}) eq 'HASH' ? $st->{'completed'} : {};

    if (($st->{'total'} // 0) == $total && ($st->{'installed'} // 0) > 0) {
        return {
            total          => $total,
            installed      => $st->{'installed'},
            missing        => $st->{'missing'} // ($total - ($st->{'installed'} // 0)),
            last_installed => $st->{'last_basename'} // '',
            resume_index   => $st->{'resume_index'} // 0,
            pack_name      => $meta->{'pack_name'} // '',
            mod_dir        => $mod_dir,
        };
    }

    if (my $done = scalar grep { defined $_ && $_ ne '' } values %$completed) {
        my $resume_idx = $st->{'resume_index'};
        if (!defined $resume_idx || $resume_idx !~ /^\d+$/) {
            for my $i (0 .. $#files) {
                unless (($completed->{$i} // '') =~ /\S/) {
                    $resume_idx = $i;
                    last;
                }
            }
            $resume_idx //= $total;
        }
        return {
            total          => $total,
            installed      => $done,
            missing        => $total - $done,
            last_installed => $st->{'last_basename'} // '',
            resume_index   => $resume_idx,
            pack_name      => $meta->{'pack_name'} // '',
            mod_dir        => $mod_dir,
        };
    }

    my $target = "$server_dir/serverfiles/$mod_dir";
    my $jar_count = 0;
    if (-d $target) {
        opendir(my $dh, $target) or return modpack_install_progress($job_dir, $server_dir);
        $jar_count = scalar grep {
            !/^\./ && /\.(?:jar|zip)$/i && -f "$target/$_"
        } readdir($dh);
        closedir($dh);
    }
    my $installed = $jar_count > $total ? $total : $jar_count;
    return {
        total          => $total,
        installed      => $installed,
        missing        => $total - $installed,
        last_installed => '',
        resume_index   => $installed < $total ? $installed : $total,
        pack_name      => $meta->{'pack_name'} // '',
        mod_dir        => $mod_dir,
    };
}

sub modpack_job_has_resume_meta {
    my ($job_dir) = @_;
    return defined $job_dir && -f "$job_dir/pack_meta.json" ? 1 : 0;
}

sub modpack_cf_resolve_checkpoint_path {
    my ($job_dir) = @_;
    return "$job_dir/cf_resolve_progress.json";
}

sub modpack_read_cf_resolve_checkpoint {
    my ($job_dir) = @_;
    my $path = modpack_cf_resolve_checkpoint_path($job_dir);
    return undef unless -f $path;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $raw = <$fh> // '';
    close($fh);
    my $cp = eval { decode_json($raw) };
    return undef unless ref($cp) eq 'HASH';
    return $cp;
}

# Pad stored checkpoint to $total entries (JSON may omit trailing nulls on older writes).
sub modpack_cf_resolve_merge_checkpoint {
    my ($cp, $total) = @_;
    return () unless ref($cp) eq 'HASH'
        && ref($cp->{'resolved'}) eq 'ARRAY'
        && ($cp->{'total'} // 0) == $total
        && $total > 0;
    my @stored = @{ $cp->{'resolved'} };
    return @stored if @stored == $total;
    my @out = ((undef) x $total);
    my $limit = @stored < $total ? $#stored : ($total - 1);
    for my $i (0 .. $limit) {
        $out[$i] = $stored[$i] if ref($stored[$i]) eq 'HASH';
    }
    return @out;
}

sub modpack_cf_resolve_done_count {
    my ($resolved_ref) = @_;
    return 0 unless ref($resolved_ref) eq 'ARRAY';
    return scalar grep { ref($_) eq 'HASH' && _modpack_entry_has_download($_) } @$resolved_ref;
}

sub modpack_write_cf_resolve_checkpoint {
    my ($job_dir, $resolved_ref, $total, $unix_user, $extra) = @_;
    return 0 unless defined $job_dir && ref($resolved_ref) eq 'ARRAY';
    my @dense = @$resolved_ref;
    while (@dense < $total) {
        push @dense, undef;
    }
    $#dense = ($total - 1) if @dense > $total;
    my $payload = {
        total    => $total,
        resolved => \@dense,
    };
    if (ref($extra) eq 'HASH') {
        for my $k (keys %$extra) {
            $payload->{$k} = $extra->{$k};
        }
    }
    my $path = modpack_cf_resolve_checkpoint_path($job_dir);
    return 0 unless _modpack_atomic_write_json($path, encode_json($payload));
    _modpack_chown_to_user($unix_user, $path) if defined $unix_user && $unix_user ne '';
    return 1;
}

sub modpack_cf_rate_limit_cooldown_sec {
    my $env = $ENV{'WEBCORE_CF_COOLDOWN_SEC'} // '';
    return $env if $env =~ /^\d+$/ && $env > 0;
    return 900;
}

# CurseForge CDN often throttles large pack installs around mod ~95 (bulk threshold for user hints).
sub modpack_cf_cdn_bulk_threshold {
    my $env = $ENV{'WEBCORE_CF_CDN_BULK_THRESHOLD'} // '';
    return $env if $env =~ /^\d+$/ && $env > 0;
    return 90;
}

sub modpack_is_cf_bulk_pack_meta {
    my ($meta) = @_;
    return 0 unless ref($meta) eq 'HASH';
    my $total = scalar @{ $meta->{'files'} // [] };
    return ($meta->{'format'} // '') eq 'curseforge' && $total > modpack_cf_cdn_bulk_threshold();
}

sub modpack_cf_bulk_install_info_message {
    my ($total, $text_ref) = @_;
    $text_ref //= {};
    return '' unless defined $total && $total =~ /^\d+$/ && $total > modpack_cf_cdn_bulk_threshold();
    my $fmt = $text_ref->{'mc_modpack_cf_bulk_install_info'};
    return _mc_modpack_apply_text($fmt, $total) if defined $fmt && $fmt =~ /\S/;
    return "Large CurseForge pack ($total mods): API/CDN often pauses around mods ~90-95 — normal. "
        . "Wait 10-15 minutes, then use Download fortsetzen on the same job.";
}

sub modpack_cf_bulk_install_log {
    my ($total, $text_ref) = @_;
    my $msg = modpack_cf_bulk_install_info_message($total, $text_ref);
    return unless defined $msg && $msg =~ /\S/;
    print "=== $msg ===\n";
    STDOUT->autoflush(1) if -t STDOUT;
    return $msg;
}

sub modpack_cf_auto_resume_enabled {
    our %config;
    if (defined &module_config_apply_job_secrets) {
        eval { module_config_apply_job_secrets() };
    }
    my $raw = $config{modpack_cf_auto_resume};
    # Default ON when the key is absent (e.g. installs made before this option).
    return 1 unless defined $raw && $raw =~ /\S/;
    if (defined &module_config_bool) {
        return module_config_bool($raw) ? 1 : 0;
    }
    (my $v = $raw) =~ s/[\t\n\r]//g;
    return ($v eq '1') ? 1 : 0;
}

# Cooldown (15 min) + 30s buffer => ~15.5 min between auto-retries.
sub modpack_cf_auto_resume_wait_sec {
    my $extra = $ENV{WEBCORE_CF_AUTO_RESUME_EXTRA_SEC} // 30;
    $extra = 30 unless defined $extra && $extra =~ /^\d+$/;
    return modpack_cf_rate_limit_cooldown_sec() + $extra;
}

sub modpack_cf_auto_resume_sleep {
    my ($phase) = @_;
    $phase //= 'curseforge';
    my $wait = modpack_cf_auto_resume_wait_sec();
    my $wait_min = int(($wait + 59) / 60);
    print "=== CurseForge Auto-Resume ($phase): warte ${wait}s (~${wait_min} Min.) ===\n";
    print "=== (Automatische Pause - Job laeuft weiter, bitte nicht abbrechen) ===\n";
    STDOUT->autoflush(1) if -t STDOUT;
    sleep($wait);
    return $wait;
}

# Sleep until CurseForge cooldown elapsed after last rate-limit failure (expand phase).
sub modpack_cf_apply_rate_limit_cooldown {
    my ($job_dir) = @_;
    my $cp = modpack_read_cf_resolve_checkpoint($job_dir) or return 0;
    my $at = $cp->{'last_rate_limit_at'} // 0;
    if (!($at =~ /^\d+$/ && $at > 0)) {
        my $done  = ref($cp->{'resolved'}) eq 'ARRAY'
            ? modpack_cf_resolve_done_count($cp->{'resolved'}) : 0;
        my $total = $cp->{'total'} // 0;
        if ($done > 0 && $total > 0 && $done < $total) {
            my $st_file = "$job_dir/status";
            if (-f $st_file && open(my $sf, '<', $st_file)) {
                my $st = <$sf> // '';
                close($sf);
                chomp $st;
                if ($st eq 'failed' || $st eq 'aborted') {
                    $at = (stat($st_file))[9] // 0;
                }
            }
        }
    }
    return 0 unless $at =~ /^\d+$/ && $at > 0;
    my $cooldown = modpack_cf_rate_limit_cooldown_sec();
    my $elapsed  = time() - $at;
    return 0 if $elapsed >= $cooldown;
    my $wait = $cooldown - $elapsed;
    my $wait_min = int(($wait + 59) / 60);
    print "=== CurseForge Abkühlphase: warte noch ${wait}s (~${wait_min} Min.) vor dem naechsten API-Aufruf ===\n";
    print "=== (Automatische Pause - Job laeuft weiter, bitte nicht abbrechen) ===\n";
    STDOUT->autoflush(1) if -t STDOUT;
    sleep($wait);
    return $wait;
}

sub _modpack_entry_has_download {
    my ($entry) = @_;
    return 0 unless ref($entry) eq 'HASH';
    return ref($entry->{'downloads'}) eq 'ARRAY' && @{ $entry->{'downloads'} } ? 1 : 0;
}

sub _modpack_find_upload_pack {
    my ($job_dir) = @_;
    return undef unless defined $job_dir && -d "$job_dir/upload";
    opendir(my $dh, "$job_dir/upload") or return undef;
    my @candidates = sort grep { /\.(?:mrpack|zip)\z/i && -f "$job_dir/upload/$_" } readdir($dh);
    closedir($dh);
    return $candidates[0] ? "$job_dir/upload/$candidates[0]" : undef;
}

sub modpack_job_expand_resumable {
    my ($job_dir) = @_;
    return 0 unless defined $job_dir && -d $job_dir;
    return 1 if -f modpack_cf_resolve_checkpoint_path($job_dir);
    return 1 if defined _modpack_find_upload_pack($job_dir);
    my $meta = _modpack_read_job_meta_file($job_dir) or return 0;
    return 1 if ($meta->{'remote_pending'} // 0);
    return 1 if ($meta->{'remote_download'} // '') =~ m{\Ahttps://}i;
    return 0;
}

# Returns (ok, progress_hashref)
sub modpack_job_resumable {
    my ($job_dir, $server_dir, $status, $action) = @_;
    $status //= '';
    $action //= '';
    return (0, undef) unless $action eq 'modpack_import';
    return (0, undef) unless $status eq 'failed' || $status eq 'aborted';
    return (0, undef) unless defined $job_dir && modpack_job_has_resume_meta($job_dir);
    my $prog = modpack_install_progress_light($job_dir, $server_dir);
    if (!ref($prog) || ($prog->{'total'} // 0) <= 0) {
        if (modpack_job_expand_resumable($job_dir)) {
            return (1, {
                total          => 0,
                installed      => 0,
                missing        => 0,
                last_installed => '',
                resume_index   => 0,
                phase          => 'expand',
            });
        }
        return (0, undef);
    }
    return (0, undef) if ($prog->{'installed'} // 0) >= ($prog->{'total'} // 0);
    # Allow resume even when scan finds 0 but job failed mid-import (mods dir or state file).
    if (($prog->{'installed'} // 0) == 0) {
        my $mod_dir = $prog->{'mod_dir'} // 'mods';
        my $target = "$server_dir/serverfiles/$mod_dir";
        my $st = modpack_read_install_state($job_dir);
        if (($st->{'completed_count'} // 0) > 0) {
            return (1, $prog);
        }
        if (-d $target) {
            opendir(my $dh, $target) or return (1, $prog);
            my @jars = grep { /\.(?:jar|zip)$/i && -f "$target/$_" } readdir($dh);
            closedir($dh);
            return (1, $prog) if @jars;
        }
        return (0, undef);
    }
    return (1, $prog);
}

# Returns (ok, files_arrayref, error_code, detail_hashref)
sub curseforge_resolve_pack_files {
    my ($pack, %opts) = @_;
    my $progress_cb     = $opts{'progress_cb'};
    my $checkpoint_job = $opts{'checkpoint_job'};
    my $checkpoint_user = $opts{'checkpoint_user'};
    my $throttle_sec    = $opts{'throttle_sec'};
    $throttle_sec = 1 unless defined $throttle_sec && $throttle_sec =~ /^\d+(?:\.\d+)?$/;
    my $key = curseforge_api_key();
    return (0, undef, 'curseforge_key_missing', undef) unless $key =~ /\S/;
    my @src = @{ $pack->{'files'} // [] };
    my $total = scalar @src;
    return (0, undef, 'no_server_mods', undef) unless $total;

    modpack_cf_bulk_install_log($total);

    my @resolved;
    if ($checkpoint_job) {
        my $cp = modpack_read_cf_resolve_checkpoint($checkpoint_job);
        if (ref($cp) eq 'HASH') {
            @resolved = modpack_cf_resolve_merge_checkpoint($cp, $total);
        }
    }
    @resolved = ((undef) x $total) unless @resolved == $total;

    my $n = 0;
    my $api_calls = 0;
    my $checkpoint_skip = modpack_cf_resolve_done_count(\@resolved);
    if ($checkpoint_skip > 0) {
        print "=== Skipping $checkpoint_skip/$total mods (checkpoint cache) ===\n";
    }
    for my $i (0 .. $#src) {
        my $f = $src[$i];
        next unless ref($f) eq 'HASH';
        if (_modpack_entry_has_download($f)) {
            $resolved[$i] = { %$f };
            $n++;
            next;
        }
        if (_modpack_entry_has_download($resolved[$i])) {
            $n++;
            next;
        }
        my $pid = $f->{'project_id'};
        my $fid = $f->{'file_id'};
        $pid =~ s/\D//g if defined $pid;
        $fid =~ s/\D//g if defined $fid;
        my $mod_num = $i + 1;
        sleep($throttle_sec) if $api_calls > 0 && $throttle_sec > 0;
        sleep(15) if $api_calls > 0 && $api_calls % 20 == 0;
        my ($rec, $meta, $url);
        while (1) {
            $rec = curseforge_fetch_file_record($pid, $fid, $key, 120);
            $api_calls++ unless ref($rec) eq 'HASH' && ($rec->{'from_cache'} // 0);
            $meta = ref($rec) eq 'HASH' ? $rec->{'meta'} : undef;
            $url  = ref($rec) eq 'HASH' ? ($rec->{'url'} // '') : '';
            last if $meta && $url;

            my %fail_extra;
            my $rec_err  = ref($rec) eq 'HASH' ? ($rec->{'err'} // '') : '';
            my $is_limit = ($rec_err eq 'rate_limited')
                || ($rec_err eq 'api_failed')
                || ($rec_err eq 'no_url' && $meta);
            my $err_code = $is_limit ? 'curseforge_rate_limited' : 'curseforge_api_failed';
            if ($is_limit) {
                $fail_extra{last_rate_limit_at} = time();
                $fail_extra{last_fail_index}   = $i;
            }
            if ($checkpoint_job) {
                modpack_write_cf_resolve_checkpoint(
                    $checkpoint_job, \@resolved, $total, $checkpoint_user, \%fail_extra)
                    or print STDERR "WARNING: cf_resolve checkpoint write failed ($!)\n";
            }
            unless ($is_limit && modpack_cf_auto_resume_enabled()) {
                my %detail = (
                    project_id => ($pid && $pid =~ /\S/ ? $pid : ($f->{'project_id'} // '?')),
                    file_id    => ($fid && $fid =~ /\S/ ? $fid : ($f->{'file_id'} // '?')),
                    index      => $i,
                    mod_num    => $i + 1,
                );
                return (0, undef, $err_code, \%detail);
            }
            my $info = mc_modpack_error_message('curseforge_rate_limited', {
                mod_num    => $mod_num,
                project_id => $pid,
                file_id    => $fid,
            }, {}, {});
            print "INFO: $info\n" if defined $info && $info =~ /\S/;
            modpack_cf_auto_resume_sleep('API');
        }
        my $fname = $meta->{'fileName'};
        unless (defined $fname && $fname =~ /\S/) {
            $fname = 'mod-' . ($pid // '') . '-' . ($fid // '') . '.jar';
        }
        $fname =~ s/[^a-zA-Z0-9._-]//g;
        $fname = "mod.jar" unless $fname =~ /\S/;
        my $norm = curseforge_normalize_hashes($meta->{'hashes'});
        my %hashes = ref($norm) eq 'HASH' ? %$norm : ();
        $resolved[$i] = {
            path         => 'mods/' . $fname,
            downloads    => [$url],
            hashes       => \%hashes,
            env          => $f->{'env'} // 'unknown',
            required     => $f->{'required'} ? 1 : 0,
            project_id   => $f->{'project_id'},
            file_id      => $f->{'file_id'},
            source       => 'curseforge',
        };
        $n++;
        if ($checkpoint_job) {
            modpack_write_cf_resolve_checkpoint(
                $checkpoint_job, \@resolved, $total, $checkpoint_user)
                or print STDERR "WARNING: cf_resolve checkpoint write failed ($!)\n";
        }
        print "=== Mod $mod_num/$total (project $pid, file $fid): $fname ===\n";
        $progress_cb->($n, $total) if $progress_cb;
    }
    my @out = grep { ref($_) eq 'HASH' } @resolved;
    return (0, undef, 'no_server_mods', undef) unless @out;
    return (1, \@resolved, undef, undef);
}

# Defer per-mod CurseForge API calls to install worker (modpack zip only at expand time).
# Returns (ok, files_arrayref, error_code, detail_hashref)
sub curseforge_deferred_pack_files {
    my ($pack) = @_;
    return (0, undef, 'invalid_pack', undef) unless ref($pack) eq 'HASH';
    unless (curseforge_api_key() =~ /\S/) {
        return (0, undef, 'curseforge_key_missing', undef);
    }
    my @out;
    for my $f (@{ $pack->{'files'} // [] }) {
        next unless ref($f) eq 'HASH';
        my $pid = $f->{'project_id'};
        my $fid = $f->{'file_id'};
        next unless defined $pid && defined $fid;
        $pid =~ s/\D//g;
        $fid =~ s/\D//g;
        next unless $pid && $fid;
        push @out, {
            path       => sprintf('mods/mod-%s-%s.jar', $pid, $fid),
            project_id => "$pid",
            file_id    => "$fid",
            source     => 'curseforge',
            required   => ($f->{'required'} // 1) ? 1 : 0,
            env        => 'server',
            downloads  => [],
            hashes     => {},
        };
    }
    return (0, undef, 'no_server_mods', undef) unless @out;
    return (1, \@out, undef, undef);
}

sub _mc_modpack_apply_text {
    my ($fmt, @repl) = @_;
    return '' unless defined $fmt && $fmt =~ /\S/;
    my $i = 0;
    $fmt =~ s/\$(\d+)/($i < @repl ? $repl[$i++] : "\$$1")/ge;
    return $fmt;
}

sub _mc_modpack_text_lookup {
    my ($text_ref) = @_;
    $text_ref = {} unless ref($text_ref) eq 'HASH';
    return sub {
        my ($key, @repl) = @_;
        return _mc_modpack_apply_text($text_ref->{$key}, @repl) if $text_ref->{$key};
        return '';
    };
}

# Pack vs instance summary lines (job log / UI).
sub modpack_validation_compare_lines {
    my ($pack, $profile, $text_ref) = @_;
    $pack     = {} unless ref($pack) eq 'HASH';
    $profile  = {} unless ref($profile) eq 'HASH';
    my $t = _mc_modpack_text_lookup($text_ref);

    my $p_loader = $pack->{'loader'} // '?';
    my $p_mc     = $pack->{'mc_version'} // '?';
    my $p_lv     = $pack->{'loader_version'} // '';
    my $p_lv_s   = $p_lv ne '' ? " / Loader $p_lv" : '';

    my $i_loader = $profile->{'loader'} // '?';
    my $i_mc     = $profile->{'mc_version'} // '?';
    my $i_lv     = $profile->{'loader_version'} // '';
    my $i_lv_s   = $i_lv ne '' ? " / Loader $i_lv" : '';
    my $i_java   = int($profile->{'java_major'} // 0) || '?';

    my $header = $t->('mc_modpack_compare_header') || 'Pack vs. Instanz:';
    my $pack_line = $t->('mc_modpack_compare_pack', $p_loader, $p_mc, $p_lv_s)
        || "Pack: $p_loader / MC $p_mc$p_lv_s";
    my $inst_line = $t->('mc_modpack_compare_instance', $i_loader, $i_mc, $i_lv_s, $i_java)
        || "Instanz: $i_loader / MC $i_mc$i_lv_s / Java $i_java";
    return ($header, $pack_line, $inst_line);
}

# Soft mismatch messages (import continues). $text_ref optional (Webmin %text).
sub modpack_validation_warning_messages {
    my ($validation, $pack, $profile, $text_ref) = @_;
    return () unless ref($validation) eq 'HASH';
    $pack    = {} unless ref($pack) eq 'HASH';
    $profile = {} unless ref($profile) eq 'HASH';
    my $t = _mc_modpack_text_lookup($text_ref);

    my @out;
    for my $code (@{ $validation->{'warnings'} // [] }) {
        if ($code eq 'loader_version_mismatch') {
            push @out, $t->('mc_modpack_loader_version_mismatch',
                    $pack->{'loader_version'} // '?',
                    $profile->{'loader_version'} // '?')
                || 'Modpack benötigt Loader-Version '
                . ($pack->{'loader_version'} // '?')
                . ', Instanz hat '
                . ($profile->{'loader_version'} // '?')
                . '. Import läuft weiter — Loader ggf. anpassen.';
        } elsif ($code eq 'java_mismatch') {
            my $mc = $pack->{'mc_version'} || $profile->{'mc_version'} || '?';
            my $need = resolve_java_major($mc) || '?';
            my $have = int($profile->{'java_major'} // 0) || '?';
            push @out, $t->('mc_modpack_java_mismatch', $mc, $need, $have)
                || "Modpack (MC $mc) erwartet Java $need, Instanz-Profil hat Java $have. "
                . 'Java wird beim Import ggf. angepasst.';
        } elsif ($code eq 'loader_mismatch') {
            push @out, $t->('mc_modpack_adopt_loader_mismatch',
                    $pack->{'loader'} // '?',
                    $profile->{'loader'} // '?')
                || 'Hinweis (Adopt): Pack-Loader „'
                . ($pack->{'loader'} // '?')
                . '“ weicht von Instanz „'
                . ($profile->{'loader'} // '?')
                . '“ ab — Profil wird vom Pack übernommen.';
        } elsif ($code eq 'version_mismatch') {
            push @out, $t->('mc_modpack_adopt_version_mismatch',
                    $pack->{'mc_version'} // '?',
                    $profile->{'mc_version'} // '?')
                || 'Hinweis (Adopt): Pack-MC '
                . ($pack->{'mc_version'} // '?')
                . ' weicht von Instanz '
                . ($profile->{'mc_version'} // '?')
                . ' ab — Profil wird vom Pack übernommen.';
        } else {
            push @out, $code;
        }
    }
    return @out;
}

# Print compare + WARN from pack_meta (after job log truncate / install-ready path).
sub modpack_print_validation_report_from_meta {
    my ($meta, $server_dir, $text_ref) = @_;
    return 0 unless ref($meta) eq 'HASH';

    my $pack = {
        loader         => $meta->{'pack_loader'} // '',
        loader_version => $meta->{'pack_loader_version'} // '',
        mc_version     => $meta->{'pack_mc_version'} // '',
    };
    my $profile = $meta->{'profile'};
    if (ref($profile) ne 'HASH' && defined $server_dir && $server_dir =~ /\S/) {
        $profile = read_mc_profile($server_dir) if defined &read_mc_profile;
    }
    return 0 unless ref($profile) eq 'HASH';
    return 0 unless ($pack->{'loader'} ne '' || $pack->{'mc_version'} ne ''
        || @{ $meta->{'validation_warnings'} // [] });

    my $validation = {
        ok       => 1,
        errors   => [],
        warnings => [ @{ $meta->{'validation_warnings'} // [] } ],
    };
    return modpack_print_validation_report($pack, $profile, $validation, $text_ref);
}

# Print compare + WARN lines to STDOUT (worker / expand_meta).
sub modpack_print_validation_report {
    my ($pack, $profile, $validation, $text_ref) = @_;
    return 0 unless ref($pack) eq 'HASH' && ref($profile) eq 'HASH';
    $validation = { ok => 1, errors => [], warnings => [] }
        unless ref($validation) eq 'HASH';

    print "=== ";
    my ($header, $pack_line, $inst_line) =
        modpack_validation_compare_lines($pack, $profile, $text_ref);
    print "$header ===\n";
    print "$pack_line\n";
    print "$inst_line\n";

    my @warns = modpack_validation_warning_messages(
        $validation, $pack, $profile, $text_ref);
    if (@warns) {
        my $wh = _mc_modpack_text_lookup($text_ref)->('mc_modpack_validation_warn_header')
            || 'Versionshinweise (Import läuft trotzdem)';
        print "=== $wh ===\n";
        for my $w (@warns) {
            print "WARN: $w\n";
        }
    }
    return scalar @warns;
}

# Human-readable modpack import error (Webmin UI + job log). $text_ref optional (Webmin %text).
sub mc_modpack_error_message {
    my ($err, $detail, $profile, $text_ref) = @_;
    $detail  //= {};
    $profile //= {};
    $text_ref //= {};
    my $t = sub {
        my ($key, @repl) = @_;
        return _mc_modpack_apply_text($text_ref->{$key}, @repl) if $text_ref->{$key};
        return '';
    };
    my $mc     = $detail->{'mc'}     // ($profile->{'mc_version'} // '?');
    my $loader = $detail->{'loader'} // ($profile->{'loader'} // '?');
    my $pid    = $detail->{'project_id'} // '?';
    my $fid    = $detail->{'file_id'} // '?';
    my $host   = $detail->{'host'} // '?';

    if ($err eq 'curseforge_key_missing') {
        return $t->('mc_modpack_curseforge_key_missing')
            || 'CurseForge API-Key fehlt — unter Integrationen hinterlegen.';
    }
    if ($err eq 'mkdir') {
        my $mp = $detail->{'path'} // '?';
        my $oe = $detail->{'os_err'} // '?';
        return $t->('mc_modpack_resolve_failed_detail', "mkdir $mp ($oe)")
            || "Job-Upload-Verzeichnis konnte nicht erstellt werden ($mp): $oe";
    }
    if ($err eq 'invalid_project') {
        return $t->('mc_modpack_resolve_invalid_project', $pid)
            || "Ungültige Modpack-Projekt-ID: $pid";
    }
    if ($err eq 'curseforge_no_matching_file' || $err eq 'modrinth_no_matching_file') {
        return $t->('mc_modpack_resolve_no_file', $mc, $loader, $pid)
            || "Keine passende Modpack-Datei für Minecraft $mc mit Loader $loader (Projekt $pid).";
    }
    if ($err eq 'curseforge_profile_incomplete') {
        return $t->('mc_modpack_resolve_profile_incomplete', $mc, $loader)
            || "Instanz-Profil unvollständig (MC $mc, Loader $loader).";
    }
    if ($err eq 'curseforge_rate_limited') {
        my $mod_num = $detail->{'mod_num'} // (($detail->{'index'} // -1) + 1);
        return $t->('mc_modpack_curseforge_rate_limited', $mod_num, $pid, $fid)
            || $t->('mc_modpack_resolve_cf_api', $pid, $fid)
            || "CurseForge rate limit at mod $mod_num (project $pid, file $fid). "
            . "Wait 10–15 minutes, then use Download fortsetzen on the same job.";
    }
    if ($err eq 'curseforge_cdn_rate_limited') {
        my $mod_num = $detail->{'mod_num'} // (($detail->{'index'} // -1) + 1);
        my $base  = $detail->{'basename'} // '?';
        my $total = $detail->{'total'} // '?';
        return $t->('mc_modpack_curseforge_cdn_rate_limited', $mod_num, $base, $total)
            || "CurseForge CDN limit at mod $mod_num ($base) — normal for large packs ($total mods). "
            . "Wait 10–15 minutes, then use Download fortsetzen on the same job.";
    }
    if ($err eq 'curseforge_api_failed') {
        return $t->('mc_modpack_resolve_cf_api', $pid, $fid)
            || $t->('mc_modpack_curseforge_api_failed')
            || "CurseForge-API-Fehler (Projekt $pid, Datei $fid).";
    }
    if ($err eq 'curseforge_failed') {
        return $t->('mc_modpack_curseforge_api_failed')
            || 'CurseForge-API fehlgeschlagen beim Auflösen der Mod-Dateien.';
    }
    if ($err eq 'curseforge_download_url_missing') {
        return $t->('mc_modpack_resolve_cf_download', $pid, $fid)
            || "CurseForge lieferte keine Download-URL (Projekt $pid, Datei $fid).";
    }
    if ($err eq 'curseforge_download_host_blocked') {
        return $t->('mc_modpack_resolve_cf_host', $host, $pid)
            || "Download-Host nicht erlaubt: $host (Projekt $pid).";
    }
    if ($err eq 'loader_mismatch') {
        my $p_loader = $detail->{'pack_loader'} // $detail->{'loader'} // '?';
        my $i_loader = $detail->{'instance_loader'} // ($profile->{'loader'} // '?');
        return $t->('mc_modpack_loader_mismatch', $p_loader, $i_loader)
            || "Modpack benötigt Loader $p_loader, Instanz läuft mit $i_loader.";
    }
    if ($err eq 'version_mismatch') {
        my $p_mc = $detail->{'pack_mc'} // $detail->{'mc'} // '?';
        my $i_mc = $detail->{'instance_mc'} // ($profile->{'mc_version'} // '?');
        return $t->('mc_modpack_version_mismatch', $p_mc, $i_mc)
            || "Modpack benötigt Minecraft $p_mc, Instanz läuft mit $i_mc.";
    }
    if ($err eq 'modded_pack_on_vanilla') {
        return $t->('mc_modpack_modded_on_vanilla')
            || 'Modpack enthält Mods, Instanz ist Vanilla/Paper ohne Mod-Loader.';
    }
    if ($err eq 'download_failed') {
        return $t->('mc_modpack_job_download_failed')
            || 'Modpack-Download fehlgeschlagen (Netzwerk, CDN oder CurseForge-Key für forgecdn.net).';
    }
    if ($err eq 'invalid_pack') {
        return $t->('mc_modpack_invalid')
            || 'Ungültiges Modpack-Format (.mrpack oder CurseForge-ZIP erwartet).';
    }
    if ($err eq 'validation_failed') {
        return $t->('mc_modpack_job_validation_failed')
            || 'Modpack passt nicht zum Instanz-Profil (Loader oder Minecraft-Version).';
    }
    if ($err eq 'no_server_mods') {
        return $t->('mc_modpack_no_server_mods')
            || 'Keine server-tauglichen Mods im Pack gefunden.';
    }
    if ($err eq 'invalid_source') {
        return $t->('mc_modpack_resolve_invalid_source')
            || $t->('mc_modpack_resolve_failed')
            || 'Unbekannte Modpack-Quelle.';
    }
    if ($err eq 'too_large') {
        return $t->('mc_modpack_too_large')
            || 'Modpack zu gross (serverseitiges Limit: 800 MB).';
    }
    if ($err eq 'write_meta') {
        return $t->('mc_modpack_write_meta_failed')
            || 'Modpack-Metadaten konnten nicht gespeichert werden (Job-Verzeichnis beschreibbar?).';
    }
    return $t->('mc_modpack_resolve_failed_detail', $err // 'unknown')
        || $t->('mc_modpack_resolve_failed')
        || "Modpack-Import fehlgeschlagen ($err).";
}

sub _modpack_chown_to_user {
    my ($unix_user, @paths) = @_;
    return unless defined $unix_user && $unix_user ne '';
    my @pw = getpwnam($unix_user);
    return unless @pw;
    for my $p (@paths) {
        next unless defined $p && -e $p;
        chown($pw[2], $pw[3], $p);
    }
}

# Atomic JSON write; unlinks root-owned target in game-user job dir when not writable.
sub _modpack_ensure_dir {
    my ($dir, $mode) = @_;
    return 0 unless defined $dir && $dir =~ /\S/;
    $mode = 0750 unless defined $mode;
    return 1 if -d $dir;
    return 0 if -e $dir && !-d $dir;
    return mkdir($dir, $mode) ? 1 : 0;
}

sub _modpack_save_expand_draft_meta {
    my ($job_dir, $meta, $path) = @_;
    return 0 unless defined $job_dir && ref($meta) eq 'HASH';
    return 0 unless defined $path && -f $path;
    $meta->{'pack_file'} = $path;
    delete $meta->{'remote_pending'};
    return write_modpack_job_meta($job_dir, $meta, undef);
}

sub _modpack_atomic_write_json {
    my ($path, $json) = @_;
    return 0 unless defined $path && $path =~ /\S/ && defined $json;
    if (-e $path && !-w $path) {
        unlink($path) or return 0;
    }
    my $tmp = "$path.$$.tmp";
    open(my $fh, '>', $tmp) or return 0;
    print $fh $json or do { unlink($tmp); return 0; };
    close($fh) or do { unlink($tmp); return 0; };
    if (!rename($tmp, $path)) {
        unlink($path) if -e $path;
        rename($tmp, $path) or do { unlink($tmp); return 0; };
    }
    return 1;
}

sub write_modpack_job_meta {
    my ($job_dir, $meta, $unix_user) = @_;
    return 0 unless defined $job_dir && -d $job_dir && ref($meta) eq 'HASH';
    my $json = encode_json($meta);
    my $path = "$job_dir/pack_meta.json";
    return 0 unless _modpack_atomic_write_json($path, $json);
    _modpack_chown_to_user($unix_user, $path) if defined $unix_user && $unix_user ne '';
    return 1;
}

sub modrinth_resolve_modpack_file {
    my ($project_id, $profile) = @_;
    return undef unless defined $project_id && $project_id =~ /\S/;
    return undef unless ref($profile) eq 'HASH';
    $project_id =~ s/[^a-zA-Z0-9_-]//g;
    my $mc = $profile->{'mc_version'} // '';
    $mc =~ s/[^0-9.]//g;
    my $loader = mc_loader_modrinth_slug($profile->{'loader'} // '');
    return undef unless $mc && $loader;
    my $loaders = _mc_mods_urlencode(encode_json([$loader]));
    my $vers    = _mc_mods_urlencode(encode_json([$mc]));
    my $url = "https://api.modrinth.com/v2/project/$project_id/version"
        . "?loaders=$loaders&game_versions=$vers";
    my $list = _modpack_http_get_json($url, {
        'User-Agent' => modrinth_user_agent(),
    });
    return undef unless ref($list) eq 'ARRAY' && @$list;
    for my $ver (@$list) {
        next unless ref($ver) eq 'HASH';
        for my $f (@{ $ver->{'files'} // [] }) {
            next unless ref($f) eq 'HASH';
            my $fname = $f->{'filename'} // '';
            next unless $fname =~ /\.mrpack\z/i || ($f->{'primary'} // 0);
            my $dl = _modrinth_file_download_url($f);
            next unless $dl;
            $fname =~ s/[^a-zA-Z0-9._-]//g;
            $fname = 'pack.mrpack' unless $fname =~ /\.mrpack\z/i;
            return {
                version_id   => $ver->{'id'} // '',
                filename     => $fname,
                download_url => $dl,
            };
        }
    }
    return undef;
}

sub modrinth_resolve_modpack_version_by_id {
    my ($version_id, $profile) = @_;
    $version_id =~ s/[^a-zA-Z0-9_-]//g;
    return undef unless $version_id;
    my $ver = _modpack_http_get_json(
        "https://api.modrinth.com/v2/version/$version_id",
        { 'User-Agent' => modrinth_user_agent() },
    );
    return undef unless ref($ver) eq 'HASH';
    if (ref($profile) eq 'HASH') {
        my $mc = $profile->{'mc_version'} // '';
        $mc =~ s/[^0-9.]//g;
        my $loader = mc_loader_modrinth_slug($profile->{'loader'} // '');
        if ($mc && $loader) {
            my @gvs = @{ $ver->{'game_versions'} // [] };
            my @lds = @{ $ver->{'loaders'} // [] };
            return undef unless grep { $_ eq $mc } @gvs;
            return undef unless grep { $_ eq $loader } @lds;
        }
    }
    for my $f (@{ $ver->{'files'} // [] }) {
        next unless ref($f) eq 'HASH';
        my $fname = $f->{'filename'} // '';
        next unless $fname =~ /\.mrpack\z/i || ($f->{'primary'} // 0);
        my $dl = _modrinth_file_download_url($f);
        next unless $dl;
        $fname =~ s/[^a-zA-Z0-9._-]//g;
        $fname = 'pack.mrpack' unless $fname =~ /\.mrpack\z/i;
        return {
            version_id   => $version_id,
            filename     => $fname,
            download_url => $dl,
        };
    }
    return undef;
}

# Search query variants (abbreviations, slug-style names).
sub mc_modpack_search_query_variants {
    my ($query) = @_;
    my $q = $query // '';
    $q =~ s/[\t\n\r\0]//g;
    $q =~ s/^\s+|\s+$//g;
    return () unless $q =~ /\S/;
    my %seen;
    my @variants;
    for my $c ($q) {
        next unless $c =~ /\S/;
        next if $seen{lc($c)}++;
        push @variants, $c;
    }
    my $lc = lc($q);
    if ($lc =~ /\bsky\b|atm10sky|to\s+the\s+sky|\btts\b/) {
        for my $extra (
            'All the Mods 10 To the Sky',
            'All the Mods 10 Sky',
            'ATM10 Sky',
            'ATM10SKY',
            'all-the-mods-10-sky',
        ) {
            next if $seen{lc($extra)}++;
            $seen{lc($extra)} = 1;
            push @variants, $extra;
        }
    }
    if ($lc =~ /\b(atm\s*10|all\s+the\s+mods\s*10)\b/ || $lc =~ /^atm10$/) {
        for my $extra ('All the Mods 10', 'all-the-mods-10', 'ATM10') {
            next if $seen{lc($extra)}++;
            $seen{lc($extra)} = 1;
            push @variants, $extra;
        }
    }
    if ($lc =~ /\b(atm\s*9|all\s+the\s+mods\s*9)\b/ || $lc =~ /^atm9$/) {
        for my $extra ('All the Mods 9', 'all-the-mods-9') {
            next if $seen{lc($extra)}++;
            $seen{lc($extra)} = 1;
            push @variants, $extra;
        }
    }
    if ($lc =~ /^atm$/ || ($lc =~ /\ball\s+the\s+mods\b/ && $lc !~ /\d/)) {
        my $extra = 'All the Mods';
        unless ($seen{lc($extra)}++) {
            push @variants, $extra;
        }
    }
    return @variants;
}

# Known CurseForge slugs for common abbreviations (ATM10 is CF-only).
sub mc_modpack_guess_curseforge_slugs {
    my ($query) = @_;
    my $q = lc($query // '');
    $q =~ s/^\s+|\s+$//g;
    my @slugs;
    my $want_sky = ($q =~ /\bsky\b|atm10sky|to\s+the\s+sky|\btts\b/);
    my $want_atm10 = ($q =~ /\ball\s+the\s+mods\s+10\b/ || $q =~ /^atm\s*10$|^atm10$/ || $q =~ /\batm10\b/);
    if ($want_sky || $want_atm10) {
        if ($want_sky) {
            push @slugs, 'all-the-mods-10-sky', 'all-the-mods-10';
        } else {
            push @slugs, 'all-the-mods-10', 'all-the-mods-10-sky';
        }
    }
    if ($q =~ /\ball\s+the\s+mods\s+9\b/ || $q =~ /^atm\s*9$|^atm9$/) {
        push @slugs, 'all-the-mods-9';
    }
    if ($q =~ /\ball\s+the\s+mods\b/ && $q !~ /\b(10|9|8|7|6|5)\b/) {
        push @slugs, 'all-the-mods-10', 'all-the-mods-9';
    }
    my %seen;
    return grep { !$seen{$_}++ } @slugs;
}

sub mc_modpack_query_likely_curseforge_only {
    my ($query) = @_;
    my $q = lc($query // '');
    return 1 if $q =~ /\batm\d*\b|all\s+the\s+mods/;
    return 0;
}

sub _modpack_dedupe_key {
    my ($r) = @_;
    return '' unless ref($r) eq 'HASH';
    return ($r->{'source'} // '') . ':' . ($r->{'project_id'} // '');
}

sub _modpack_merge_results {
    my (@lists) = @_;
    my %seen;
    my @out;
    for my $list (@lists) {
        next unless ref($list) eq 'ARRAY';
        for my $r (@$list) {
            next unless ref($r) eq 'HASH';
            my $k = _modpack_dedupe_key($r);
            next unless $k =~ /:\S/;
            next if $seen{$k}++;
            push @out, $r;
        }
    }
    return @out;
}

sub _modpack_curseforge_is_modpack {
    my ($mod) = @_;
    return 0 unless ref($mod) eq 'HASH';
    return 1 if defined $mod->{'classId'} && $mod->{'classId'} == 4471;
    my $slug = lc($mod->{'slug'} // '');
    return 1 if $slug =~ /^all-the-mods(?:-\d+)?(?:-sky|-to-the-sky)?$/;
    for my $c (@{ $mod->{'categories'} // [] }) {
        if (ref($c) eq 'HASH') {
            my $cs = lc($c->{'slug'} // '');
            return 1 if $cs eq 'modpacks' || $cs =~ /modpack/;
        }
    }
    return 0;
}

sub _curseforge_file_matches_profile {
    my ($f, $mc, $loader_type) = @_;
    return 0 unless ref($f) eq 'HASH';
    my @vers;
    push @vers, @{ $f->{'gameVersions'} // [] };
    for my $sgv (@{ $f->{'sortableGameVersions'} // [] }) {
        push @vers, $sgv->{'gameVersion'} if ref($sgv) eq 'HASH' && ($sgv->{'gameVersion'} // '') =~ /\S/;
    }
    if ($mc && @vers) {
        my $ok_ver;
        for my $v (@vers) {
            next unless defined $v && $v =~ /\S/;
            if ($v eq $mc || index($v, $mc) == 0) {
                $ok_ver = 1;
                last;
            }
        }
        return 0 unless $ok_ver;
    }
    if (defined $loader_type && ref($f->{'modLoaders'}) eq 'ARRAY' && @{ $f->{'modLoaders'} }) {
        my %want = (
            1 => 'forge', 4 => 'fabric', 5 => 'quilt', 6 => 'neoforge',
        );
        my $want_name = lc($want{$loader_type} // '');
        my $ok_loader;
        for my $ml (@{ $f->{'modLoaders'} }) {
            if (!ref($ml)) {
                $ok_loader = 1 if $want_name && lc($ml) eq $want_name;
            }
            elsif (ref($ml) eq 'HASH') {
                $ok_loader = 1 if ($ml->{'id'} // 0) == $loader_type;
                my $n = lc($ml->{'name'} // '');
                $ok_loader = 1 if $want_name && ($n eq $want_name || index($n, $want_name) >= 0);
            }
        }
        return 0 unless $ok_loader;
    }
    return 1;
}

# Extract the Minecraft versions and loader names declared on a CurseForge
# file entry, for display in search results. Returns (\@mc, \@loaders).
sub _curseforge_file_display_versions {
    my ($f) = @_;
    my (@mc, @loaders);
    return (\@mc, \@loaders) unless ref($f) eq 'HASH';
    my @raw = @{ $f->{'gameVersions'} // [] };
    for my $sgv (@{ $f->{'sortableGameVersions'} // [] }) {
        push @raw, $sgv->{'gameVersion'}
            if ref($sgv) eq 'HASH' && ($sgv->{'gameVersion'} // '') =~ /\S/;
    }
    my %loader_names = map { $_ => 1 } qw(forge fabric quilt neoforge liteloader);
    for my $v (@raw) {
        next unless defined $v && $v =~ /\S/;
        if ($v =~ /^\d+\.\d+/) {
            push @mc, $v unless grep { $_ eq $v } @mc;
        }
        else {
            (my $lv = lc($v)) =~ s/\s+//g;
            push @loaders, $v if $loader_names{$lv} && !grep { lc($_) eq lc($v) } @loaders;
        }
    }
    for my $ml (@{ $f->{'modLoaders'} // [] }) {
        my $name;
        if    (ref($ml) eq 'HASH') { $name = $ml->{'name'} // ''; }
        elsif (!ref($ml))          { $name = $ml // ''; }
        next unless defined $name && $name =~ /\S/;
        push @loaders, $name unless grep { lc($_) eq lc($name) } @loaders;
    }
    return (\@mc, \@loaders);
}

# Determine whether a CurseForge mod (project) has any file compatible with the
# instance profile, and pick a MC version + loader label to display.
# Returns { compatible => 0|1, mc => '', loader => '' }.
# compatible is only 0 when we have version info AND no file matches — packs
# with no usable version metadata stay compatible (avoid false negatives).
sub curseforge_mod_compat_info {
    my ($mod, $profile) = @_;
    my %info = (compatible => 1, mc => '', loader => '');
    return \%info unless ref($mod) eq 'HASH' && ref($profile) eq 'HASH';
    my $files = $mod->{'latestFiles'};
    return \%info unless ref($files) eq 'ARRAY' && @$files;
    my $mc = $profile->{'mc_version'} // '';
    $mc =~ s/[^0-9.]//g;
    my $loader_type = curseforge_mod_loader_type($profile->{'loader'} // '');
    my ($has_match, $have_info, $disp_mc, $disp_loader);
    for my $f (@$files) {
        next unless ref($f) eq 'HASH';
        next if ($f->{'isServerPack'} // 0);
        my ($mcs, $lds) = _curseforge_file_display_versions($f);
        $have_info = 1 if @$mcs;
        my $match = _curseforge_file_matches_profile($f, $mc, $loader_type);
        $has_match = 1 if $match;
        # Prefer the matching file's labels; otherwise fall back to the newest.
        if ($match) {
            $disp_mc     = $mcs->[0] if @$mcs && (!defined $disp_mc || !$has_match);
            $disp_loader = $lds->[0] if @$lds;
        }
        $disp_mc     //= $mcs->[0] if @$mcs;
        $disp_loader //= $lds->[0] if @$lds;
    }
    $info{'mc'}         = $disp_mc     // '';
    $info{'loader'}     = $disp_loader // '';
    $info{'compatible'} = ($have_info && !$has_match) ? 0 : 1;
    return \%info;
}

sub _curseforge_pack_file_from_entry {
    my ($project_id, $f, $key) = @_;
    return undef unless ref($f) eq 'HASH';
    return undef if ($f->{'isServerPack'} // 0);
    my $fid = $f->{'id'};
    return undef unless defined $fid;
    my $fname = $f->{'fileName'} // '';
    return undef unless $fname =~ /\.(?:zip|mrpack)\z/i;
    my $dl = curseforge_file_download_url($project_id, $fid, $key);
    return undef unless $dl;
    $fname =~ s/[^a-zA-Z0-9._-]//g;
    $fname = 'pack.zip' unless $fname =~ /\.(?:zip|mrpack)\z/i;
    return {
        file_id      => $fid,
        filename     => $fname,
        download_url => $dl,
    };
}

sub _curseforge_pick_modpack_file_meta {
    my ($profile, $files_ref) = @_;
    return undef unless ref($profile) eq 'HASH' && ref($files_ref) eq 'ARRAY';
    my $mc = $profile->{'mc_version'} // '';
    $mc =~ s/[^0-9.]//g;
    my $loader_type = curseforge_mod_loader_type($profile->{'loader'} // '');
    for my $f (@$files_ref) {
        next unless ref($f) eq 'HASH';
        next if ($f->{'isServerPack'} // 0);
        next unless _curseforge_file_matches_profile($f, $mc, $loader_type);
        my $fid = $f->{'id'};
        next unless defined $fid;
        my $fname = $f->{'fileName'} // '';
        next unless $fname =~ /\.(?:zip|mrpack)\z/i;
        $fname =~ s/[^a-zA-Z0-9._-]//g;
        $fname = 'pack.zip' unless $fname =~ /\.(?:zip|mrpack)\z/i;
        return { file_id => $fid, filename => $fname };
    }
    for my $f (@$files_ref) {
        next unless ref($f) eq 'HASH';
        next if ($f->{'isServerPack'} // 0);
        my $fid = $f->{'id'};
        next unless defined $fid;
        my $fname = $f->{'fileName'} // '';
        next unless $fname =~ /\.(?:zip|mrpack)\z/i;
        $fname =~ s/[^a-zA-Z0-9._-]//g;
        $fname = 'pack.zip' unless $fname =~ /\.(?:zip|mrpack)\z/i;
        return { file_id => $fid, filename => $fname };
    }
    return undef;
}

sub _curseforge_pick_modpack_file {
    my ($project_id, $profile, $files_ref) = @_;
    our %config;
    my $key = $config{'curseforge_api_key'} // '';
    return undef unless $key =~ /\S/;
    $project_id =~ s/\D//g;
    return undef unless $project_id && ref($files_ref) eq 'ARRAY';
    my $mc = $profile->{'mc_version'} // '';
    $mc =~ s/[^0-9.]//g;
    my $loader_type = curseforge_mod_loader_type($profile->{'loader'} // '');
    for my $f (@$files_ref) {
        next unless ref($f) eq 'HASH';
        next if ($f->{'isServerPack'} // 0);
        next unless _curseforge_file_matches_profile($f, $mc, $loader_type);
        my $picked = _curseforge_pack_file_from_entry($project_id, $f, $key);
        return $picked if $picked;
    }
    for my $f (@$files_ref) {
        next unless ref($f) eq 'HASH';
        next if ($f->{'isServerPack'} // 0);
        my $picked = _curseforge_pack_file_from_entry($project_id, $f, $key);
        return $picked if $picked;
    }
    return undef;
}

sub curseforge_fetch_mod {
    my ($project_id) = @_;
    our %config;
    my $key = $config{'curseforge_api_key'} // '';
    return undef unless $key =~ /\S/;
    $project_id =~ s/\D//g;
    return undef unless $project_id;
    my $resp = _modpack_http_get_json_import(
        "https://api.curseforge.com/v1/mods/$project_id",
        { 'x-api-key' => $key },
    );
    return undef unless ref($resp) eq 'HASH' && ref($resp->{'data'}) eq 'HASH';
    return $resp->{'data'};
}

sub _modpack_hit_from_curseforge_mod {
    my ($mod, $profile) = @_;
    return () unless ref($mod) eq 'HASH';
    my $pid = $mod->{'id'};
    return () unless defined $pid;
    my $file_id  = '';
    my $filename = 'pack.zip';
    my $compat_src = (ref($mod->{'latestFiles'}) eq 'ARRAY' && @{ $mod->{'latestFiles'} })
        ? $mod : undef;
    if (ref($mod->{'latestFiles'}) eq 'ARRAY') {
        my $meta = _curseforge_pick_modpack_file_meta($profile, $mod->{'latestFiles'});
        if ($meta) {
            $file_id  = $meta->{'file_id'} // '';
            $filename = $meta->{'filename'} // $filename;
        }
    }
    if (!$file_id) {
        my $full = (ref($mod->{'latestFiles'}) eq 'ARRAY' && @{ $mod->{'latestFiles'} })
            ? $mod
            : curseforge_fetch_mod($pid);
        $compat_src //= $full
            if ref($full) eq 'HASH' && ref($full->{'latestFiles'}) eq 'ARRAY';
        if (ref($full) eq 'HASH' && ref($full->{'latestFiles'}) eq 'ARRAY') {
            my $meta = _curseforge_pick_modpack_file_meta($profile, $full->{'latestFiles'});
            if ($meta) {
                $file_id  = $meta->{'file_id'} // '';
                $filename = $meta->{'filename'} // $filename;
            }
        }
        if (!$file_id && ref($full) eq 'HASH') {
            my $fetched = _curseforge_fetch_modpack_file_meta($pid, $profile);
            if ($fetched) {
                $file_id  = $fetched->{'file_id'} // '';
                $filename = $fetched->{'filename'} // $filename;
            }
        }
    }
    my $compat = curseforge_mod_compat_info($compat_src // $mod, $profile);
    return {
        source       => 'curseforge',
        project_id   => $pid,
        file_id      => $file_id,
        title        => $mod->{'name'} // '',
        description  => substr($mod->{'summary'} // '', 0, 200),
        downloads    => $mod->{'downloadCount'} // 0,
        filename     => $filename,
        compatible   => $compat->{'compatible'},
        pack_mc      => $compat->{'mc'},
        pack_loader  => $compat->{'loader'},
    };
}

sub _modpack_hit_from_modrinth {
    my ($hit, $profile) = @_;
    return () unless ref($hit) eq 'HASH';
    my $pid = $hit->{'project_id'} // $hit->{'slug'} // '';
    return () unless $pid =~ /\S/;
    return {
        source       => 'modrinth',
        project_id   => $hit->{'project_id'} // '',
        version_id   => '',
        title        => $hit->{'title'} // $hit->{'slug'} // '',
        description  => substr($hit->{'description'} // '', 0, 200),
        downloads    => $hit->{'downloads'} // 0,
        filename     => 'pack.mrpack',
    };
}

sub modrinth_search_modpacks {
    my ($query, $profile) = @_;
    return () unless defined $query && $query =~ /\S/;
    return () unless ref($profile) eq 'HASH';
    my $loader_slug = mc_loader_modrinth_slug($profile->{'loader'} // '');
    my %seen;
    my @out;
    for my $q (mc_modpack_search_query_variants($query)) {
        for my $facet_mode ($loader_slug ? qw(loader type_only) : qw(type_only)) {
            my @facets = (['project_type:modpack']);
            push @facets, ["categories:$loader_slug"] if $facet_mode eq 'loader' && $loader_slug;
            my $facets = _mc_mods_urlencode(encode_json(\@facets));
            my $enc_q = _mc_mods_urlencode($q);
            my $url = "https://api.modrinth.com/v2/search?query=$enc_q&limit=15&index=downloads&facets=$facets";
            my $resp = _modpack_http_get_json($url, {
                'User-Agent' => modrinth_user_agent(),
            });
            next unless ref($resp) eq 'HASH' && ref($resp->{'hits'}) eq 'ARRAY';
            for my $hit (@{ $resp->{'hits'} }) {
                my $r = _modpack_hit_from_modrinth($hit, $profile);
                next unless $r;
                my $k = _modpack_dedupe_key($r);
                next if $seen{$k}++;
                $seen{$k} = 1;
                push @out, $r;
            }
            last if @out >= 15;
        }
        last if @out >= 15;
    }
    return @out;
}

sub curseforge_resolve_modpack_file {
    my ($project_id, $profile, $mod_hint) = @_;
    our %config;
    my $key = $config{'curseforge_api_key'} // '';
    return (undef, 'curseforge_key_missing', undef) unless $key =~ /\S/;
    $project_id =~ s/\D//g;
    return (undef, 'invalid_project', { project_id => $project_id // '' })
        unless $project_id;
    return (undef, 'missing_profile', undef) unless ref($profile) eq 'HASH';
    my $mc = $profile->{'mc_version'} // '';
    $mc =~ s/[^0-9.]//g;
    my $loader = $profile->{'loader'} // '';
    my $loader_type = curseforge_mod_loader_type($loader);
    my %detail = (
        mc         => $mc || ($profile->{'mc_version'} // '?'),
        loader     => $loader || '?',
        project_id => $project_id,
    );
    unless ($mc && defined $loader_type) {
        return (undef, 'curseforge_profile_incomplete', \%detail);
    }

    my ($last_err, $last_detail);
    my $try_build = sub {
        my ($meta) = @_;
        return unless ref($meta) eq 'HASH' && $meta->{'file_id'};
        my ($file, $err, $d) = _curseforge_build_modpack_file(
            $project_id, $meta->{'file_id'}, $key, $meta->{'filename'});
        return $file if $file;
        $last_err    = $err    if $err;
        $last_detail = $d      if ref($d) eq 'HASH';
        return;
    };

    if (ref($mod_hint) eq 'HASH' && ref($mod_hint->{'latestFiles'}) eq 'ARRAY') {
        my $meta = _curseforge_pick_modpack_file_meta($profile, $mod_hint->{'latestFiles'});
        my $file = $try_build->($meta);
        return ($file, undef, undef) if $file;
    }

    my $meta = _curseforge_fetch_modpack_file_meta($project_id, $profile);
    if ($meta) {
        my $file = $try_build->($meta);
        return ($file, undef, undef) if $file;
    } else {
        $last_err //= 'curseforge_no_matching_file';
        $last_detail //= \%detail;
    }

    my $mod_full = curseforge_fetch_mod($project_id);
    if (ref($mod_full) eq 'HASH' && ref($mod_full->{'latestFiles'}) eq 'ARRAY') {
        my $meta2 = _curseforge_pick_modpack_file_meta($profile, $mod_full->{'latestFiles'});
        my $file = $try_build->($meta2);
        return ($file, undef, undef) if $file;
    } elsif (!ref($mod_full)) {
        $last_err    = 'curseforge_api_failed';
        $last_detail = \%detail;
    }

    if (!$meta && !$last_err) {
        $last_err    = 'curseforge_no_matching_file';
        $last_detail = \%detail;
    }
    return (undef, $last_err // 'curseforge_no_matching_file', $last_detail // \%detail);
}

sub _curseforge_modpack_search_url {
    my ($query, $mc, $loader_type, $mode) = @_;
    my $q = _mc_mods_urlencode($query);
    my $url = "https://api.curseforge.com/v1/mods/search?gameId=432&classId=4471"
        . "&pageSize=15&sortField=2&sortOrder=desc&searchFilter=$q";
    if ($mode eq 'strict') {
        $url .= "&gameVersion=" . _mc_mods_urlencode($mc) if $mc;
        $url .= "&modLoaderType=$loader_type" if defined $loader_type;
    }
    elsif ($mode eq 'version_only') {
        $url .= "&gameVersion=" . _mc_mods_urlencode($mc) if $mc;
    }
    return $url;
}

sub curseforge_search_modpack_by_slug {
    my ($slug, $profile) = @_;
    $slug =~ s/[^a-z0-9_-]//g;
    return () unless $slug && ref($profile) eq 'HASH';
    our %config;
    my $key = $config{'curseforge_api_key'} // '';
    return () unless $key =~ /\S/;
    my $url = "https://api.curseforge.com/v1/mods/search?gameId=432&slug="
        . _mc_mods_urlencode($slug);
    my $resp = _modpack_http_get_json($url, { 'x-api-key' => $key });
    return () unless ref($resp) eq 'HASH' && ref($resp->{'data'}) eq 'ARRAY';
    my @out;
    for my $mod (@{ $resp->{'data'} }) {
        my $r = _modpack_hit_from_curseforge_mod($mod, $profile);
        push @out, $r if $r;
    }
    if (!@out) {
        my $url2 = "https://api.curseforge.com/v1/mods/search?gameId=432&classId=4471"
            . "&pageSize=5&searchFilter=" . _mc_mods_urlencode($slug);
        my $resp2 = _modpack_http_get_json($url2, { 'x-api-key' => $key });
        if (ref($resp2) eq 'HASH' && ref($resp2->{'data'}) eq 'ARRAY') {
            for my $mod (@{ $resp2->{'data'} }) {
                next unless ref($mod) eq 'HASH';
                my $mod_slug = lc($mod->{'slug'} // '');
                next unless $mod_slug eq lc($slug);
                my $r = _modpack_hit_from_curseforge_mod($mod, $profile);
                push @out, $r if $r;
            }
        }
    }
    return @out;
}

sub curseforge_search_modpacks {
    my ($query, $profile) = @_;
    return () unless defined $query && $query =~ /\S/;
    return () unless ref($profile) eq 'HASH';
    our %config;
    my $key = $config{'curseforge_api_key'} // '';
    return () unless $key =~ /\S/;
    my $mc = $profile->{'mc_version'} // '';
    $mc =~ s/[^0-9.]//g;
    my $loader_type = curseforge_mod_loader_type($profile->{'loader'} // '');
    return () unless $mc && defined $loader_type;

    my %seen;
    my @out;
    my $add_mod = sub {
        my ($mod) = @_;
        return unless ref($mod) eq 'HASH';
        my $r = _modpack_hit_from_curseforge_mod($mod, $profile);
        return unless $r;
        my $k = _modpack_dedupe_key($r);
        return if $seen{$k}++;
        $seen{$k} = 1;
        push @out, $r;
        return scalar @out >= 15;
    };

    for my $slug (mc_modpack_guess_curseforge_slugs($query)) {
        for my $r (curseforge_search_modpack_by_slug($slug, $profile)) {
            my $k = _modpack_dedupe_key($r);
            next if $seen{$k}++;
            $seen{$k} = 1;
            push @out, $r;
        }
        last if @out >= 15;
    }

    my @queries = mc_modpack_search_query_variants($query);
    @queries = @queries[0 .. 1] if @queries > 2;
    for my $q (@queries) {
        for my $mode (qw(strict broad)) {
            my $url = _curseforge_modpack_search_url($q, $mc, $loader_type, $mode);
            my $resp = _modpack_http_get_json($url, { 'x-api-key' => $key });
            next unless ref($resp) eq 'HASH' && ref($resp->{'data'}) eq 'ARRAY';
            for my $mod (@{ $resp->{'data'} }) {
                last if $add_mod->($mod);
            }
            last if @out >= 15;
        }
        last if @out >= 15;
    }
    return @out;
}

# --- Version-less "open" search (modpack-first flow in the wizard) -----------
# Builds a search hit that carries the pack's own target MC version + loader,
# so the caller can prefill the profile without a second resolve round-trip.

sub _modpack_open_supported_loader {
    my ($name) = @_;
    my $id = defined &mc_loader_id_from_name ? mc_loader_id_from_name($name) : undef;
    return undef unless defined $id;
    # Only loaders the wizard can actually provision as modded.
    return (defined &mc_loader_is_modded && mc_loader_is_modded($id)) ? $id : undef;
}

sub _modpack_open_hit_from_curseforge_mod {
    my ($mod) = @_;
    return () unless ref($mod) eq 'HASH';
    my $pid = $mod->{'id'};
    return () unless defined $pid;
    my $files = $mod->{'latestFiles'};
    return () unless ref($files) eq 'ARRAY' && @$files;
    my ($mc, $loader_id, $loader_label, $file_id, $filename);
    for my $f (@$files) {
        next unless ref($f) eq 'HASH';
        next if ($f->{'isServerPack'} // 0);
        my ($mcs, $lds) = _curseforge_file_display_versions($f);
        next unless @$mcs;
        my $lid;
        for my $ln (@$lds) {
            $lid = _modpack_open_supported_loader($ln);
            if ($lid) { $loader_label = $ln; last; }
        }
        next unless $lid;
        $mc        = $mcs->[0];
        $loader_id = $lid;
        my $fid   = $f->{'id'};
        my $fname = $f->{'fileName'} // '';
        if (defined $fid && $fname =~ /\.(?:zip|mrpack)\z/i) {
            $fname =~ s/[^a-zA-Z0-9._-]//g;
            $file_id  = $fid;
            $filename = $fname;
        }
        last;
    }
    return () unless $mc && $loader_id;
    return {
        source       => 'curseforge',
        project_id   => $pid,
        file_id      => $file_id // '',
        version_id   => '',
        title        => $mod->{'name'} // '',
        description  => substr($mod->{'summary'} // '', 0, 200),
        downloads    => $mod->{'downloadCount'} // 0,
        filename     => $filename // 'pack.zip',
        pack_mc      => $mc,
        loader       => $loader_id,
        loader_label => $loader_label // $loader_id,
    };
}

sub _modpack_open_hit_from_modrinth {
    my ($hit) = @_;
    return () unless ref($hit) eq 'HASH';
    my $pid = $hit->{'project_id'} // $hit->{'slug'} // '';
    return () unless $pid =~ /\S/;
    my ($loader_id, $loader_label);
    my @cats = (@{ $hit->{'categories'} // [] }, @{ $hit->{'display_categories'} // [] });
    for my $c (@cats) {
        my $lid = _modpack_open_supported_loader($c);
        if ($lid) { $loader_id = $lid; $loader_label = $c; last; }
    }
    return () unless $loader_id;
    my $mc;
    for my $v (@{ $hit->{'versions'} // [] }) {
        next unless defined $v && $v =~ /^\d+\.\d+(?:\.\d+)?$/;
        $mc = $v;   # keep last (highest) release-style version
    }
    return () unless $mc;
    return {
        source       => 'modrinth',
        project_id   => $hit->{'project_id'} // '',
        file_id      => '',
        version_id   => '',
        title        => $hit->{'title'} // $hit->{'slug'} // '',
        description  => substr($hit->{'description'} // '', 0, 200),
        downloads    => $hit->{'downloads'} // 0,
        filename     => 'pack.mrpack',
        pack_mc      => $mc,
        loader       => $loader_id,
        loader_label => $loader_label // $loader_id,
    };
}

# Version-less modpack search across Modrinth + CurseForge.
# Returns { ok => 1, results => [...], errors => [...] }.
sub mc_modpack_search_open {
    my ($query) = @_;
    my @errors;
    return { ok => 0, results => [], errors => ['empty_query'] }
        unless defined $query && $query =~ /\S/;

    my %seen;
    my @out;
    my $add = sub {
        my ($r) = @_;
        return 0 unless ref($r) eq 'HASH';
        my $k = ($r->{'source'} // '') . ':' . ($r->{'project_id'} // '');
        return 0 if $seen{$k}++;
        push @out, $r;
        return scalar @out >= 20;
    };

    # Modrinth: modpacks, no loader facet, no version filter.
    for my $q (mc_modpack_search_query_variants($query)) {
        my $facets = _mc_mods_urlencode(encode_json([['project_type:modpack']]));
        my $enc_q  = _mc_mods_urlencode($q);
        my $url = "https://api.modrinth.com/v2/search?query=$enc_q&limit=20&index=downloads&facets=$facets";
        my $resp = _modpack_http_get_json($url, { 'User-Agent' => modrinth_user_agent() });
        if (ref($resp) eq 'HASH' && ref($resp->{'hits'}) eq 'ARRAY') {
            for my $hit (@{ $resp->{'hits'} }) {
                my $r = _modpack_open_hit_from_modrinth($hit);
                last if $r && $add->($r);
            }
        }
        last if @out >= 20;
    }

    # CurseForge: modpack class, no gameVersion/modLoaderType filter.
    our %config;
    if (($config{'curseforge_api_key'} // '') =~ /\S/) {
        my $key = $config{'curseforge_api_key'};
        for my $q (mc_modpack_search_query_variants($query)) {
            my $url = "https://api.curseforge.com/v1/mods/search?gameId=432&classId=4471"
                . "&pageSize=20&sortField=2&sortOrder=desc&searchFilter="
                . _mc_mods_urlencode($q);
            my $resp = _modpack_http_get_json($url, { 'x-api-key' => $key });
            if (ref($resp) eq 'HASH' && ref($resp->{'data'}) eq 'ARRAY') {
                for my $mod (@{ $resp->{'data'} }) {
                    my $r = _modpack_open_hit_from_curseforge_mod($mod);
                    last if $r && $add->($r);
                }
            }
            last if @out >= 20;
        }
    }
    elsif (mc_modpack_query_likely_curseforge_only($query)) {
        push @errors, 'curseforge_key_missing';
    }

    @out = sort { ($b->{'downloads'} // 0) <=> ($a->{'downloads'} // 0) } @out;
    return { ok => 1, results => \@out, errors => \@errors };
}

# Unified modpack search — { ok => 1, results => [...], errors => [...] }
sub mc_modpack_search {
    my ($query, $profile) = @_;
    my @errors;
    my @results;
    return { ok => 0, results => [], errors => ['empty_query'] }
        unless defined $query && $query =~ /\S/;
    return { ok => 0, results => [], errors => ['missing_profile'] }
        unless ref($profile) eq 'HASH';
    my $loader = $profile->{'loader'} // '';
    return { ok => 0, results => [], errors => ['unsupported_loader'] }
        unless $loader eq 'paper' || mc_loader_is_modded($loader);

    my @modrinth;
    if (mc_loader_modrinth_slug($loader) && !mc_modpack_query_likely_curseforge_only($query)) {
        @modrinth = modrinth_search_modpacks($query, $profile);
    }

    our %config;
    my $cf_key_ok = ($config{'curseforge_api_key'} // '') =~ /\S/;
    my $cf_loader_ok = defined curseforge_mod_loader_type($loader);
    my @curseforge;
    if ($cf_key_ok && $cf_loader_ok) {
        @curseforge = curseforge_search_modpacks($query, $profile);
    }
    elsif ($cf_loader_ok) {
        push @errors, 'curseforge_key_missing';
        push @errors, 'curseforge_recommended'
            if mc_modpack_query_likely_curseforge_only($query);
    }

    @results = _modpack_merge_results(\@modrinth, \@curseforge);
    # Hide packs we can positively identify as incompatible with the instance
    # (wrong Minecraft version / loader), e.g. an ATM9 hit for an ATM10 server.
    my $hidden_incompatible = 0;
    @results = grep {
        my $keep = 1;
        if (ref($_) eq 'HASH' && ($_->{'source'} // '') eq 'curseforge'
            && defined $_->{'compatible'} && !$_->{'compatible'}) {
            $keep = 0;
            $hidden_incompatible++;
        }
        $keep;
    } @results;
    push @errors, 'filtered_incompatible' if $hidden_incompatible && !@results;
    @results = sort { ($b->{'downloads'} // 0) <=> ($a->{'downloads'} // 0) } @results;
    @results = @results[0 .. 19] if @results > 20;
    return { ok => 1, results => \@results, errors => \@errors };
}

sub resolve_modpack_remote_file {
    my ($source, $ids, $profile) = @_;
    return (0, undef, 'invalid', undef) unless ref($ids) eq 'HASH' && ref($profile) eq 'HASH';
    $source =~ s/[^a-z]//g;
    if ($source eq 'modrinth') {
        my $pid = $ids->{'project_id'} // '';
        $pid =~ s/[^a-zA-Z0-9_-]//g;
        return (0, undef, 'invalid_project', { project_id => $ids->{'project_id'} // '' })
            unless $pid;
        my $file;
        if ($ids->{'version_id'} && $ids->{'version_id'} =~ /^[a-zA-Z0-9_-]+$/) {
            $file = modrinth_resolve_modpack_version_by_id($ids->{'version_id'}, $profile);
        }
        $file ||= modrinth_resolve_modpack_file($pid, $profile);
        unless ($file) {
            return (0, undef, 'modrinth_no_matching_file', {
                mc     => $profile->{'mc_version'} // '?',
                loader => $profile->{'loader'} // '?',
                project_id => $pid,
            });
        }
        return (1, $file, undef, undef);
    }
    if ($source eq 'curseforge') {
        my $pid = $ids->{'project_id'} // '';
        $pid =~ s/\D//g;
        return (0, undef, 'invalid_project', { project_id => $ids->{'project_id'} // '' })
            unless $pid;
        our %config;
        my $key = $config{'curseforge_api_key'} // '';
        return (0, undef, 'curseforge_key_missing', undef) unless $key =~ /\S/;
        my ($file, $err, $detail);
        if ($ids->{'file_id'} && $ids->{'file_id'} =~ /^\d+$/) {
            ($file, $err, $detail) = _curseforge_build_modpack_file($pid, $ids->{'file_id'}, $key);
        }
        unless ($file) {
            my ($f2, $err2, $detail2) = curseforge_resolve_modpack_file($pid, $profile);
            if ($f2) {
                return (1, $f2, undef, undef);
            }
            $err    //= $err2;
            $detail //= $detail2;
        }
        unless ($file) {
            return (0, undef, $err // 'resolve_failed', $detail);
        }
        return (1, $file, undef, undef);
    }
    return (0, undef, 'invalid_source', undef);
}

sub expand_remote_modpack_job_meta {
    my ($job_dir, $server_dir) = @_;
    return (0, 'missing_job_dir', undef) unless defined $job_dir && -d $job_dir;
    return (1, undef, undef) unless -f "$job_dir/pack_meta.json";
    open(my $rfh, '<', "$job_dir/pack_meta.json") or return (0, 'read_meta', undef);
    local $/;
    my $raw = <$rfh>;
    close($rfh);
    my $meta = eval { decode_json($raw) };
    return (0, 'parse_meta', undef) unless ref($meta) eq 'HASH';

    if (modpack_meta_install_ready($meta)) {
        # Job log was truncated at worker start — re-emit version notes.
        modpack_print_validation_report_from_meta($meta, $server_dir);
        return (1, undef, undef);
    }

    my $profile = $meta->{'profile'};
    if (ref($profile) ne 'HASH') {
        $profile = read_mc_profile($server_dir);
    }
    return (0, 'missing_profile', undef) unless ref($profile) eq 'HASH';

    my $path;
    my $local_archive = '';
    if (($meta->{'pack_file'} // '') =~ /\S/ && -f $meta->{'pack_file'}) {
        $local_archive = $meta->{'pack_file'};
    } else {
        my $found = _modpack_find_upload_pack($job_dir);
        $local_archive = $found if defined $found && -f $found;
    }

    if ($local_archive ne '') {
        $path = $local_archive;
        print "=== Using existing modpack archive ===\n";
        delete $meta->{'remote_pending'};
        delete $meta->{'remote_source'};
        delete $meta->{'remote_ids'};
        _modpack_save_expand_draft_meta($job_dir, $meta, $path);
    } else {
        if ($meta->{'remote_pending'}) {
            my $source = $meta->{'remote_source'} // '';
            my $ids    = $meta->{'remote_ids'} // {};
            my %saved_ids = ref($ids) eq 'HASH' ? %$ids : ();
            my ($resolved, $file, $err, $detail) = resolve_modpack_remote_file(
                $source, $ids, $profile);
            unless ($resolved) {
                return (0, $err // 'resolve_failed', $detail);
            }
            $meta->{'remote_download'}  = $file->{'download_url'};
            $meta->{'remote_filename'}  = $file->{'filename'};
            $meta->{'format'}           = ($source eq 'curseforge') ? 'curseforge' : 'modrinth'
                unless $meta->{'format'};
            $meta->{'_saved_remote_ids'} = \%saved_ids;
            delete $meta->{'remote_pending'};
            delete $meta->{'remote_source'};
            delete $meta->{'remote_ids'};
        }

        my $remote = $meta->{'remote_download'} // '';
        unless ($remote =~ m{\Ahttps://}i) {
            return (0, 'download_failed', { url => 'missing' });
        }
        my ($dl_host) = $remote =~ m{\Ahttps://([^/:]+)}i;
        unless (mc_download_url_allowed($remote)) {
            return (0, 'curseforge_download_host_blocked', {
                host => $dl_host // '?', project_id => ($meta->{'pack_name'} // ''),
            });
        }
        my $upload_dir = "$job_dir/upload";
        _modpack_ensure_dir($upload_dir, 0750)
            or return (0, 'mkdir', { path => $upload_dir, os_err => ($! // 'unknown') });
        my $fname = $meta->{'remote_filename'} // 'pack.mrpack';
        $fname =~ s/[^a-zA-Z0-9._-]//g;
        $fname = 'pack.mrpack' unless $fname =~ /\.(mrpack|zip)\z/i;
        $path = "$upload_dir/$fname";
        unless (-f $path) {
            mc_download_url_to_file($remote, $path)
                or do {
                    my %detail = (
                        url  => substr($remote, 0, 120),
                        host => $dl_host // '?',
                    );
                    if ($dl_host && $dl_host =~ /forgecdn\.net/i && curseforge_api_key() !~ /\S/) {
                        return (0, 'curseforge_key_missing', \%detail);
                    }
                    return (0, 'download_failed', \%detail);
                };
        } else {
            print "=== Modpack archive already downloaded ===\n";
        }
    }

    return (0, 'download_failed', { url => 'missing' }) unless defined $path && -f $path;

    my $max = 800 * 1024 * 1024;
    my $size = -s $path;
    return (0, 'too_large', undef) if defined $size && $size > $max;

    _modpack_save_expand_draft_meta($job_dir, $meta, $path);

    my $pack = parse_modpack_file($path);
    return (0, 'invalid_pack', undef) unless $pack;

    # Adopt mode (modpack-first wizard): the pack is the source of truth for
    # loader / loader_version / mc_version, so version/loader "mismatches"
    # against the provisional profile become warnings (not hard errors).
    my $adopt = $meta->{'adopt_profile'} ? 1 : 0;

    my $validation = validate_modpack_against_profile($pack, $profile, { adopt => $adopt });
    unless ($validation->{'ok'}) {
        my %detail = (
            pack_mc           => $pack->{'mc_version'} // '',
            pack_loader       => $pack->{'loader'} // '',
            instance_mc       => $profile->{'mc_version'} // '',
            instance_loader   => $profile->{'loader'} // '',
            project_id        => ($meta->{'_saved_remote_ids'} // {})->{'project_id'} // '',
        );
        my @verr = @{ $validation->{'errors'} // [] };
        if (grep { $_ eq 'loader_mismatch' } @verr) {
            return (0, 'loader_mismatch', \%detail);
        }
        if (grep { $_ eq 'version_mismatch' } @verr) {
            return (0, 'version_mismatch', \%detail);
        }
        if (grep { $_ eq 'modded_pack_on_vanilla' } @verr) {
            return (0, 'modded_pack_on_vanilla', \%detail);
        }
        return (0, 'validation_failed', \%detail);
    }

    modpack_print_validation_report($pack, $profile, $validation);
    $meta->{'validation_warnings'} = [ @{ $validation->{'warnings'} // [] } ];

    if (($pack->{'format'} // '') eq 'curseforge') {
        my $needs_resolve = 0;
        for my $f (@{ $pack->{'files'} // [] }) {
            next unless ref($f) eq 'HASH';
            unless (ref($f->{'downloads'}) eq 'ARRAY' && @{ $f->{'downloads'} }) {
                $needs_resolve = 1;
                last;
            }
        }
        if ($needs_resolve) {
            my $file_total = scalar @{ $pack->{'files'} // [] };
            my $cp = modpack_read_cf_resolve_checkpoint($job_dir);
            my $unix_user = $ENV{'WEBCORE_UNIX_USER'} // '';
            if (ref($cp) eq 'HASH' && ref($cp->{'resolved'}) eq 'ARRAY') {
                my @merged = modpack_cf_resolve_merge_checkpoint($cp, $file_total);
                my $done = @merged ? modpack_cf_resolve_done_count(\@merged) : 0;
                print "=== Resuming CurseForge mod metadata ($done/$file_total already resolved) ===\n"
                    if $done > 0;
            } else {
                print "=== Resolving CurseForge mod metadata ===\n";
            }
            modpack_cf_apply_rate_limit_cooldown($job_dir);
            my ($ok, $resolved, $cf_err, $cf_detail) = curseforge_resolve_pack_files($pack,
                checkpoint_job   => $job_dir,
                checkpoint_user  => $unix_user,
            );
            return (0, $cf_err // 'curseforge_failed', $cf_detail) unless $ok;
            $pack->{'files'} = $resolved;
            unlink modpack_cf_resolve_checkpoint_path($job_dir);
        } else {
            print "=== CurseForge mod metadata already resolved ===\n";
        }
    }

    my ($files, $skipped_client) = modpack_files_for_server_import($pack);
    return (0, 'no_server_mods', undef) unless @$files;

    $meta->{'pack_file'}      = $path;
    $meta->{'format'}         = $pack->{'format'};
    $meta->{'pack_name'}      = $pack->{'name'} // '';
    $meta->{'mod_dir'}        = $profile->{'mod_dir'} // ($meta->{'mod_dir'} // 'mods');
    $meta->{'server_dir'}     = $server_dir;
    $meta->{'skipped_client'} = $skipped_client;
    $meta->{'files'}          = $files;
    # Authoritative loader/version info from the pack manifest (for adopt mode
    # and informational display). Kept even when not adopting.
    $meta->{'pack_loader'}         = $pack->{'loader'}         if defined $pack->{'loader'};
    $meta->{'pack_loader_version'} = $pack->{'loader_version'} if defined $pack->{'loader_version'};
    $meta->{'pack_mc_version'}     = $pack->{'mc_version'}     if defined $pack->{'mc_version'};
    delete $meta->{'remote_download'};
    delete $meta->{'remote_filename'};
    delete $meta->{'profile'};
    delete $meta->{'_saved_remote_ids'};

    my $json = encode_json($meta);
    my $meta_path = "$job_dir/pack_meta.json";
    return (0, 'write_meta', undef) unless _modpack_atomic_write_json($meta_path, $json);
    return (1, undef, undef);
}

# Adopt mode: rewrite the instance profile from the pack manifest values so the
# loader (and its pinned version) + MC version match the pack exactly.
# MUST run as root (write_mc_profile uses su). Returns (ok, code, detail).
sub modpack_adopt_profile_from_meta {
    my ($job_dir, $server_dir, $unix_user) = @_;
    return (0, 'missing_args')
        unless defined $job_dir && defined $server_dir && defined $unix_user;
    return (0, 'no_meta') unless -f "$job_dir/pack_meta.json";
    open(my $fh, '<', "$job_dir/pack_meta.json") or return (0, 'read_meta');
    local $/;
    my $meta = eval { decode_json(<$fh>) };
    close($fh);
    return (0, 'parse_meta') unless ref($meta) eq 'HASH';
    return (1, 'not_adopt') unless $meta->{'adopt_profile'};

    my $old = read_mc_profile($server_dir);
    return (0, 'no_profile') unless ref($old) eq 'HASH';

    my $loader = $meta->{'pack_loader'} // $old->{'loader'} // '';
    my $mc     = $meta->{'pack_mc_version'} // $old->{'mc_version'} // '';
    my $lv     = $meta->{'pack_loader_version'};
    $loader =~ s/[^a-z]//g;
    $mc     =~ s/[^0-9.]//g;
    return (0, 'incomplete_pack') unless $loader && $mc;

    my %opts;
    $opts{'loader_version'} = $lv if defined $lv && $lv =~ /\S/;
    my $new = build_mc_profile($loader, $mc, \%opts);
    return (0, 'build_failed') unless ref($new) eq 'HASH';

    # Preserve non-derived, still-valid fields from the existing profile.
    for my $k (qw(eula_accepted eula_accepted_at)) {
        $new->{$k} = $old->{$k} if defined $old->{$k};
    }

    # Nothing to do if loader, mc and loader_version already match — unless Java
    # fields are stale (MC 26.x still pointing at Temurin 21).
    if (($old->{'loader'} // '') eq ($new->{'loader'} // '')
        && ($old->{'mc_version'} // '') eq ($new->{'mc_version'} // '')
        && ($old->{'loader_version'} // '') eq ($new->{'loader_version'} // '')) {
        if (mc_profile_java_needs_sync($old)) {
            my $synced = mc_profile_sync_java_fields($old);
            write_mc_profile($server_dir, $unix_user, $synced) or return (0, 'write_failed');
            return (1, 'java_synced', {
                loader         => $synced->{'loader'},
                mc_version     => $synced->{'mc_version'},
                loader_version => $synced->{'loader_version'} // '',
                java_major     => $synced->{'java_major'},
            });
        }
        return (1, 'unchanged', {
            loader => $new->{'loader'}, mc_version => $new->{'mc_version'},
            loader_version => $new->{'loader_version'} // '',
        });
    }

    write_mc_profile($server_dir, $unix_user, $new) or return (0, 'write_failed');
    return (1, 'adopted', {
        loader         => $new->{'loader'},
        mc_version     => $new->{'mc_version'},
        loader_version => $new->{'loader_version'} // '',
    });
}

1;
