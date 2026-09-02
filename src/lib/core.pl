# LinuxGSM-WebCore - Shared helpers and Webmin API wrappers
use strict;
use warnings;

our (%text, %config, %gconfig, $module_root, $module_root_directory, $current_lang, $config_directory);

# Webmin sets $config_directory to the global /etc/webmin in some CGI contexts.
# Derive the module-specific path from $module_root_directory if needed.
if ($module_root_directory && $config_directory) {
    (my $_mn = $module_root_directory) =~ s{.*/}{};
    $config_directory .= "/$_mn" unless !$_mn || $config_directory =~ /\Q$_mn\E/;
}

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

# Collapsible page section (<details>/<summary>) used by manage.cgi / mods.cgi.
# Opts:
#   id    => stable anchor id (deep links, localStorage key, layout tests)
#   open  => default state when the browser has no stored state
#   force => keep open regardless of stored state (running job, search hits, deep link)
#   badge => short suffix in the summary line (counts, target versions)
#   hint  => paragraph directly below the summary
sub ui_collapsible_start {
    my ($title, %opts) = @_;
    my $id = lc($opts{'id'} // '');
    $id =~ s/[^a-z0-9_-]//g;
    my $open = ($opts{'open'} || $opts{'force'}) ? 1 : 0;
    my $attrs = ' class="lgsm-section"';
    $attrs .= " id=\"$id\"" if $id ne '';
    $attrs .= ' data-lgsm-force="1"' if $opts{'force'};
    $attrs .= ' open' if $open;
    my $out = "<details$attrs>\n<summary><b>" . &html_escape($title // '') . "</b>";
    my $badge = $opts{'badge'} // '';
    $out .= " <small>(" . &html_escape($badge) . ")</small>" if $badge =~ /\S/;
    $out .= "</summary>\n";
    my $hint = $opts{'hint'} // '';
    $out .= "<p>" . &html_escape($hint) . "</p>\n" if $hint =~ /\S/;
    return $out;
}

sub ui_collapsible_end {
    return "</details>\n";
}

# Single status line shared by manage.cgi and mods.cgi so both pages open the
# same way. Values are passed as ready-to-print HTML (badges, links).
sub ui_instance_status_part {
    my ($label, $value_html) = @_;
    return '' unless defined $value_html && $value_html =~ /\S/;
    return "<b>" . &html_escape($label // '') . ":</b> " . $value_html;
}

sub ui_instance_status_line {
    my (@parts) = @_;
    @parts = grep { defined && /\S/ } @parts;
    return '' unless @parts;
    return "<p>" . join(' &nbsp;&middot;&nbsp; ', @parts) . "</p>\n";
}

# Remembers open/closed state per section id in localStorage. Without JS the
# server-side default from ui_collapsible_start() stays in effect.
sub ui_collapsible_state_script {
    return <<'JS';
<script>
(function() {
    var KEY = 'lgsmWebcoreSections';
    function load() {
        try { return JSON.parse(window.localStorage.getItem(KEY) || '{}') || {}; }
        catch (e) { return {}; }
    }
    function save(state) {
        try { window.localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {}
    }
    function init() {
        var state = load();
        var nodes = document.querySelectorAll('details.lgsm-section[id]');
        for (var i = 0; i < nodes.length; i++) {
            (function(node) {
                var id = node.id;
                if (!node.hasAttribute('data-lgsm-force')
                    && Object.prototype.hasOwnProperty.call(state, id)) {
                    node.open = state[id] ? true : false;
                }
                node.addEventListener('toggle', function() {
                    var s = load();
                    s[id] = node.open ? true : false;
                    save(s);
                });
            })(nodes[i]);
        }
        if (window.location.hash.length > 1) {
            var target = document.getElementById(window.location.hash.substring(1));
            while (target) {
                if (target.tagName === 'DETAILS') { target.open = true; }
                target = target.parentElement;
            }
            var anchor = document.getElementById(window.location.hash.substring(1));
            if (anchor && anchor.scrollIntoView) { anchor.scrollIntoView(true); }
        }
    }
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
</script>
JS
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
