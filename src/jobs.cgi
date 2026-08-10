#!/usr/bin/perl
use strict;
use warnings;

do '../web-lib.pl';
do '../ui-lib.pl';
&init_config();

require './lib/core.pl';
require './lib/instance.pl';
require './lib/acl.pl';
require './lib/jobs.pl';
require './lib/schedule.pl';
require './lib/logging.pl';
require './lib/live_log.pl';

our (%text, %config, %in, %gconfig);
$main::gconfig{'charset'} = 'utf-8';
&ReadParse(\%in);

# Viewer haben keinen Zugriff
if (&effective_role() eq 'viewer') {
    &error($text{'err_acl_admin_only'} || 'Access denied');
}

my $action = $in{'action'} // '';
$action =~ s/[^a-z_]//g;

# POST: abort_job
if ($action eq 'abort_job') {
    my $job_id = $in{'job_id'} // '';
    $job_id =~ s/[^0-9a-f]//g;
    $job_id or &error($text{'err_invalid_input'});

    my @all = get_all_jobs();
    my ($job) = grep { $_->{job_id} eq $job_id } @all;
    $job or &error($text{'err_not_found'});

    my $inst_id = $job->{instance_id} // '';
    &is_admin() || &user_can_manage($inst_id)
        or &error($text{'err_acl_admin_only'});

    &log_debug("jobs.cgi: abort_job job_id=$job_id");
    abort_job($job_id);
    &redirect('jobs.cgi?xnavigation=1');
    exit;
}

# POST: delete_job
if ($action eq 'delete_job') {
    my $job_id = $in{'job_id'} // '';
    $job_id =~ s/[^0-9a-f]//g;
    $job_id or &error($text{'err_invalid_input'});

    my @all = get_all_jobs();
    my ($job) = grep { $_->{job_id} eq $job_id } @all;
    $job or &error($text{'err_not_found'});

    my $inst_id = $job->{instance_id} // '';
    &is_admin() || &user_can_manage($inst_id)
        or &error($text{'err_acl_admin_only'});

    &log_debug("jobs.cgi: delete_job job_id=$job_id");
    delete_job($job_id)
        or &error($text{'err_invalid_action'} || 'Cannot delete running job');
    &redirect('jobs.cgi?xnavigation=1');
    exit;
}

# GET: view_output
if ($action eq 'view_output') {
    my $job_id = $in{'job_id'} // '';
    $job_id =~ s/[^0-9a-f]//g;
    $job_id or &error($text{'err_invalid_input'});

    my @all = get_all_jobs();
    my ($job) = grep { $_->{job_id} eq $job_id } @all;
    $job or &error($text{'err_not_found'});

    my $inst_id = $job->{instance_id} // '';
    &is_admin() || &user_can_manage($inst_id)
        or &error($text{'err_acl_admin_only'});

    my $out = get_job_output_display($job_id);
    &header($text{'jobs_output_title'} || 'Job Output', '');
    print &job_log_view_page_css();
    print &job_log_view_page_open();
    print "<h3>" . &html_escape($text{'jobs_output_title'} || 'Job Output') . "</h3>\n";
    print &job_log_view_toolbar_open();
    print "<p><a href='jobs.cgi'>&larr; "
        . &html_escape($text{'jobs_title'} || 'Jobs') . "</a></p>\n";
    print &job_log_view_toolbar_close();
    if (defined $out && $out ne '') {
        print &job_log_view_block($out, id => 'jobs_output');
    } else {
        print "<p><i>" . &html_escape('Keine Ausgabe vorhanden.') . "</i></p>\n";
    }
    print &job_log_view_page_close();
    &footer('jobs.cgi', $text{'jobs_title'} || 'Jobs');
    exit;
}

# GET: Hauptliste
&header($text{'jobs_title'} || 'Job-Übersicht', '');
print "<h3>" . &html_escape($text{'jobs_title'} || 'Job-Übersicht') . "</h3>\n";

