# mc_upgrade.pl — Minecraft loader/MC version upgrade preflight and plans
use strict;
use warnings;

our @MC_UPGRADE_TEST_LOADER_VERSIONS;
our @MC_UPGRADE_TEST_MC_VERSIONS;

sub mc_upgrade_set_loader_versions_for_test {
    @MC_UPGRADE_TEST_LOADER_VERSIONS = @_;
}

sub mc_upgrade_clear_loader_versions_for_test {
    @MC_UPGRADE_TEST_LOADER_VERSIONS = ();
}

sub mc_upgrade_set_mc_versions_for_test {
    @MC_UPGRADE_TEST_MC_VERSIONS = @_;
}

sub mc_upgrade_clear_mc_versions_for_test {
    @MC_UPGRADE_TEST_MC_VERSIONS = ();
}

sub _mc_upgrade_avail_mc_versions {
    if (@MC_UPGRADE_TEST_MC_VERSIONS) {
        return @MC_UPGRADE_TEST_MC_VERSIONS;
    }
    return mc_list_mc_versions();
}

sub _mc_upgrade_avail_loader_versions {
    my ($loader, $mc_version) = @_;
    if (@MC_UPGRADE_TEST_LOADER_VERSIONS) {
        return @MC_UPGRADE_TEST_LOADER_VERSIONS;
    }
    return mc_fetch_loader_versions($loader, $mc_version);
}

