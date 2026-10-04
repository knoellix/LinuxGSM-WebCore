#!/usr/bin/env perl
# UTF-8 hard-load: module lang files must populate %text with real umlauts.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Encode qw(encode_utf8);

require "$Bin/stubs.pl";
our (%text, $module_root, $module_root_directory, $module_name, $current_lang);

$module_root = "$Bin/../src";
$module_root_directory = $module_root;
$module_name = 'linuxgsm-webcore';
$current_lang = 'de';
$main::current_lang = 'de';
$main::module_name = $module_name;

# Stub load_language before core.pl auto-applies ensure (may mojibake).
{
    no warnings 'redefine';
    *main::load_language = sub {
        return (jobs_title => "Job-\xC3\x9Cbersicht");
    };
}

require "$Bin/../src/lib/core.pl";

ok(defined &webcore_load_lang_file_utf8, 'webcore_load_lang_file_utf8 defined');
ok(defined &webcore_ensure_utf8_text, 'webcore_ensure_utf8_text defined');

my %from_file = webcore_load_lang_file_utf8("$module_root/lang/de.UTF-8");
ok(%from_file, 'de.UTF-8 parsed');
ok(exists $from_file{jobs_title}, 'jobs_title present in file');
ok(index($from_file{jobs_title}, "\x{00DC}") >= 0,
    'jobs_title from file contains real U+00DC Ü');
my $bytes = encode_utf8($from_file{jobs_title});
unlike($bytes, qr/\xC3\x83/, 'jobs_title UTF-8 bytes are not mojibake Ã');

# Re-run ensure after poisoning %text like a Latin-1 Webmin load.
%text = (jobs_title => "Job-\x{00C3}\x{009C}bersicht");
ok(webcore_ensure_utf8_text(), 'webcore_ensure_utf8_text succeeds');
ok(index($text{jobs_title} // '', "\x{00DC}") >= 0,
    '%text jobs_title has real Ü after ensure');
is($main::force_charset, 'utf-8', 'force_charset utf-8');

done_testing();
