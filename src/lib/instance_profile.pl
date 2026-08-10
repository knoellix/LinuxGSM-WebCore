# LinuxGSM-WebCore - Modular instance profile → LGSM cfg bridge
# Game-specific providers register via profile_cfg_overrides_for() below.
use strict;
use warnings;

# Return hashref of LGSM instance.cfg keys to apply from wizard/instance profiles.
# Extend by adding elsif branches for other game families.
sub get_instance_profile_cfg_overrides {
    my ($script_name, $server_dir) = @_;
    my %merged;

    if (defined &is_minecraft_game && &is_minecraft_game($script_name)) {
        if (defined &read_mc_profile && defined &mc_lgsm_cfg_overrides) {
            my $profile = &read_mc_profile($server_dir);
            if ($profile) {
                my $mc = &mc_lgsm_cfg_overrides($profile, $server_dir);
                if (ref($mc) eq 'HASH') {
                    @merged{keys %$mc} = values %$mc;
                }
            }
        }
    }

    return \%merged;
}

# Patch LGSM instance.cfg content using any registered instance profile provider.
sub apply_instance_profile_to_cfg_content {
    my ($content, $script_name, $server_dir) = @_;
    $content //= '';

    if (defined &is_minecraft_game && &is_minecraft_game($script_name)) {
        if (defined &read_mc_profile && defined &patch_lgsm_mc_cfg_content) {
            my $profile = &read_mc_profile($server_dir);
            if ($profile) {
                return &patch_lgsm_mc_cfg_content($content, $profile, $server_dir);
            }
        }
    }

    return $content;
}

1;