# Loader builds newer than the pinned profile version (same MC line).
sub mc_upgrade_loader_upgrade_candidates {
    my ($profile, $versions_ref) = @_;
    return () unless ref($profile) eq 'HASH';
    my $loader = $profile->{'loader'} // '';
    return () unless mc_loader_is_modded($loader);
    my @avail = ref($versions_ref) eq 'ARRAY' ? @$versions_ref
        : _mc_upgrade_avail_loader_versions($loader, $profile->{'mc_version'} // '');
    return @avail unless @avail;
    my $current = mc_sanitize_loader_version_pin($loader, $profile->{'loader_version'});
    return @avail unless defined $current;
    return grep { mc_loader_version_cmp($_, $current) > 0 } @avail;
}

# Returns undef when valid; otherwise an error token.
sub mc_upgrade_validate_loader_target {
    my ($profile, $target, $versions_ref) = @_;
    return 'invalid' unless ref($profile) eq 'HASH';
    my $loader = $profile->{'loader'} // '';
    my $mc = $profile->{'mc_version'} // '';
    return 'loader_not_modded' unless mc_loader_is_modded($loader);
    my $clean = mc_sanitize_loader_version_pin($loader, $target);
    return 'invalid_target' unless defined $clean;
    return 'invalid_target' unless mc_loader_version_matches_mc($loader, $mc, $clean);

    my @avail = ref($versions_ref) eq 'ARRAY' ? @$versions_ref
        : _mc_upgrade_avail_loader_versions($loader, $mc);
    if (@avail) {
        return 'invalid_target' unless grep { $_ eq $clean } @avail;
    } else {
        return 'invalid_target' if mc_validate_loader_version_pin($loader, $mc, $clean);
    }

    my $current = mc_sanitize_loader_version_pin($loader, $profile->{'loader_version'});
    if (defined $current && mc_loader_version_cmp($clean, $current) <= 0) {
        return 'not_newer';
    }
    return undef;
}

sub mc_upgrade_loader_plan {
    my ($profile, $target_loader_version, $versions_ref) = @_;
    my $err = mc_upgrade_validate_loader_target($profile, $target_loader_version, $versions_ref);
    return (0, undef, $err // 'invalid_target') if $err;
    my $clean = mc_sanitize_loader_version_pin($profile->{'loader'}, $target_loader_version);
    return (0, undef, 'invalid_target') unless defined $clean;
    return (1, {
        mode                  => 'loader',
        loader                => $profile->{'loader'} // '',
        mc_version            => $profile->{'mc_version'} // '',
        target_loader_version => $clean,
        needs_java            => 0,
        lgsm_script           => $profile->{'lgsm_script'} // '',
    }, undef);
}

# True when the current loader family supports an MC release (wizard list or structural).
sub mc_upgrade_mc_loader_supports {
    my ($loader, $mc_version) = @_;
    $loader =~ s/[^a-z]//g;
    $mc_version =~ s/[^0-9.]//g;
    return 0 unless $loader && $mc_version =~ /^[0-9.]+$/;
    return 0 unless mc_loader_is_modded($loader);
    return 0 unless mc_loader_config($loader);
    my @list = _mc_upgrade_avail_mc_versions();
    return 1 if grep { $_ eq $mc_version } @list;
    return 1;
}

sub mc_upgrade_mc_needs_java {
    my ($profile, $target_mc) = @_;
    return 0 unless ref($profile) eq 'HASH';
    $target_mc =~ s/[^0-9.]//g;
    return 0 unless $target_mc =~ /^[0-9.]+$/;
    my $target_java = int(resolve_java_major($target_mc));
    my $current_java = int($profile->{'java_major'} // 0);
    return $target_java != $current_java ? 1 : 0;
}

sub mc_upgrade_mc_upgrade_candidates {
    my ($profile, $versions_ref) = @_;
    return () unless ref($profile) eq 'HASH';
    my $loader = $profile->{'loader'} // '';
    return () unless mc_loader_is_modded($loader);
    my $current = $profile->{'mc_version'} // '';
    $current =~ s/[^0-9.]//g;
    return () unless $current =~ /^[0-9.]+$/;
    my @avail = ref($versions_ref) eq 'ARRAY' ? @$versions_ref : _mc_upgrade_avail_mc_versions();
    return grep {
        my $v = $_;
        $v =~ s/[^0-9.]//g;
        $v ne $current
            && mc_upgrade_mc_loader_supports($loader, $v)
            && mc_loader_version_cmp($v, $current) > 0
    } @avail;
}

sub mc_upgrade_validate_mc_target {
    my ($profile, $target_mc, $versions_ref) = @_;
    return 'invalid' unless ref($profile) eq 'HASH';
    my $loader = $profile->{'loader'} // '';
    return 'loader_not_modded' unless mc_loader_is_modded($loader);
    my $clean = $target_mc // '';
    $clean =~ s/[^0-9.]//g;
    return 'invalid_target' unless $clean =~ /^[0-9.]+$/;
    return 'invalid_target' unless mc_upgrade_mc_loader_supports($loader, $clean);

    my $current = $profile->{'mc_version'} // '';
    $current =~ s/[^0-9.]//g;
    return 'same_version' if $current eq $clean;
    return 'not_newer' if $current =~ /^[0-9.]+$/ && mc_loader_version_cmp($clean, $current) <= 0;

    my @avail = ref($versions_ref) eq 'ARRAY' ? @$versions_ref : _mc_upgrade_avail_mc_versions();
    if (@avail) {
        return 'invalid_target' unless grep { $_ eq $clean } @avail;
    }
    return undef;
}

sub mc_upgrade_mc_plan {
    my ($profile, $target_mc_version, $versions_ref) = @_;
    my $err = mc_upgrade_validate_mc_target($profile, $target_mc_version, $versions_ref);
    return (0, undef, $err // 'invalid_target') if $err;
    my $clean = $target_mc_version // '';
    $clean =~ s/[^0-9.]//g;
    my $target_java = int(resolve_java_major($clean));
    return (1, {
        mode               => 'mc',
        loader             => $profile->{'loader'} // '',
        mc_version         => $profile->{'mc_version'} // '',
        target_mc_version  => $clean,
        target_java_major  => $target_java,
        needs_java         => mc_upgrade_mc_needs_java($profile, $clean) ? 1 : 0,
        lgsm_script        => $profile->{'lgsm_script'} // '',
    }, undef);
}

sub mc_upgrade_preflight {
    my ($inst, $profile, $server_dir, $target, $ctx) = @_;
    $ctx = {} unless ref($ctx) eq 'HASH';
    $target = {} unless ref($target) eq 'HASH';

    return { ok => 0, err => 'profile_missing' } unless ref($profile) eq 'HASH';
    return { ok => 0, err => 'loader_not_modded' }
        unless mc_loader_is_modded($profile->{'loader'} // '');

    my $runtime = $ctx->{'runtime_status'} // '';
    if ($runtime eq 'online' || $runtime eq 'running') {
        return { ok => 0, err => 'server_must_be_stopped' };
    }

    my $iid = $ctx->{'instance_id'} // '';
    if ($iid !~ /\S/ && ref($inst) eq 'HASH') {
        $iid = $inst->{'instance_id'} // $inst->{'user'} // '';
    }
    if ($iid =~ /\S/) {
        my $job = find_running_job_for_instance($iid);
        return { ok => 0, err => 'job_running' } if $job;
    }

    my $mode = $target->{'mode'} // 'loader';
    if ($mode eq 'loader') {
        my $pin = $target->{'target_loader_version'} // '';
        my $verr = mc_upgrade_validate_loader_target($profile, $pin, $ctx->{'loader_versions'});
        return { ok => 0, err => ($verr // 'invalid_target') } if $verr;
        return { ok => 1 };
    }
    if ($mode eq 'mc') {
        my $mc = $target->{'target_mc_version'} // '';
        my $verr = mc_upgrade_validate_mc_target($profile, $mc, $ctx->{'mc_versions'});
        return { ok => 0, err => ($verr // 'invalid_target') } if $verr;
        return { ok => 1 };
    }
    return { ok => 0, err => 'invalid_mode' };
}

sub write_upgrade_job_plan {
    my ($job_dir, $plan) = @_;
    return 0 unless defined $job_dir && -d $job_dir;
    return 0 unless ref($plan) eq 'HASH';
    require JSON::PP;
    open(my $fh, '>', "$job_dir/upgrade_plan.json") or return 0;
    print $fh JSON::PP::encode_json($plan);
    close($fh);
    return 1;
}

1;
