# LinuxGSM-WebCore - Shared helpers and Webmin API wrappers
use strict;
use warnings;

our (%text, %config, %gconfig, $module_root, $current_lang, $config_directory);

# Prevent root execution of privileged actions
sub error_if_root {
    if ($< == 0 && !$config{'allow_root'}) {
        &error($text{'err_root'});
    }
}

# Strip dangerous characters from user input.
# Dies() via Webmin &error() if nothing valid remains.
sub sanitize_input {
    my ($input) = @_;
    $input //= '';
    $input =~ s/[^a-zA-Z0-9_\-]//g;
    &error($text{'err_invalid_input'}) unless length $input;
    return $input;
}

# Run a server action as the game user (never as root).
# $action must be in the whitelist — otherwise Webmin error() is called.
# $script_name is the basename of the script (defaults to $user for standard LGSM setup).
# $script_dir is the directory containing the script (cd'd to before execution).
sub run_server_action {
    my ($user, $action, $script_name, $script_dir) = @_;
    $user        = &sanitize_input($user);
    $action      = &sanitize_input($action);
    $script_name = defined $script_name ? &sanitize_input($script_name) : $user;

    my %valid_actions = map { $_ => 1 } qw(start stop restart update details);
    &error($text{'err_invalid_action'}) unless $valid_actions{$action};

    my @pw = getpwnam($user) or &error($text{'err_not_found'});
    my $home = $pw[7];
    $script_dir //= $home;  # fallback to home for standard setups

    return &system_logged(
        "su -s /bin/bash -c \"cd \Q$script_dir\E && ./$script_name $action\" $user"
    );
}

1;
