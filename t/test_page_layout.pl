#!/usr/bin/perl
# Static layout guards: section order and collapsible bookkeeping in the CGIs.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $src = "$Bin/../src";

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot read $path: $!";
    local $/;
    my $raw = <$fh>;
    close($fh);
    return $raw;
}

my %page = map { $_ => slurp("$src/$_.cgi") } qw(manage mods workshop);

sub id_pos {
    my ($text, $id) = @_;
    return $text =~ /id\s*=>\s*'\Q$id\E'/ ? $-[0] : -1;
}

sub count_of {
    my ($text, $needle) = @_;
    my $n = 0;
    $n++ while $text =~ /\Q$needle\E/g;
    return $n;
}

for my $name (sort keys %page) {
    subtest "$name.cgi collapsible bookkeeping" => sub {
        my $text = $page{$name};
        my $starts = count_of($text, 'ui_collapsible_start');
        my $ends   = count_of($text, 'ui_collapsible_end');
        ok($starts > 0, "$name.cgi uses collapsible sections");
        is($ends, $starts, 'every opened section is closed');
        like($text, qr/ui_collapsible_state_script/, 'state script is emitted');
        unlike($text, qr/\bui_success\b/,
            "$name.cgi must not call non-existent ui_success");

        my @ids = $text =~ /ui_collapsible_start\([^;]*?id\s*=>\s*'([a-z0-9_-]+)'/gs;
        ok(scalar(@ids) >= $starts - 1, 'sections carry ids for state and deep links');
        my %seen;
        my @dupes = grep { $seen{$_}++ } @ids;
        is_deeply(\@dupes, [], 'section ids are unique');
    };
}

subtest 'mods.cgi section order' => sub {
    my $text = $page{'mods'};
    my %at;
    for my $key (qw(jobs upgrade-check modpack mod-search installed-mods)) {
        my $pos = id_pos($text, $key);
        cmp_ok($pos, '>', -1, "section $key exists");
        $at{$key} = $pos;
    }
    cmp_ok($at{'jobs'}, '<', $at{'upgrade-check'}, 'jobs stay on top');
    cmp_ok($at{'upgrade-check'}, '<', $at{'modpack'},
        'upgrade check sits above modpack import');
    cmp_ok($at{'modpack'}, '<', $at{'mod-search'}, 'modpack import above mod search');
    cmp_ok($at{'mod-search'}, '<', $at{'installed-mods'}, 'installed mods last');
};

subtest 'mods.cgi modpack sources are nested collapsibles' => sub {
    my $text = $page{'mods'};
    for my $key (qw(modpack-search modpack-upload modpack-path)) {
        like($text, qr/id\s*=>\s*'\Q$key\E'/, "$key is collapsible");
    }
};

subtest 'manage.cgi section groups' => sub {
    my $text = $page{'manage'};
    my %at;
    for my $key (qw(controls monitoring upgrades access config)) {
        my $pos = id_pos($text, $key);
        cmp_ok($pos, '>', -1, "section $key exists");
        $at{$key} = $pos;
    }
    like($text, qr/lgsm-danger-zone.*id=\\"danger\\"/s, 'danger zone marker exists');
    cmp_ok(index($text, 'lgsm-danger-zone'), '>', index($text, "id => 'config'"),
        'destructive actions last');
    cmp_ok($at{'controls'}, '<', $at{'monitoring'}, 'controls first');
    cmp_ok($at{'monitoring'}, '<', $at{'upgrades'}, 'monitoring before upgrades');
    cmp_ok($at{'upgrades'}, '<', $at{'access'}, 'upgrades before access');
    cmp_ok($at{'access'}, '<', $at{'config'}, 'access before configuration');
};

subtest 'upgrade blocks render from cache, not from a page-load fetch' => sub {
    my $text = $page{'manage'};
    unlike($text, qr/mc_upgrade_loader_upgrade_candidates\(\s*\$profile\s*\)\s*;/,
        'no unbounded loader fetch during page render');
    like($text, qr/no_fetch\s*=>\s*1/, 'render path asks the cache only');
    like($page{'mods'}, qr/no_fetch\s*=>\s*1/, 'mods page render path asks the cache only');
};

subtest 'manage.cgi job_log_card bypasses LGSM action dispatch' => sub {
    my $text = $page{'manage'};
    like($text, qr{!\~\s*/\^\(\?:poll_job\|poll_monitor\|poll_runtime\|poll_players\|monitor\|job_log_card\|start_log_panel\)\$},
        'job_log_card/start_log_panel exempt from the catch-all action block');
    like($text, qr/job_log_card_json_emit/,
        'job_log_card returns JSON for fetch');
    like($text, qr/action=start_log_panel|eq 'start_log_panel'/,
        'Dev-Start panel fragment action exists');
};

subtest 'manage.cgi A2S player row gated on player_query meta' => sub {
    my $text = $page{'manage'};
    like($text, qr/player_query_meta\(\$script_name_for_cfg\)/,
        'A2S row checks player_query_meta for script');
    like($text, qr/\$has_pq\s*=.*player_query_meta/,
        'has_pq guard before a2s_query row');
    like($text, qr/if\s*\(\s*\$qfield\s*&&\s*!\$has_pq\s*\)/,
        'a2s_query row skipped when player_query meta set');
    like($text, qr/\$qfield\s*&&\s*!\$has_pq[\s\S]*?a2s_query/,
        'a2s_query only inside player_query guard');
};

subtest 'manage.cgi auto-update UI + save path' => sub {
    my $text = $page{'manage'};
    like($text, qr/action\s*eq\s*'save_auto_update'/,
        'POST save_auto_update handler exists');
    like($text, qr/save_auto_update/,
        'form/action mentions save_auto_update');
    like($text, qr/auto_update_howto_title/,
        'howto title lang key is rendered');
    like($text, qr/auto_update_howto_body/,
        'howto body lang key is rendered');
    like($text, qr/auto_update_adapter_for_script/,
        'block gated on adapter');
    like($text, qr/rebuild_auto_update_cron|\_rebuild_auto_update_cron/,
        'save rebuilds auto-update cron');
    like($text, qr/auto_update_save_\$/,
        'flash key uses auto_update_save_$instance_id');
    like($text, qr/module_config_bool\(\$in\{'auto_update_enabled'\}\)/,
        'enabled uses module_config_bool');
    like($text, qr/module_config_bool\(\$in\{'auto_update_check_game'\}\)/,
        'check_game uses module_config_bool');
    like($text, qr/module_config_bool\(\$in\{'auto_update_check_workshop'\}\)/,
        'check_workshop uses module_config_bool');
};

subtest 'auto-update howto lang keys exist in de+en' => sub {
    for my $lang (qw(de en)) {
        my $raw = slurp("$src/lang/$lang");
        for my $key (qw(
            auto_update_howto_title auto_update_howto_body
            auto_update_title auto_update_enabled_label
            auto_update_check_game auto_update_check_workshop
            auto_update_interval_label auto_update_warn_minutes_label
            auto_update_msg_template_label auto_update_msg_now_label
            auto_update_save_btn auto_update_saved_ok
            auto_update_save_failed auto_update_cron_rebuild_failed
            auto_update_last_check_col auto_update_pending_col
            auto_update_workshop_no_key_hint
        )) {
            like($raw, qr/^\Q$key=\E/m, "$lang has $key");
        }
        like($raw, qr/^auto_update_howto_body=.+/m,
            "$lang howto body is non-empty");
    }
};

subtest 'workshop.cgi lazy inventory poll' => sub {
    my $text = $page{'workshop'};
    like($text, qr/action=poll_inventory|poll_inventory/,
        'poll_inventory action present');
    like($text, qr/ws-inventory/,
        'inventory placeholder container');
    like($text, qr/_ws_build_inventory_payload/,
        'inventory HTML built in helper for poll');
    like($text, qr/workshop_inventory_loading/,
        'loading placeholder text key used on shell');
    # Steam titles only in the poll helper (not on first paint).
    like($text, qr/sub _ws_build_inventory_payload[\s\S]*?pz_workshop_steam_details/,
        'Steam details live inside inventory payload helper');
    like($text, qr/_ws_paginate_inventory/,
        'inventory uses page pagination helper');
    like($text, qr/_ws_inventory_pager_html|workshop_page_info|inv_page/,
        'inventory pager / inv_page wired');
};

subtest 'mods.cgi lazy installed mods poll' => sub {
    my $text = $page{'mods'};
    like($text, qr/action=poll_installed|poll_installed/,
        'poll_installed action present');
    like($text, qr/mc-mods-installed/,
        'installed mods placeholder container');
    like($text, qr/_mods_build_installed_payload/,
        'installed mods HTML built in helper for poll');
    like($text, qr/mc_mods_page_inventory_loading/,
        'loading placeholder text key used on shell');
    like($text, qr/sub _mods_build_installed_payload[\s\S]*?list_installed_mods/,
        'disk scan only inside poll payload helper');
    unlike($text, qr/id\s*=>\s*'installed-mods'[\s\S]*?list_installed_mods/s,
        'installed-mods shell does not sync-scan on first paint');
};

subtest 'soft start/stop helpers wired' => sub {
    like($page{'manage'}, qr/server_control_soft_form|server_control_async_requested/,
        'manage uses soft-action helpers');
    like($page{'manage'}, qr/server_control_install_async_error_trap/,
        'manage installs async JSON error trap');
    like($page{'manage'}, qr/instance_job_launch_lock/,
        'manage serializes start/stop/restart launch');
    like($page{'workshop'}, qr/server_control_async_requested/,
        'workshop async silent job path');
    like($page{'workshop'}, qr/instance_job_launch_lock/,
        'workshop serializes start/stop/restart launch');
    like($page{'mods'}, qr/poll_job|_mods_async_silent_job_json/,
        'mods has silent poll_job for soft control bar');
    like($page{'mods'}, qr/instance_job_launch_lock/,
        'mods serializes start/stop/restart launch');
};

subtest 'job log card fetch query avoids xnavigation' => sub {
    require "$src/lib/jobs.pl";
    no warnings qw(redefine once);
    *main::urlize = sub { my ($s) = @_; return $s; };
    my $q = job_log_card_fetch_template('manage.cgi', 'test-server');
    like($q, qr/action=job_log_card/, 'fetch query includes action');
    unlike($q, qr/xnavigation/, 'fetch query must not use xnavigation');
    unlike($q, qr{^/}, 'fetch query is relative (client adds pathname)');
};

subtest 'manage active job notice: one banner, ASCII separator' => sub {
    my $text = $page{'manage'};
    like($text, qr/sub _manage_render_active_job_notice/,
        'active job notice helper present');
    like($text, qr/\$_MANAGE_ACTIVE_JOB_NOTICE_DONE/,
        'once-per-page guard for active job notice');
    like($text, qr/\$seen_act\{\$act\}/,
        'dedupes running jobs by action');
    unlike(
        $text,
        qr/html_escape\(\$label\)\s*\.\s*"\s*—\s*"/,
        'job notice must not use UTF-8 em-dash (mojibakes to â)'
    );
    like(
        $text,
        qr/html_escape\(\$label\)\s*\.\s*" - "/,
        'job notice uses ASCII " - " separator'
    );
};

done_testing();
