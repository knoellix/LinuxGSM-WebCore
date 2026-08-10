# LinuxGSM-WebCore — Live job log (Webmin xterm.js + WebSocket stack)
use strict;
use warnings;

our ($root_directory);

# Perl modules required for xterm.js assets (AttachAddon optional; live log uses JSON poll).
sub live_log_required_perl_modules {
    return qw(
        Digest::SHA
        Digest::MD5
        IO::Select
        Time::HiRes
    );
}

# Optional packages for WebSocket log server (joblogserver.pl — not used by default UI).
sub live_log_apt_packages {
    return qw(
        libio-tty-perl
        libnet-websocket-server-perl
    );
}

sub live_log_perl_module_ok {
    my ($mod) = @_;
    return 0 unless defined $mod && $mod =~ /^[A-Za-z0-9:]+$/;
    eval "require $mod; 1" ? 1 : 0;
}

sub live_log_missing_perl_modules {
    my @miss;
    for my $mod (live_log_required_perl_modules()) {
        push @miss, $mod unless live_log_perl_module_ok($mod);
    }
    return @miss;
}

sub live_log_xterm_assets {
    my $wver = &get_webmin_version();
    $wver =~ s/\.//g;
    return {
        css => [ "/xterm/xterm.css?$wver" ],
        js  => [
            "/xterm/xterm.js?$wver",
            "/xterm/xterm-addon-attach.js?$wver",
            "/xterm/xterm-addon-fit.js?$wver",
        ],
    };
}

sub live_log_xterm_module_installed {
    return &foreign_check('xterm') ? 1 : 0;
}

sub live_log_xterm_assets_ok {
    my ($root) = @_;
    $root //= $root_directory // '';
    return 0 unless length $root;
    my $assets = live_log_xterm_assets();
    for my $f (@{ $assets->{css} }, @{ $assets->{js} }) {
        my $path = $f;
        $path =~ s/\?.*//;
        return 0 unless -r "$root$path";
    }
    return 1;
}

# Returns hashref: xterm_module, xterm_assets, perl_missing => [], ready => 0/1
sub live_log_status {
    my ($root) = @_;
    $root //= $root_directory // '';
    my @perl_missing = live_log_missing_perl_modules();
    my $xterm_mod = live_log_xterm_module_installed();
    my $xterm_assets = live_log_xterm_assets_ok($root);
    my $ready = $xterm_mod && $xterm_assets && !@perl_missing ? 1 : 0;
    return {
        xterm_module  => $xterm_mod,
        xterm_assets  => $xterm_assets,
        perl_missing  => \@perl_missing,
        ready         => $ready,
    };
}

sub live_log_ready {
    my ($root) = @_;
    my $st = live_log_status($root);
    return $st->{'ready'} ? 1 : 0;
}

sub live_log_first_problem {
    my ($root) = @_;
    my $st = live_log_status($root);
    return 'xterm_module'  unless $st->{'xterm_module'};
    return 'xterm_assets'  unless $st->{'xterm_assets'};
    my $miss = $st->{'perl_missing'};
    return 'perl:' . $miss->[0] if $miss && @$miss;
    return undef;
}

sub install_live_log_apt_packages {
    our $module_root;
    my $script = "$module_root/scripts/module_bootstrap_deps.sh";
    return &system_logged("bash '$script' live_log 2>&1");
}

