# LinuxGSM-WebCore - Shared helpers and Webmin API wrappers
use strict;
use warnings;

our (%text, %config, %gconfig, $module_root, $current_lang, $config_directory);

# Load English base texts, then override with current language
&read_file("$module_root/lang/en", \%text);
if ($current_lang && $current_lang ne 'en') {
    &read_file("$module_root/lang/$current_lang", \%text);
}

# Load module config
&read_file("$config_directory/config", \%config) if -f "$config_directory/config";

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
sub run_server_action {
    my ($user, $action) = @_;
    $user   = &sanitize_input($user);
    $action = &sanitize_input($action);

    my %valid_actions = map { $_ => 1 } qw(start stop restart update details);
    &error($text{'err_invalid_action'}) unless $valid_actions{$action};

    return &system_logged("su -s /bin/bash -c \"./$user $action\" $user");
}

1;
