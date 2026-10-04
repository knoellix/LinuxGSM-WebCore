# LinuxGSM-WebCore - Shared helpers and Webmin API wrappers
use strict;
use warnings;

our (%text, %config, %gconfig, $module_root, $module_root_directory, $current_lang, $config_directory, $module_name);

# Webmin sets $config_directory to the global /etc/webmin in some CGI contexts.
# Derive the module-specific path from $module_root_directory if needed.
if ($module_root_directory && $config_directory) {
    (my $_mn = $module_root_directory) =~ s{.*/}{};
    $config_directory .= "/$_mn" unless !$_mn || $config_directory =~ /\Q$_mn\E/;
}

# Webmin's plain "de"/"en" often default to ISO-8859-1 when loading lang files,
# which mojibakes UTF-8 strings (geprüft → geprÃ¼ft / Übersicht → Ãbersicht).
# Prefer lang/*.UTF-8 and force HTTP charset before header().
# Also re-read the module lang file ourselves as UTF-8 so %text is correct even
# when load_language still decodes as Latin-1 under de.UTF-8.
sub webcore_ensure_utf8_text {
    $main::force_charset = 'utf-8';
    $main::gconfig{'charset'} = 'utf-8';
    $gconfig{'charset'} = 'utf-8' if %gconfig;

    my $lang = $main::current_lang // $current_lang // $gconfig{'lang'} // '';
    my $base = '';
    if ($lang =~ /^(de|en)(?:\.UTF-8)?$/i) {
        $base = lc($1);
    } else {
        return 0;
    }
    my $root = $module_root_directory // $module_root // '';
    return 0 unless $root ne '';

    my $utf_file = "$root/lang/${base}.UTF-8";
    my $lang_file = (-f $utf_file) ? $utf_file : "$root/lang/$base";
    return 0 unless -f $lang_file;

    $main::current_lang = "${base}.UTF-8" if -f $utf_file;
    $current_lang = "${base}.UTF-8" if -f $utf_file;

    # Best-effort: let Webmin populate %text first (may already be wrong).
    my $mod = $module_name // '';
    if ($mod ne '' && defined &load_language) {
        my %loaded = eval { &load_language($mod) };
        %text = %loaded if %loaded;
    }

    my %from_file = webcore_load_lang_file_utf8($lang_file);
    return 0 unless %from_file;
    # Overlay module strings with a verified UTF-8 decode of the lang file.
    %text = (%text, %from_file);
    return 1;
}

# Parse a Webmin-style key=value lang file as UTF-8. Returns a hash (empty on fail).
sub webcore_load_lang_file_utf8 {
    my ($path) = @_;
    return () unless defined $path && $path ne '' && -f $path;
    open(my $fh, '<:encoding(UTF-8)', $path) or return ();
    my %out;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        next if $line =~ /^\s*#/ || $line !~ /\S/;
        next unless $line =~ /^([^=]+)=(.*)$/s;
        my ($k, $v) = ($1, $2);
        $k =~ s/^\s+|\s+$//g;
        next if $k eq '';
        $out{$k} = $v;
    }
    close $fh;
    return %out;
}

# Auto-apply when this lib is required after init_config().
webcore_ensure_utf8_text() if defined $module_name && defined $main::current_lang;

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
our $_ui_collapsible_styles_emitted = 0;

sub ui_collapsible_start {
    my ($title, %opts) = @_;
    my $id = lc($opts{'id'} // '');
    $id =~ s/[^a-z0-9_-]//g;
    my $open = ($opts{'open'} || $opts{'force'}) ? 1 : 0;
    my $attrs = ' class="lgsm-section"';
    $attrs .= " id=\"$id\"" if $id ne '';
    $attrs .= ' data-lgsm-force="1"' if $opts{'force'};
    $attrs .= ' open' if $open;
    # Emit frame CSS with the first section so themes that override late styles
    # still see a bordered box + chevron on first paint.
    my $out = '';
    unless ($_ui_collapsible_styles_emitted) {
        $out .= &ui_collapsible_styles();
        $_ui_collapsible_styles_emitted = 1;
    }
    $out .= "<details$attrs>\n<summary>"
        . "<span class=\"lgsm-section-chevron\" aria-hidden=\"true\">"
        . "<span class=\"lgsm-chevron-closed\">\x{25B6}</span>"
        . "<span class=\"lgsm-chevron-open\">\x{25BC}</span>"
        . "</span>"
        . "<span class=\"lgsm-section-title\"><b>" . &html_escape($title // '') . "</b>";
    my $badge = $opts{'badge'} // '';
    $out .= " <small>(" . &html_escape($badge) . ")</small>" if $badge =~ /\S/;
    $out .= "</span></summary>\n";
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

# Visual frame + chevron for collapsible sections (theme-neutral: currentColor only).
# Solid #888 border is the baseline; color-mix is an enhancement for modern browsers.
sub ui_collapsible_styles {
    return <<'CSS';
<style>
details.lgsm-section {
    border: 1px solid #888;
    border: 1px solid color-mix(in srgb, currentColor 35%, transparent);
    border-radius: 4px;
    margin: 0 0 10px 0;
    background: color-mix(in srgb, currentColor 5%, transparent);
}
details.lgsm-section details.lgsm-section {
    margin-top: 8px;
}
details.lgsm-section > summary {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 12px;
    cursor: pointer;
    user-select: none;
    list-style: none;
}
details.lgsm-section > summary::-webkit-details-marker {
    display: none;
}
details.lgsm-section[open] > summary {
    border-bottom: 1px solid #888;
    border-bottom: 1px solid color-mix(in srgb, currentColor 28%, transparent);
}
details.lgsm-section > :not(summary) {
    margin: 0 12px 12px 12px;
}
details.lgsm-section > summary + :not(summary) {
    margin-top: 12px;
}
details.lgsm-section > summary .lgsm-section-chevron {
    display: inline-block;
    width: 1em;
    flex-shrink: 0;
    line-height: 1;
    opacity: 0.9;
    font-size: 0.9em;
    text-align: center;
}
details.lgsm-section > summary .lgsm-section-chevron .lgsm-chevron-open {
    display: none;
}
details.lgsm-section[open] > summary .lgsm-section-chevron .lgsm-chevron-closed {
    display: none;
}
details.lgsm-section[open] > summary .lgsm-section-chevron .lgsm-chevron-open {
    display: inline;
}
.lgsm-section-title {
    flex: 1 1 auto;
    min-width: 0;
}
.lgsm-danger-zone {
    border: 1px solid #888;
    border: 1px solid color-mix(in srgb, currentColor 35%, transparent);
    border-radius: 4px;
    margin: 16px 0 10px 0;
    padding: 12px;
    background: color-mix(in srgb, currentColor 4%, transparent);
}
.lgsm-danger-zone h4 {
    margin: 0 0 10px 0;
}
</style>
CSS
}

# Remembers open/closed state per section id in localStorage. Without JS the
# server-side default from ui_collapsible_start() stays in effect.
# Styles are emitted with the first ui_collapsible_start(); avoid a second
# copy at the page footer when already printed.
sub ui_collapsible_state_script {
    my $css = $_ui_collapsible_styles_emitted ? '' : &ui_collapsible_styles();
    $_ui_collapsible_styles_emitted = 1;
    return $css . <<'JS';
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