# Download and install Webmin xterm module (Terminal).
sub install_xterm_webmin_module {
    &foreign_require('webmin', 'webmin-lib.pl');
    my $url = 'https://download.webmin.com/download/modules/xterm.wbm.gz';
    my $file = &transname(&file_basename($url));
    my $err;
    if ($url =~ m{^https://([^/]+)(/.*)$}) {
        my ($host, $page) = ($1, $2);
        &http_download($host, 443, $page, $file, \$err, undef, 1);
    } else {
        return (0, 'invalid xterm module URL');
    }
    return (0, $err) if $err;
    my $users = &webmin::get_newmodule_users();
    $users ||= [ 'root', 'admin' ];
    my $rv = &webmin::install_webmin_module($file, 1, 1, $users);
    if (ref($rv)) {
        return (1, undef);
    }
    $rv =~ s/<[^>]+>//g;
    return (0, $rv || 'install failed');
}

sub live_log_webmin_env {
    my $cfg = $ENV{'WEBMIN_CONFIG'} // '';
    if (!$cfg || !-f "$cfg/miniserv.conf") {
        for my $c ('/etc/webmin', '/usr/local/etc/webmin') {
            if (-f "$c/miniserv.conf") {
                $cfg = $c;
                last;
            }
        }
    }
    $cfg ||= '/etc/webmin';
    my $var = $ENV{'WEBMIN_VAR'} // '';
    if ((!$var || !-d $var) && -r "$cfg/var-path") {
        if (open(my $fh, '<', "$cfg/var-path")) {
            chomp($var = <$fh> // '');
            close($fh);
        }
    }
    $var ||= '/var/webmin';
    return ($cfg, $var);
}

# Launch joblogserver.pl with global Webmin config (not module config dir).
sub live_log_launch_jobserver_cmd {
    my ($port, $output_file, $session_id, $module_root, $webmin_root) = @_;
    $port =~ s/\D//g;
    my $script = "$module_root/scripts/joblogserver.pl";
    my ($wcfg, $wvar) = live_log_webmin_env();
    $webmin_root //= $root_directory // '/usr/share/webmin';
    for my $p ($webmin_root, $wcfg, $wvar, $session_id // '', $script, $output_file) {
        next unless defined $p;
        $p =~ s/'/'\\''/g;
    }
    return "cd '$webmin_root' && WEBMIN_CONFIG='$wcfg' WEBMIN_VAR='$wvar' SESSION_ID='$session_id' "
        . "exec '$script' '$port' '$output_file'";
}

sub live_log_remove_stale_wrapper {
    my ($module_config_directory) = @_;
    return unless defined $module_config_directory && $module_config_directory ne '';
    my $stale = "$module_config_directory/joblogserver.pl";
    unlink($stale) if -f $stale;
}

# Decode lang / file bytes to Perl UTF-8 for JSON and UI output.
sub job_log_utf8_decode {
    my ($s) = @_;
    $s //= '';
    return $s if utf8::is_utf8($s);
    require Encode;
    return Encode::decode('UTF-8', $s, Encode::FB_DEFAULT());
}

sub _job_log_json_utf8_deep {
    my ($v) = @_;
    if (!ref $v) {
        return undef unless defined $v;
        return $v + 0 if !ref($v) && $v =~ /^-?\d+$/;
        return job_log_utf8_decode($v);
    }
    if (ref $v eq 'HASH') {
        my %h;
        @h{keys %$v} = map { _job_log_json_utf8_deep($_) } values %$v;
        return \%h;
    }
    if (ref $v eq 'ARRAY') {
        return [ map { _job_log_json_utf8_deep($_) } @$v ];
    }
    return $v;
}

# ASCII JSON (\u escapes) for <script> blocks — safe when Webmin iframe charset is not UTF-8.
sub job_log_json_for_script {
    my ($data) = @_;
    require JSON::PP;
    return JSON::PP->new->ascii->allow_nonref->encode(_job_log_json_utf8_deep($data));
}

# UTF-8 JSON for fetch/XHR responses (Content-Type: application/json; charset=utf-8).
sub job_log_json_utf8 {
    my ($data) = @_;
    require JSON::PP;
    return JSON::PP->new->utf8->allow_nonref->encode(_job_log_json_utf8_deep($data));
}

# Shared scrollable log viewer (job live, poll fallback, jobs list, server monitor).
sub job_log_view_page_css {
    return <<'CSS';
<meta charset="utf-8">
<style>
html.lgsm-job-log-lock,
html.lgsm-job-log-lock body {
  overflow: hidden !important;
  height: 100%;
  max-height: 100vh;
}
.lgsm-job-log-page {
  padding-bottom: 72px;
  box-sizing: border-box;
  max-width: 100%;
}
.lgsm-job-log-toolbar {
  margin: 0 0 12px 0;
}
/* Full-viewport variant (live polling): toolbar fixed, only log area scrolls. */
.lgsm-job-log-page-fill {
  display: flex;
  flex-direction: column;
  min-height: 320px;
  padding-bottom: 0;
  overflow: hidden;
  box-sizing: border-box;
}
.lgsm-job-log-page-fill .lgsm-job-log-toolbar {
  flex: 0 0 auto;
  overflow: visible;
  z-index: 1;
}
.lgsm-job-log-page-fill .lgsm-job-log-scrollhost {
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}
.lgsm-job-log-page-fill .lgsm-job-log-scrollhost .lgsm-job-log-view {
  flex: 1 1 auto;
  min-height: 0;
  max-height: 100%;
  height: auto;
  overflow: auto;
  overscroll-behavior: contain;
  -webkit-overflow-scrolling: touch;
}
.lgsm-job-log-toolbar form {
  display: inline-block;
  margin: 0 8px 8px 0;
  vertical-align: middle;
}
.lgsm-job-log-view {
  display: block;
  width: 100%;
  background: #111;
  color: #eee;
  border: 1px solid #333;
  border-radius: 4px;
  padding: 10px 12px 28px 12px;
  margin: 0;
  overflow: auto;
  max-height: calc(100vh - 320px);
  min-height: 240px;
  box-sizing: border-box;
  white-space: pre-wrap;
  word-break: break-word;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 13px;
  line-height: 1.45;
  scroll-padding-bottom: 28px;
}
.lgsm-job-live-page {
  display: flex;
  flex-direction: column;
  height: calc(100vh - 140px);
  min-height: 420px;
  max-width: 100%;
  padding-bottom: 72px;
  box-sizing: border-box;
}
.lgsm-job-live-toolbar {
  flex: 0 0 auto;
  margin-bottom: 10px;
}
.lgsm-job-live-toolbar form {
  display: inline-block;
  margin: 0 8px 8px 0;
  vertical-align: middle;
}
.lgsm-job-live-actions {
  margin: 8px 0 0 0;
}
#job_terminal {
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
  box-sizing: border-box;
  border: 1px solid #333;
  border-radius: 4px;
  background: #111;
  padding: 4px 4px 32px 4px;
  overflow: auto;
}
#job_terminal .terminal,
#job_terminal .xterm {
  height: calc(100% - 8px) !important;
  min-height: 200px;
}
#job_terminal .xterm-viewport {
  overflow-y: auto !important;
  overflow-x: hidden !important;
}
.lgsm-job-log-spacer {
  display: block;
  height: 1.5em;
  line-height: 1.5em;
  pointer-events: none;
}
.lgsm-job-pulse {
  display: inline-block;
  width: 11px;
  height: 11px;
  margin-right: 8px;
  border-radius: 50%;
  background: #38c172;
  vertical-align: middle;
  box-shadow: 0 0 0 0 rgba(56, 193, 114, 0.7);
  animation: lgsm-job-pulse 1.2s ease-in-out infinite;
}
@keyframes lgsm-job-pulse {
  0%   { opacity: 1;    transform: scale(1);    box-shadow: 0 0 0 0 rgba(56, 193, 114, 0.7); }
  50%  { opacity: 0.45; transform: scale(0.7);  box-shadow: 0 0 0 5px rgba(56, 193, 114, 0); }
  100% { opacity: 1;    transform: scale(1);    box-shadow: 0 0 0 0 rgba(56, 193, 114, 0); }
}
@media (prefers-reduced-motion: reduce) {
  .lgsm-job-pulse { animation: none; opacity: 0.85; }
}
#job_terminal .xterm-decoration-overview-ruler,
#job_terminal .xterm-decoration-top {
  display: none !important;
}
</style>
CSS
}

