# Shared Start / Stop / Restart / Log / Back control bar (mods, workshop, …).
# Game-agnostic: callers supply status HTML and handle monitor enable/disable.
use strict;
use warnings;

our (%text);

our $_server_control_soft_js_emitted = 0;

# Status badge with solid/pulsing CSS dots (caller prints job_status_pulse_css once).
sub server_runtime_status_badge_html {
    my ($status) = @_;
    $status //= 'unknown';
    if ($status eq 'starting') {
        my $label = $text{'manage_status_starting'}
            // $text{'mc_mods_page_status_starting'}
            // 'Starting…';
        return '<span class="lgsm-job-pulse" aria-hidden="true"></span>'
            . &html_escape($label);
    }
    my %labels = (
        online     => ($text{'mc_mods_page_status_online'}  // 'Running'),
        running    => ($text{'mc_mods_page_status_online'}  // 'Running'),
        offline    => ($text{'mc_mods_page_status_offline'} // 'Not started'),
        stopped    => ($text{'mc_mods_page_status_offline'} // 'Not started'),
        fresh      => ($text{'mc_mods_page_status_fresh'}   // 'Provisioning pending'),
        lgsm_ready => ($text{'mc_mods_page_status_lgsm'}    // 'Installation pending'),
        mc_ready   => ($text{'mc_mods_page_status_mc'}      // 'Minecraft prepared'),
        unknown    => ($text{'mc_mods_page_status_unknown'} // 'Unknown'),
    );
    my $label = $labels{$status} // ($text{'mc_mods_page_status_unknown'} // 'Unknown');
    my $dot_class = 'lgsm-status-dot';
    if ($status eq 'online' || $status eq 'running') {
        # solid green
    }
    elsif ($status eq 'offline' || $status eq 'stopped') {
        $dot_class .= ' lgsm-status-dot-off';
    }
    else {
        $dot_class .= ' lgsm-status-dot-warn';
    }
    return '<span class="' . $dot_class . '" aria-hidden="true"></span>'
        . &html_escape($label);
}

# Inline form wrapper (same pattern as mods.cgi / manage.cgi toolbars).
sub server_control_bar_inline_btn {
    my ($html) = @_;
    $html //= '';
    $html =~ s/<form(\s)/<form style="display:inline-block;margin:0;vertical-align:middle"$1/i;
    return "<span style='display:inline-block;margin:0 8px 6px 0;vertical-align:middle'>$html</span>";
}

# True when the client asked for JSON (soft Start/Stop) instead of a full redirect.
sub server_control_async_requested {
    my ($in_ref) = @_;
    $in_ref = \%main::in unless ref($in_ref) eq 'HASH';
    return 1 if (($in_ref->{'async'} // '') eq '1');
    my $accept = $ENV{'HTTP_ACCEPT'} // '';
    return 1 if $accept =~ m{application/json}i;
    my $xrw = $ENV{'HTTP_X_REQUESTED_WITH'} // '';
    return 1 if lc($xrw) eq 'fetch' || lc($xrw) eq 'xmlhttprequest';
    return 0;
}

# Emit JSON payload and exit ( forego Webmin HTML error pages for soft actions).
sub server_control_async_json_exit {
    my ($payload) = @_;
    $payload = {} unless ref($payload) eq 'HASH';
    $main::headerprinted = 1;
    print "Content-type: application/json; charset=utf-8\n\n";
    if (defined &job_log_json_utf8) {
        print job_log_json_utf8($payload);
    }
    else {
        require JSON::PP;
        print JSON::PP->new->utf8->encode($payload);
    }
    exit;
}

# Soft fetch must never see Webmin HTML &error pages ("Ungültige Eingabe") — those
# look like dispatch failure and users click Start/Stop again, stacking jobs.
# Install once per CGI request when the client asked for JSON.
our $_server_control_async_error_trapped = 0;
sub server_control_install_async_error_trap {
    my ($in_ref) = @_;
    return 0 if $_server_control_async_error_trapped;
    return 0 unless server_control_async_requested($in_ref);
    $_server_control_async_error_trapped = 1;
    my $prev = \&main::error;
    no warnings 'redefine';
    *main::error = sub {
        my ($msg) = @_;
        $msg = defined $msg && "$msg" ne '' ? "$msg" : 'Error';
        *main::error = $prev;
        server_control_async_json_exit({ ok => 0, error => $msg });
    };
    return 1;
}

# First usable scalar from Webmin ReadParse (arrayref / "\0"-joined multi-value).
sub server_control_form_scalar {
    my ($raw) = @_;
    return '' unless defined $raw;
    my @vals;
    if (ref($raw) eq 'ARRAY') {
        @vals = @$raw;
    }
    else {
        @vals = index("$raw", "\0") >= 0 ? split(/\0/, "$raw") : ($raw);
    }
    for my $v (@vals) {
        next unless defined $v;
        $v =~ s/^\s+|\s+$//g;
        return $v if $v ne '';
    }
    return '';
}

# Mark a POST form for soft fetch dispatch (no theme full-page progress bar).
sub server_control_soft_form {
    my ($form_html) = @_;
    $form_html //= '';
    $form_html =~ s/<form(\s)/<form class="js-lgsm-soft-action"$1/i
        unless $form_html =~ /js-lgsm-soft-action/;
    unless ($form_html =~ /name=["']async["']/) {
        my $hidden = &ui_hidden('async', '1');
        if ($form_html =~ m{</form>}i) {
            $form_html =~ s{</form>}{$hidden</form>}i;
        }
        else {
            $form_html .= $hidden;
        }
    }
    return $form_html;
}

# Checkbox next to Start/Stop: Dev-Start opens embedded live start-log after start/restart.
# Preference persists in localStorage; server default follows Integrations manage_show_start_log.
sub server_control_dev_start_toggle_html {
    my (%opts) = @_;
    my $default_on = $opts{'default_on'};
    if (!defined $default_on) {
        $default_on = (defined &server_log_start_log_enabled && &server_log_start_log_enabled()) ? 1 : 0;
    }
    my $label = &html_escape($text{'manage_dev_start_label'} || 'Dev-Start');
    my $hint = &html_escape($text{'manage_dev_start_hint'}
        || 'Nach Start/Neustart Live-Log auf dieser Seite einblenden');
    my $checked = $default_on ? ' checked' : '';
    return "<label class=\"js-lgsm-dev-start-label\" style=\"display:inline-block;margin:0 12px 6px 0;vertical-align:middle;white-space:nowrap\" title=\"$hint\">"
        . "<input type=\"checkbox\" class=\"js-lgsm-dev-start\" id=\"lgsm_dev_start\" value=\"1\"$checked>"
        . " <span>$label</span></label>\n";
}

sub server_control_dev_start_slot_html {
    return "<div id=\"lgsm_dev_start_slot\"></div>\n";
}

# One-shot JS: intercept .js-lgsm-soft-action POST, toast overlay + silent job poll.
# Feels like a background job: page stays usable, badge blinks, corner toast + Live-Log.
sub server_control_soft_action_js {
    return '' if $_server_control_soft_js_emitted++;
    my $cfg = '';
    if (defined &job_log_json_for_script) {
        $cfg = job_log_json_for_script({
            runningMsg   => ($text{'manage_action_running'} || 'Aktion läuft…'),
            startedMsg   => ($text{'manage_action_bg_started'}
                || 'Im Hintergrund gestartet…'),
            busyMsg      => ($text{'manage_action_busy'}
                || 'Eine Aktion läuft bereits — bitte warten.'),
            pollErrorMsg => ($text{'manage_action_poll_error'}
                || 'Statusabfrage fehlgeschlagen — Seite neu laden.'),
            dispatchErr  => ($text{'manage_action_dispatch_failed'}
                || 'Aktion konnte nicht gestartet werden.'),
            liveLabel    => ($text{'manage_job_open_live'} || 'Live-Log öffnen'),
            pollInterval => 500,
            storageKey   => 'lgsm_dev_start',
        });
    }
    else {
        $cfg = '{}';
    }
    return <<"JS";
<style>
#lgsm_soft_toast {
  position: fixed; z-index: 10050; right: 16px; bottom: 16px; max-width: 360px;
  margin: 0; box-shadow: 0 4px 16px rgba(0,0,0,.18); display: none;
}
#lgsm_soft_toast .lgsm-soft-toast-actions { margin-top: 6px; font-size: 90%; }
#lgsm_soft_toast .lgsm-soft-toast-actions a { margin-right: 10px; }
#lgsm_soft_page_banner {
  margin: 8px 0 12px 0;
}
#lgsm_soft_page_banner .lgsm-soft-toast-actions { margin-top: 6px; font-size: 90%; }
#lgsm_soft_page_banner .lgsm-soft-toast-actions a { margin-right: 10px; }
</style>
<div id="lgsm_soft_toast" class="alert alert-info" role="status" aria-live="polite"></div>
<script>
(function () {
  /* Refresh config on every page paint (xnavigation). Bind submit only once. */
  window.__lgsmSoftCfg = $cfg;
  if (window.__lgsmSoftActionBound) {
    try { window.__lgsmSoftSyncDev && window.__lgsmSoftSyncDev(); } catch (e) {}
    return;
  }
  window.__lgsmSoftActionBound = 1;
  var timer = null;
  var runtimeTimer = null;
  var failCount = 0;
  var hideTimer = null;
  var disabledBtns = [];
  function cfg() { return window.__lgsmSoftCfg || {}; }
  function setBusy(on) {
    window.__lgsmSoftBusy = on ? 1 : 0;
  }
  function disableFormButtons(form) {
    disabledBtns = [];
    if (!form) return;
    var nodes = form.querySelectorAll("input[type=submit],button[type=submit],button:not([type])");
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].disabled) continue;
      nodes[i].disabled = true;
      disabledBtns.push(nodes[i]);
    }
  }
  function restoreFormButtons() {
    for (var i = 0; i < disabledBtns.length; i++) {
      try { disabledBtns[i].disabled = false; } catch (e) {}
    }
    disabledBtns = [];
  }

  function escapeHtml(s) {
    return String(s || "").replace(/[&<>"']/g, function (c) {
      return ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" })[c];
    });
  }
  function ensureToast() {
    var t = document.getElementById("lgsm_soft_toast");
    if (t) return t;
    t = document.createElement("div");
    t.id = "lgsm_soft_toast";
    t.className = "alert alert-info";
    t.setAttribute("role", "status");
    t.setAttribute("aria-live", "polite");
    t.style.display = "none";
    document.body.appendChild(t);
    return t;
  }
  function ensurePageBanner() {
    var b = document.getElementById("lgsm_soft_page_banner");
    if (b) return b;
    b = document.createElement("div");
    b.id = "lgsm_soft_page_banner";
    b.className = "alert alert-info";
    b.setAttribute("role", "status");
    b.style.display = "none";
    var anchor = document.querySelector(".js-runtime-status");
    var table = anchor ? anchor.closest("table") : null;
    if (table && table.parentNode) {
      table.parentNode.insertBefore(b, table);
    } else {
      var content = document.getElementById("content")
        || document.querySelector(".panel-body")
        || document.body;
      content.insertBefore(b, content.firstChild);
    }
    return b;
  }
  function devStartBox() {
    return document.getElementById("lgsm_dev_start")
      || document.querySelector(".js-lgsm-dev-start");
  }
  function syncDevStartFromStorage() {
    var box = devStartBox();
    if (!box) return;
    var storageKey = (cfg().storageKey || "lgsm_dev_start");
    try {
      var v = window.localStorage.getItem(storageKey);
      if (v === "1") box.checked = true;
      else if (v === "0") box.checked = false;
    } catch (e) {}
  }
  window.__lgsmSoftSyncDev = syncDevStartFromStorage;
  function persistDevStart() {
    var box = devStartBox();
    if (!box) return;
    var storageKey = (cfg().storageKey || "lgsm_dev_start");
    try {
      window.localStorage.setItem(storageKey, box.checked ? "1" : "0");
    } catch (e) {}
  }
  function loadStartLogPanel(url) {
    if (!url) return;
    var slot = document.getElementById("lgsm_dev_start_slot");
    if (!slot) return;
    fetch(url, { credentials: "same-origin", cache: "no-store" })
      .then(function (r) { if (!r.ok) throw new Error("http"); return r.text(); })
      .then(function (html) {
        slot.innerHTML = html || "";
        /* Re-execute scripts from injected fragment (innerHTML skips them). */
        var scripts = slot.querySelectorAll("script");
        for (var i = 0; i < scripts.length; i++) {
          var s = document.createElement("script");
          if (scripts[i].src) s.src = scripts[i].src;
          else s.text = scripts[i].textContent || "";
          document.body.appendChild(s);
        }
        try { slot.scrollIntoView({ behavior: "smooth", block: "nearest" }); } catch (e) {}
      })
      .catch(function () {});
  }
  function showToast(cls, msg, extraHtml) {
    if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
    var html = "<strong>" + escapeHtml(msg || "") + "</strong>";
    if (extraHtml) html += "<div class=\\"lgsm-soft-toast-actions\\">" + extraHtml + "</div>";
    var toast = ensureToast();
    toast.style.display = "";
    toast.className = "alert " + (cls || "alert-info");
    toast.innerHTML = html;
    var banner = ensurePageBanner();
    banner.style.display = "";
    banner.className = "alert " + (cls || "alert-info");
    banner.innerHTML = html;
  }
  function hideFeedback() {
    var toast = document.getElementById("lgsm_soft_toast");
    if (toast) toast.style.display = "none";
    var banner = document.getElementById("lgsm_soft_page_banner");
    if (banner) banner.style.display = "none";
  }
  function hideToastLater(ms) {
    if (hideTimer) clearTimeout(hideTimer);
    hideTimer = window.setTimeout(function () {
      hideFeedback();
      hideTimer = null;
    }, ms || 4500);
  }
  function liveLinkHtml(url) {
    if (!url) return "";
    return "<a href=\\"" + escapeHtml(url) + "\\">"
      + escapeHtml(cfg().liveLabel || "Live log") + "</a>";
  }
  function setRuntimeHtml(html) {
    if (!html) return;
    if (window.__lgsmStartReadySeen && html.indexOf("lgsm-job-pulse") >= 0) return;
    var nodes = document.querySelectorAll(".js-runtime-status");
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].innerHTML = html;
    }
  }
  function optimisticStarting(action) {
    if (action !== "start" && action !== "restart") return;
    var nodes = document.querySelectorAll(".js-runtime-status");
    if (!nodes.length) return;
    var html = '<span class="lgsm-job-pulse" aria-hidden="true"></span>';
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].innerHTML.indexOf("lgsm-job-pulse") >= 0) continue;
      nodes[i].innerHTML = html + nodes[i].textContent;
    }
  }
  function pollRuntimeUntilReady(url) {
    if (!url) return;
    if (runtimeTimer) return;
    function once() {
      if (window.__lgsmStartReadySeen) { runtimeTimer = null; return; }
      fetch(url, { credentials: "same-origin", cache: "no-store" })
        .then(function (r) { if (!r.ok) throw new Error("http"); return r.json(); })
        .then(function (d) {
          if (window.__lgsmStartReadySeen) { runtimeTimer = null; return; }
          if (d.runtime_html) setRuntimeHtml(d.runtime_html);
          if (d.starting) {
            runtimeTimer = window.setTimeout(once, 2000);
          } else {
            runtimeTimer = null;
          }
        })
        .catch(function () {
          runtimeTimer = window.setTimeout(once, 3000);
        });
    }
    once();
  }
  function finishPoll(d, pollUrl, runtimeUrl, startBlink) {
    if (timer) { clearInterval(timer); timer = null; }
    setBusy(0);
    restoreFormButtons();
    if (pollUrl) {
      var markUrl = pollUrl + (pollUrl.indexOf("?") >= 0 ? "&" : "?") + "mark_result=1";
      fetch(markUrl, { credentials: "same-origin", cache: "no-store" }).catch(function () {});
    }
    if (d.status === "ok") {
      showToast("alert-success", d.notice_msg || "");
    } else if (d.status === "aborted") {
      showToast("alert-info", d.notice_msg || "");
    } else {
      showToast("alert-danger", d.notice_msg || "");
    }
    if (d.runtime_html) setRuntimeHtml(d.runtime_html);
    if (d.starting || (startBlink && d.status === "ok" && d.runtime_status === "starting")) {
      pollRuntimeUntilReady(runtimeUrl);
    }
    hideToastLater(4500);
  }
  function startSilentPoll(d) {
    var C = cfg();
    var pollUrl = d.poll_url || "";
    var runtimeUrl = d.runtime_poll_url || "";
    var startBlink = !!d.start_blink;
    if (!pollUrl) {
      showToast("alert-danger", C.dispatchErr || "Dispatch failed");
      setBusy(0);
      restoreFormButtons();
      return;
    }
    showToast(
      "alert-info",
      C.startedMsg || C.runningMsg || "Running…",
      liveLinkHtml(d.live_url)
    );
    if (d.runtime_html) setRuntimeHtml(d.runtime_html);
    if (d.start_log && d.start_log_panel_url) {
      loadStartLogPanel(d.start_log_panel_url);
    }
    failCount = 0;
    function pollOnce() {
      fetch(pollUrl, { credentials: "same-origin", cache: "no-store" })
        .then(function (r) {
          if (!r.ok) throw new Error("http " + r.status);
          return r.json();
        })
        .then(function (jd) {
          failCount = 0;
          if (jd.status === "running") {
            if (jd.runtime_html) setRuntimeHtml(jd.runtime_html);
            return;
          }
          finishPoll(jd, pollUrl, runtimeUrl, startBlink);
        })
        .catch(function () {
          failCount++;
          if (failCount >= 6) {
            showToast("alert-warning", cfg().pollErrorMsg || "Poll failed");
            if (timer) { clearInterval(timer); timer = null; }
            setBusy(0);
            restoreFormButtons();
          }
        });
    }
    pollOnce();
    timer = setInterval(pollOnce, C.pollInterval || 500);
  }
  function onSoftSubmit(ev) {
    var form = ev.target;
    if (!form || !form.classList || !form.classList.contains("js-lgsm-soft-action")) return;
    if (window.__lgsmSoftBusy) {
      ev.preventDefault();
      showToast("alert-warning", cfg().busyMsg || "Busy");
      hideToastLater(4000);
      return;
    }
    if ((form.getAttribute("method") || "get").toLowerCase() !== "post") return;
    ev.preventDefault();
    ev.stopPropagation();
    setBusy(1);
    disableFormButtons(form);
    var fd = new FormData(form);
    if (!fd.has("async")) fd.set("async", "1");
    var box = devStartBox();
    if (box && box.checked) fd.set("dev_start", "1");
    else fd.delete("dev_start");
    persistDevStart();
    var act = String(fd.get("action") || "");
    optimisticStarting(act);
    showToast("alert-info", cfg().runningMsg || "Running…");
    var actionUrl = form.getAttribute("action") || window.location.href;
    fetch(actionUrl, {
      method: "POST",
      body: fd,
      credentials: "same-origin",
      cache: "no-store",
      headers: {
        "Accept": "application/json",
        "X-Requested-With": "fetch"
      }
    }).then(function (r) {
      var ct = (r.headers.get("content-type") || "").toLowerCase();
      if (ct.indexOf("application/json") >= 0) {
        return r.json().then(function (d) { return { okHttp: r.ok, d: d }; });
      }
      throw new Error("non-json");
    }).then(function (res) {
      var d = res.d || {};
      if (!res.okHttp || d.ok === 0 || d.ok === false) {
        showToast("alert-danger", d.error || cfg().dispatchErr || "Dispatch failed");
        setBusy(0);
        restoreFormButtons();
        hideToastLater(6000);
        return;
      }
      if (d.mode === "redirect" || d.mode === "job_live") {
        if (d.redirect) {
          window.location.assign(d.redirect);
          return;
        }
      }
      if (d.poll_url) {
        startSilentPoll(d);
        return;
      }
      if (d.redirect) {
        window.location.assign(d.redirect);
        return;
      }
      showToast("alert-success", d.notice_msg || "");
      setBusy(0);
      restoreFormButtons();
      hideToastLater(4500);
    }).catch(function () {
      showToast("alert-danger", cfg().dispatchErr || "Dispatch failed");
      setBusy(0);
      restoreFormButtons();
      hideToastLater(6000);
    });
  }
  syncDevStartFromStorage();
  document.addEventListener("change", function (ev) {
    var t = ev.target;
    if (!t) return;
    if (t.id === "lgsm_dev_start" || (t.classList && t.classList.contains("js-lgsm-dev-start"))) {
      persistDevStart();
    }
  }, true);
  window.addEventListener("pageshow", function () {
    setBusy(0);
    restoreFormButtons();
    syncDevStartFromStorage();
  });
  document.addEventListener("submit", onSoftSubmit, true);
})();
</script>
JS
}

# opts:
#   cgi                 => form action CGI (required for useful markup)
#   instance_id         => instance id
#   readonly            => bool — hide start/stop/restart
#   runtime_status_html => pre-rendered status badge HTML
#   extra_status_parts  => arrayref of ui_instance_status_part strings
#   after_status_html   => HTML inserted between status line and action buttons
#   actions             => list among start stop restart log back (default all)
#   back_cgi            => default manage.cgi
#   back_label          => optional override for Back button label
#   readonly_hint       => optional override for readonly message
#   soft_actions        => bool (default 1) — fetch POST for start/stop/restart
sub server_control_bar_html {
    my (%opts) = @_;
    my $cgi = $opts{'cgi'} // '';
    $cgi =~ s/[^a-zA-Z0-9_.-]//g;
    $cgi = 'manage.cgi' if $cgi eq '';

    my $instance_id = $opts{'instance_id'} // '';
    $instance_id =~ s/[^a-zA-Z0-9_-]//g;
    my $safe_id = &html_escape($instance_id);

    my $readonly = $opts{'readonly'} ? 1 : 0;
    my $soft = exists $opts{'soft_actions'} ? ($opts{'soft_actions'} ? 1 : 0) : 1;
    my $runtime_html = $opts{'runtime_status_html'} // '';
    if ($runtime_html =~ /\S/ && $runtime_html !~ /js-runtime-status/) {
        $runtime_html = '<span class="js-runtime-status">' . $runtime_html . '</span>';
    }
    my $extra = $opts{'extra_status_parts'};
    $extra = [] unless ref($extra) eq 'ARRAY';

    my $actions = $opts{'actions'};
    if (!defined $actions) {
        $actions = [qw(start stop restart log back)];
    }
    elsif (ref($actions) ne 'ARRAY') {
        $actions = [ grep { length } split /\s+/, "$actions" ];
    }
    my %want = map { $_ => 1 } @$actions;

    my $back_cgi = $opts{'back_cgi'} // 'manage.cgi';
    $back_cgi =~ s/[^a-zA-Z0-9_.-]//g;
    $back_cgi = 'manage.cgi' if $back_cgi eq '';

    my $back_label = $opts{'back_label'}
        // $text{'mc_mods_page_back_manage'}
        // 'Back to manage';
    my $readonly_hint = $opts{'readonly_hint'}
        // $text{'mc_mods_page_readonly_hint'}
        // 'Read-only mode: Start/Stop actions are disabled.';

    my $start_label = $text{'mc_mods_page_start_btn'} || 'Start';
    my $stop_label  = $text{'mc_mods_page_stop_btn'}  || 'Stop';
    my $restart_label = $text{'jobs_action_restart'}
        || $text{'mc_mods_page_restart_btn'}
        || 'Restart';
    my $log_label = $text{'mc_mods_page_log_btn'} || 'Log';

    my $inst_label = $text{'mc_mods_page_instance_label'} || 'Instance';
    my $stat_label = $text{'mc_mods_page_status_label'}
        || $text{'manage_status'}
        || 'Status';

    my @parts;
    push @parts, &ui_instance_status_part($inst_label, $safe_id) if $safe_id ne '';
    push @parts, &ui_instance_status_part($stat_label, $runtime_html)
        if defined $runtime_html && $runtime_html =~ /\S/;
    push @parts, grep { defined && /\S/ } @$extra;

    my $html = '';
    $html .= &ui_instance_status_line(@parts) if @parts;

    my $after = $opts{'after_status_html'} // '';
    $html .= $after if $after ne '';

    $html .= "<div style='margin:4px 0 12px 0'>\n";

    my $mutates = ($want{'start'} || $want{'stop'} || $want{'restart'}) ? 1 : 0;
    my $emitted_soft = 0;
    my $want_dev = exists $opts{'dev_start_toggle'}
        ? ($opts{'dev_start_toggle'} ? 1 : 0)
        : 1;
    if ($readonly && $mutates) {
        $html .= "<p>" . &html_escape($readonly_hint) . "</p>\n";
    }
    elsif (!$readonly) {
        if ($want_dev && $mutates) {
            $html .= server_control_dev_start_toggle_html(
                default_on => $opts{'dev_start_default'});
        }
        if ($want{'start'}) {
            my $form = &ui_form_start($cgi, 'post');
            $form .= &ui_hidden('instance_id', $safe_id);
            $form .= &ui_hidden('xnavigation', '1');
            $form .= &ui_hidden('action', 'start');
            $form .= &ui_submit($start_label, undef, undef, undef, 'btn-success');
            $form .= &ui_form_end();
            $form = server_control_soft_form($form) if $soft;
            $emitted_soft = 1 if $soft;
            $html .= server_control_bar_inline_btn($form);
        }
        if ($want{'stop'}) {
            my $form = &ui_form_start($cgi, 'post');
            $form .= &ui_hidden('instance_id', $safe_id);
            $form .= &ui_hidden('xnavigation', '1');
            $form .= &ui_hidden('action', 'stop');
            $form .= &ui_submit($stop_label, undef, undef, undef, 'btn-default');
            $form .= &ui_form_end();
            $form = server_control_soft_form($form) if $soft;
            $emitted_soft = 1 if $soft;
            $html .= server_control_bar_inline_btn($form);
        }
        if ($want{'restart'}) {
            my $form = &ui_form_start($cgi, 'post');
            $form .= &ui_hidden('instance_id', $safe_id);
            $form .= &ui_hidden('xnavigation', '1');
            $form .= &ui_hidden('action', 'restart');
            $form .= &ui_submit($restart_label, undef, undef, undef, 'btn-default');
            $form .= &ui_form_end();
            $form = server_control_soft_form($form) if $soft;
            $emitted_soft = 1 if $soft;
            $html .= server_control_bar_inline_btn($form);
        }
    }

    if ($want{'log'}) {
        my $form = &ui_form_start($cgi, 'get');
        $form .= &ui_hidden('instance_id', $safe_id);
        $form .= &ui_hidden('action', 'monitor');
        $form .= &ui_hidden('xnavigation', '1');
        $form .= &ui_submit($log_label, undef, undef, undef, 'btn-default');
        $form .= &ui_form_end();
        $html .= server_control_bar_inline_btn($form);
    }
    if ($want{'back'}) {
        my $form = &ui_form_start($back_cgi, 'get');
        $form .= &ui_hidden('instance_id', $safe_id);
        $form .= &ui_hidden('xnavigation', '1');
        $form .= &ui_submit($back_label, undef, undef, undef, 'btn-default');
        $form .= &ui_form_end();
        $html .= server_control_bar_inline_btn($form);
    }

    $html .= "</div>\n";
    $html .= server_control_dev_start_slot_html()
        if (!$readonly && $want_dev && $mutates);
    $html .= server_control_soft_action_js() if $emitted_soft;
    return $html;
}

1;