my @all_jobs = get_all_jobs();

# ACL-Filter für Operatoren
unless (&is_admin()) {
    @all_jobs = grep { &user_can_manage($_->{instance_id} // '') } @all_jobs;
}

my %action_labels = %{ &job_action_labels_hash(\%text) };

my %status_labels = (
    running => '&#x23F3; ' . ($text{'jobs_status_running'} || 'Läuft…'),
    ok      => '&#x2705; ' . ($text{'jobs_status_ok'}      || 'Erfolgreich'),
    failed  => '&#x1F534; ' . ($text{'jobs_status_failed'} || 'Fehlgeschlagen'),
    aborted => '&#x1F6AB; ' . ($text{'jobs_status_aborted'} || 'Abgebrochen'),
);

if (!@all_jobs) {
    print "<p><i>" . &html_escape($text{'jobs_no_jobs'} || 'Keine Jobs vorhanden.') . "</i></p>\n";
} else {
    my @rows;
    for my $job (@all_jobs) {
        my $jid    = $job->{job_id};
        my $status = $job->{status};
        my $inst   = &html_escape($job->{instance_id} || '—');
        my $act    = &html_escape($action_labels{$job->{action} // ''} || $job->{action} || '—');
        my $ts     = $job->{started_at} || 0;
        my @lt     = localtime($ts);
        my $ts_str = $ts ? sprintf('%02d:%02d:%02d', $lt[2], $lt[1], $lt[0]) : '—';

        my $status_cell = $status_labels{$status} // &html_escape($status);

        my $out_cell;
        if ($status eq 'running') {
            $out_cell = "<a href='job_live.cgi?instance_id="
                . &html_escape($job->{instance_id} // '')
                . "&amp;job=" . &html_escape($jid) . "&amp;xnavigation=1'>Live</a>";
        } elsif ($status eq 'ok' || $status eq 'failed' || $status eq 'aborted') {
            $out_cell = "<a href='jobs.cgi?action=view_output&amp;job_id="
                . &html_escape($jid) . "'>Log</a>";
        } else {
            $out_cell = '—';
        }

        my $actions_cell = '';
        my $can_act = &is_admin() || &user_can_manage($job->{instance_id} // '');
        if ($can_act) {
            if ($status eq 'running') {
                $actions_cell = &ui_form_start('jobs.cgi', 'post', undef,
                    "onsubmit=\"return confirm('"
                    . &html_escape($text{'jobs_abort_confirm'} || 'Abbrechen?')
                    . "')\"");
                $actions_cell .= &ui_hidden('action', 'abort_job');
                $actions_cell .= &ui_hidden('job_id', &html_escape($jid));
                $actions_cell .= &ui_submit(
                    $text{'jobs_abort_btn'} || 'Abbrechen',
                    undef, undef, undef, 'btn-danger');
                $actions_cell .= &ui_form_end();
            } else {
                $actions_cell = &ui_form_start('jobs.cgi', 'post');
                $actions_cell .= &ui_hidden('action', 'delete_job');
                $actions_cell .= &ui_hidden('job_id', &html_escape($jid));
                $actions_cell .= &ui_submit(
                    $text{'jobs_delete_btn'} || 'Löschen',
                    undef, undef, undef, 'btn-danger');
                $actions_cell .= &ui_form_end();
            }
        }

        push @rows, [
            $inst,
            $act,
            $ts_str,
            $status_cell,
            $out_cell,
            $actions_cell,
        ];
    }

    print &ui_columns_table(
        [
            $text{'jobs_col_instance'} || 'Instanz',
            $text{'jobs_col_action'}   || 'Aktion',
            $text{'jobs_col_started'}  || 'Gestartet',
            $text{'jobs_col_status'}   || 'Status',
            $text{'jobs_col_output'}   || 'Ausgabe',
            $text{'jobs_col_actions'}  || 'Aktionen',
        ],
        "100%",
        \@rows,
    );
}

&footer('index.cgi', $text{'index_title'});