sub job_log_view_page_open {
    my ($variant) = @_;
    my $cls = 'lgsm-job-log-page';
    $cls .= ' lgsm-job-log-page-fill' if defined $variant && $variant eq 'fill';
    return "<div class=\"$cls\">\n";
}

sub job_log_view_page_close {
    return "</div>\n";
}

sub job_log_view_toolbar_open {
    return "<div class=\"lgsm-job-log-toolbar\">\n";
}

sub job_log_view_toolbar_close {
    return "</div>\n";
}

sub job_log_view_pre {
    my ($content, %opts) = @_;
    my $id = $opts{'id'} // '';
    my $id_attr = '';
    if ($id ne '' && $id =~ /^[a-zA-Z0-9_-]+$/) {
        $id_attr = ' id="' . &html_escape($id) . '"';
    }
    return "<pre class=\"lgsm-job-log-view\"$id_attr>"
        . "<span class=\"lgsm-job-log-body\">"
        . &html_escape($content // '')
        . "</span><span class=\"lgsm-job-log-spacer\">&#160;</span></pre>\n";
}

# Live polling pages: scroll host wrapper, no MutationObserver auto-scroll.
sub job_log_view_pre_live {
    my ($content, %opts) = @_;
    return "<div class=\"lgsm-job-log-scrollhost\">\n"
        . &job_log_view_pre($content, %opts)
        . "</div>\n";
}

# Scrollable <pre> block — static views auto-scroll; live => 1 skips forced scroll JS.
sub job_log_view_block {
    my ($content, %opts) = @_;
    my $id = $opts{'id'} // 'job_log';
    if ($opts{'live'}) {
        return &job_log_view_pre_live($content, id => $id);
    }
    return &job_log_view_pre($content, id => $id)
        . &job_log_view_scroll_js("#$id");
}

# Lock page scroll and size the fill container to remaining viewport (Webmin iframe).
sub job_log_live_page_js {
    return <<'JS';
<script>
(function () {
  document.documentElement.classList.add("lgsm-job-log-lock");
  function fitLiveLogPage() {
    var page = document.querySelector(".lgsm-job-log-page-fill");
    if (!page) return;
    var top = page.getBoundingClientRect().top;
    var h = Math.max(320, window.innerHeight - top - 12);
    page.style.height = h + "px";
    page.style.maxHeight = h + "px";
  }
  fitLiveLogPage();
  window.addEventListener("resize", fitLiveLogPage);
})();
</script>
JS
}

# Shared JSON poll client: smart auto-scroll (only when user is near bottom).
sub job_log_live_poll_client_js {
    my (%opts) = @_;
    require JSON::PP;
    my %js = (
        pollUrl       => $opts{poll_url}       // '',
        manageUrl     => $opts{manage_url}     // '',
        refreshUrl    => $opts{refresh_url}    // '',
        outId         => $opts{out_id}         // 'job_out',
        statusId      => $opts{status_id}      // '',
        hintId        => $opts{hint_id}        // '',
        waitMsg       => $opts{wait_msg}       // '',
        okMsg         => $opts{ok_msg}         // '',
        failMsg       => $opts{fail_msg}       // '',
        abortedMsg    => $opts{aborted_msg}    // '',
        runningMsg    => $opts{running_msg}   // '',
        pollFailMsg   => $opts{poll_fail_msg}  // '',
        actionSuffix  => $opts{action_suffix}  // '',
        fallbackMsg   => $opts{fallback_msg}   // '',
        pollInterval  => 0 + ($opts{poll_interval}  // 1500),
        redirectDelay => 0 + ($opts{redirect_delay} // 800),
        useDoneField  => $opts{use_done_field} ? 1 : 0,
        metaFallback  => $opts{enable_meta_fallback} ? 1 : 0,
    );
    my $json = job_log_json_for_script(\%js);
    return <<"JS";
<script>
(function () {
  var O = $json;
  var outEl = document.getElementById(O.outId);
  var statusEl = O.statusId ? document.getElementById(O.statusId) : null;
  var hintEl = O.hintId ? document.getElementById(O.hintId) : null;
  var pollTimer = null;
  var failCount = 0;
  var metaOn = false;

  function isNearBottom(el, threshold) {
    if (!el) return true;
    threshold = threshold || 80;
    return (el.scrollHeight - el.scrollTop - el.clientHeight) <= threshold;
  }

  function scrollOutIfNear() {
    if (!outEl || !isNearBottom(outEl)) return;
    outEl.scrollTop = outEl.scrollHeight;
  }

  function setOutText(text) {
    if (!outEl) return;
    var stick = isNearBottom(outEl);
    var body = outEl.querySelector(".lgsm-job-log-body");
    if (body) {
      body.textContent = text || O.waitMsg;
    } else {
      outEl.textContent = text || O.waitMsg;
      var pad = document.createElement("span");
      pad.className = "lgsm-job-log-spacer";
      pad.textContent = "\u00a0";
      outEl.appendChild(pad);
    }
    if (stick) {
      outEl.scrollTop = outEl.scrollHeight;
    }
  }

  function makePulse() {
    var dot = document.createElement("span");
    dot.className = "lgsm-job-pulse";
    dot.setAttribute("aria-hidden", "true");
    return dot;
  }

  function setStatusWithPulse(msg) {
    if (!statusEl) return;
    statusEl.textContent = "";
    statusEl.appendChild(makePulse());
    statusEl.appendChild(document.createTextNode(msg));
  }

  function stopPoll() {
    if (pollTimer) {
      window.clearInterval(pollTimer);
      pollTimer = null;
    }
  }

  function finishDone(st) {
    stopPoll();
    if (st === "ok") {
      if (statusEl) {
        statusEl.style.color = "green";
        statusEl.textContent = O.okMsg + (O.actionSuffix || "");
      }
      if (O.manageUrl) {
        window.setTimeout(function () {
          window.location.replace(O.manageUrl);
        }, O.redirectDelay);
      }
      return;
    }
    if (st === "aborted") {
      if (statusEl) {
        statusEl.style.color = "";
        statusEl.textContent = O.abortedMsg || O.okMsg;
      }
      return;
    }
    if (statusEl) {
      statusEl.style.color = "red";
      statusEl.textContent = O.failMsg + (O.actionSuffix || "");
    }
  }

  function enableMetaFallback() {
    if (!O.metaFallback || metaOn || !O.refreshUrl) return;
    metaOn = true;
    var m = document.createElement("meta");
    m.httpEquiv = "refresh";
    m.content = "2;url=" + O.refreshUrl;
    document.head.appendChild(m);
    if (hintEl) hintEl.textContent = O.fallbackMsg;
  }

  function pollOnce() {
    fetch(O.pollUrl, { credentials: "same-origin", cache: "no-store" })
      .then(function (r) {
        if (!r.ok) throw new Error("http " + r.status);
        return r.json();
      })
      .then(function (d) {
        failCount = 0;
        if (typeof d.output === "string") {
          setOutText(d.output || O.waitMsg);
        } else if (outEl && !outEl.textContent.trim()) {
          setOutText(O.waitMsg);
        }
        if (O.useDoneField) {
          if (!d.done) {
            setStatusWithPulse(O.runningMsg + (O.actionSuffix || ""));
            return;
          }
          finishDone(d.status);
          return;
        }
        if (d.status === "running") {
          setStatusWithPulse(O.runningMsg + (O.actionSuffix || ""));
          return;
        }
        finishDone(d.status);
      })
      .catch(function () {
        failCount++;
        if (O.metaFallback && failCount >= 2) {
          enableMetaFallback();
          return;
        }
        if (O.pollFailMsg && statusEl) statusEl.textContent = O.pollFailMsg;
      });
  }

  scrollOutIfNear();
  pollOnce();
  pollTimer = window.setInterval(pollOnce, O.pollInterval);

  var abortInput = document.querySelector('form input[name="action"][value="abort_job"]');
  if (abortInput && abortInput.form) {
    abortInput.form.addEventListener("submit", stopPoll);
  }
})();
</script>
JS
}

sub job_log_view_scroll_js {
    my ($selector) = @_;
    $selector //= '.lgsm-job-log-view';
    $selector =~ s/\\/\\\\/g;
    $selector =~ s/'/\\'/g;
    return <<"JS";
<script>
(function () {
  var el = document.querySelector('$selector');
  if (!el) return;
  function scrollBottom() {
    var spacer = el.querySelector(".lgsm-job-log-spacer");
    if (spacer && typeof spacer.scrollIntoView === "function") {
      spacer.scrollIntoView({ block: "end", behavior: "auto" });
      return;
    }
    el.scrollTop = el.scrollHeight;
  }
  function scheduleScroll() {
    if (typeof requestAnimationFrame === "function") {
      requestAnimationFrame(scrollBottom);
    } else {
      scrollBottom();
    }
  }
  scheduleScroll();
  window.addEventListener("load", scheduleScroll);
  if (typeof MutationObserver !== "undefined") {
    new MutationObserver(scheduleScroll).observe(el, {
      childList: true, characterData: true, subtree: true
    });
  }
})();
</script>
JS
}

1;
