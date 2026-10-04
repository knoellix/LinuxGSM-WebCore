# Progressive table loading helpers (workshop inventory, MC mods list).
use strict;
use warnings;

our (%text);

sub ui_progressive_dots_css {
    return <<'CSS';
<style>
.lgsm-load-dots { display: inline-block; margin-left: 4px; }
.lgsm-load-dots span {
  display: inline-block; opacity: 0.25;
  animation: lgsm-dot-wave 1.1s ease-in-out infinite;
}
.lgsm-load-dots span:nth-child(2) { animation-delay: 0.15s; }
.lgsm-load-dots span:nth-child(3) { animation-delay: 0.3s; }
@keyframes lgsm-dot-wave {
  0%, 80%, 100% { transform: translateY(0); opacity: 0.25; }
  40% { transform: translateY(-5px); opacity: 1; }
}
/* Authentic theme dots vertical th borders look like stray pipes — neutralize. */
#ws-inventory table.table > thead > tr > th,
#mc-mods-installed table.table > thead > tr > th {
  border-left: none !important;
  border-right: none !important;
}
#ws-inventory table.table > thead > tr > th::before,
#ws-inventory table.table > thead > tr > th::after,
#mc-mods-installed table.table > thead > tr > th::before,
#mc-mods-installed table.table > thead > tr > th::after {
  content: none !important;
  display: none !important;
  border: none !important;
}
#ws-inventory table.table,
#mc-mods-installed table.table {
  border-left: none !important;
  border-right: none !important;
}
img.lgsm-ws-preview {
  width: 32px;
  height: 32px;
  max-width: 32px;
  max-height: 32px;
  object-fit: cover;
  vertical-align: middle;
  margin-right: 8px;
  border-radius: 3px;
}
</style>
CSS
}

sub ui_progressive_dots_html {
    my ($id) = @_;
    $id //= 'lgsm-prog-dots';
    $id =~ s/[^a-zA-Z0-9_-]//g;
    $id = 'lgsm-prog-dots' if $id eq '';
    return '<span class="lgsm-load-dots" id="' . &html_escape($id)
        . '" aria-hidden="true"><span>.</span><span>.</span><span>.</span></span>';
}

# Client fetches pollUrl?offset=&limit= in batches.
# Preferred: complete `html` (full ui_columns_table) when done — avoids browser
# auto-closing an open <table><tbody> set via innerHTML (broken header borders).
# Legacy: count/done/next_offset/preamble_html/table_head_html/rows_html/table_foot_html
sub ui_progressive_table_loader_js {
    my (%opts) = @_;
    my $box_id = $opts{'box_id'} // 'prog-box';
    my $section_id = $opts{'section_id'} // '';
    my $poll_url = $opts{'poll_url'} // '';
    my $fail = $opts{'fail_msg'} // 'Load failed.';
    my $batch = int($opts{'batch_size'} // 5);
    $batch = 5 if $batch < 1;
    $box_id =~ s/[^a-zA-Z0-9_-]//g;
    $section_id =~ s/[^a-zA-Z0-9_-]//g;
    return '' if $box_id eq '' || $poll_url eq '';

    my $cfg;
    if (defined &job_log_json_for_script) {
        $cfg = job_log_json_for_script({
            pollUrl   => $poll_url,
            failMsg   => $fail,
            batchSize => $batch,
            boxId     => $box_id,
            sectionId => $section_id,
        });
    }
    else {
        $cfg = '{}';
    }
    my $css = ui_progressive_dots_css();
    return $css . <<"JS";
<script>
(function () {
  var C = $cfg;
  var box = document.getElementById(C.boxId || "$box_id");
  if (!box) return;
  var batch = C.batchSize || 5;
  var offset = 0;
  var started = false;
  function setBadge(n) {
    var sid = C.sectionId || "";
    if (!sid) return;
    var small = document.querySelector("#" + sid + " > summary .lgsm-section-title small");
    if (small) small.textContent = "(" + (n || 0) + ")";
  }
  function dotsHtml() {
    return '<p class="lgsm-inv-loading-line" id="' + (C.boxId || "prog") + '-dots">'
      + '<span class="lgsm-load-dots" aria-hidden="true">'
      + '<span>.</span><span>.</span><span>.</span></span></p>';
  }
  // Insert row HTML into <tbody> via DOM — never re-parse an open table with innerHTML.
  function appendRows(wrap, html) {
    if (!wrap || !html) return;
    var tbody = wrap.querySelector("tbody");
    if (tbody) {
      tbody.insertAdjacentHTML("beforeend", html);
      return;
    }
    var table = wrap.querySelector("table");
    if (table) {
      table.insertAdjacentHTML("beforeend", html);
      return;
    }
    wrap.insertAdjacentHTML("beforeend", html);
  }
  function closeTable(wrap, footHtml) {
    footHtml = footHtml || "";
    var m = footHtml.match(/([\\s\\S]*?<\\/table>)([\\s\\S]*)/i);
    if (m) {
      var footEl = document.getElementById((C.boxId || "prog") + "-foot");
      if (footEl) footEl.innerHTML = m[2] || "";
    } else {
      var footEl2 = document.getElementById((C.boxId || "prog") + "-foot");
      if (footEl2) footEl2.innerHTML = footHtml;
    }
    var dots = document.getElementById((C.boxId || "prog") + "-dots");
    if (dots && dots.parentNode) dots.parentNode.removeChild(dots);
  }
  function loadBatch() {
    var url = C.pollUrl
      + (C.pollUrl.indexOf("?") >= 0 ? "&" : "?")
      + "offset=" + offset + "&limit=" + batch;
    fetch(url, { credentials: "same-origin", cache: "no-store" })
      .then(function (r) { if (!r.ok) throw new Error("http"); return r.json(); })
      .then(function (d) {
        if (!d || !d.ok) throw new Error("bad");
        // Prefer a complete HTML fragment (full table) — no open-tag assembly.
        if (typeof d.html === "string" && d.html.length) {
          box.innerHTML = d.html;
          setBadge(d.count || 0);
          return;
        }
        if ((d.count || 0) === 0) {
          box.innerHTML = (d.preamble_html || "") + (d.rows_html || d.empty_html || "");
          setBadge(0);
          return;
        }
        if (!started) {
          started = true;
          // Parse head in isolation so the browser closes the table once; then move
          // nodes into wrap so we can append rows into the real <tbody>.
          var tmp = document.createElement("div");
          tmp.innerHTML = d.table_head_html || "";
          box.innerHTML = (d.preamble_html || "")
            + '<div id="' + (C.boxId || "prog") + '-wrap"></div>'
            + dotsHtml()
            + '<div id="' + (C.boxId || "prog") + '-foot"></div>';
          var wrap0 = document.getElementById((C.boxId || "prog") + "-wrap");
          while (tmp.firstChild) wrap0.appendChild(tmp.firstChild);
        }
        setBadge(d.count || 0);
        appendRows(document.getElementById((C.boxId || "prog") + "-wrap"), d.rows_html || "");
        if (d.done) {
          closeTable(document.getElementById((C.boxId || "prog") + "-wrap"), d.table_foot_html || "");
          return;
        }
        offset = d.next_offset || (offset + batch);
        window.setTimeout(loadBatch, 40);
      })
      .catch(function () {
        box.innerHTML = "<p class=\\"text-danger\\"><i>"
          + (C.failMsg || "Load failed") + "</i></p>";
      });
  }
  loadBatch();
})();
</script>
JS
}

1;
