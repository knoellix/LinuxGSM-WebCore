#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

require "$Bin/stubs.pl";
our $module_root = "$Bin/../src";

require "$Bin/../src/lib/core.pl";

subtest 'collapsible markup' => sub {
    my $html = ui_collapsible_start('Steuerung', id => 'sec-controls');
    like($html, qr/<details[^>]*class="lgsm-section"/, 'details carries the section class');
    like($html, qr/id="sec-controls"/, 'id kept for anchors and state');
    like($html, qr{<summary><span class="lgsm-section-chevron"}, 'chevron marker in summary');
    like($html, qr/class="lgsm-section-title"/, 'title wrapper in summary');
    unlike($html, qr/<details[^>]*\sopen/, 'closed by default');
    like($html, qr{<summary>.*</summary>}, 'summary element');
    is(ui_collapsible_end(), "</details>\n", 'closing tag');

    like(ui_collapsible_start('X', id => 'a', open => 1), qr/<details[^>]*\sopen>/,
        'open => 1 renders an open section');
};

subtest 'collapsible id is sanitized' => sub {
    my $html = ui_collapsible_start('T', id => 'Sec Config/../evil"onload=x');
    like($html, qr/id="secconfigevilonloadx"/, 'only [a-z0-9_-] survives');
    unlike($html, qr/onload=x"/, 'no attribute injection through the id');
};

subtest 'badge and hint are escaped' => sub {
    my $html = ui_collapsible_start('T', id => 'b', badge => '3 <Mods>', hint => 'a & b');
    like($html, qr/\(3 &lt;Mods&gt;\)/, 'badge escaped');
    like($html, qr/<p>a &amp; b<\/p>/, 'hint escaped');

    my $plain = ui_collapsible_start('T', id => 'c');
    unlike($plain, qr/<small>/, 'no badge markup without a badge');
    unlike($plain, qr/<p>/, 'no hint paragraph without a hint');
};

subtest 'forced sections ignore the stored state' => sub {
    my $html = ui_collapsible_start('T', id => 'd', force => 1);
    like($html, qr/data-lgsm-force="1"/, 'force marker present');
    like($html, qr/<details[^>]*\sopen>/, 'forced sections render open');
    unlike(ui_collapsible_start('T', id => 'e', open => 1), qr/data-lgsm-force/,
        'plain open sections stay overridable');
};

subtest 'state script and styles' => sub {
    my $js = ui_collapsible_state_script();
    like($js, qr/<style>.*details\.lgsm-section/s, 'section frame styles included');
    like($js, qr/lgsm-section-chevron/, 'chevron styles included');
    like($js, qr/localStorage/, 'persists via localStorage');
    like($js, qr/details\.lgsm-section\[id\]/, 'only tracks identified sections');
    like($js, qr/data-lgsm-force/, 'skips forced sections');
    like($js, qr/window\.location\.hash/, 'deep links open their section');
};

subtest 'status line' => sub {
    is(ui_instance_status_part('Status', ''), '', 'empty value drops the part');
    is(ui_instance_status_part('Status', 'online'), '<b>Status:</b> online', 'label and value');
    like(ui_instance_status_part('A & B', 'x'), qr/A &amp; B/, 'label escaped');

    is(ui_instance_status_line('', ''), '', 'no line without parts');
    my $line = ui_instance_status_line('<b>A:</b> 1', '', '<b>B:</b> 2');
    like($line, qr/<b>A:<\/b> 1 &nbsp;&middot;&nbsp; <b>B:<\/b> 2/, 'parts joined, empties dropped');
};

done_testing();
