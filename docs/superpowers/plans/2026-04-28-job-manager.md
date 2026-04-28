# Job Manager — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hintergrund-Jobs (install, update, setup_lgsm, …) in einer globalen Übersicht anzeigen, abbrechen und automatisch bereinigen — ACL-aware (Admins sehen alles, Operatoren nur ihre eigenen Jobs, Viewer gar keine).

**Architecture:** Approach A — Metadaten-Datei pro Job. Jedes `$config_directory/jobs/{job_id}/`-Verzeichnis bekommt eine `meta`-Datei (instance_id, action, started_at, unix_user). Worker-Scripts starten via `setsid` und schreiben ihre PGID statt PID. Abbruch via `kill(9, -$pgid)` tötet den kompletten Prozessbaum. Globale Übersicht in `jobs.cgi`, kompakte Per-Instanz-Liste am Ende von `manage.cgi`.

**Tech Stack:** Perl 5, Webmin Core (`ui_*`, `html_escape`), Bash-Worker-Scripts, TAP-Tests

---

## Datei-Übersicht

| Datei | Änderung |
|---|---|
| `src/lib/jobs.pl` | `write_job_meta`, `get_all_jobs`, `abort_job`, `delete_job`, `_auto_cleanup_jobs`, `_write_error_hint`; `create_job` ruft Cleanup auf |
| `src/jobs.cgi` | Neu — globale Job-Übersicht, abort/delete-Actions, view_output |
| `src/manage.cgi` | `setsid` in allen Worker-Starts; `write_job_meta` nach `create_job`; abort_job-Action; Abbrechen-Button in poll_job; per-Instanz-Job-Liste |
| `src/index.cgi` | Jobs-Button für Admins + Operatoren |
| `src/lang/de` | 19 neue Keys |
| `src/lang/en` | 19 neue Keys |
| `src/scripts/setup_lgsm.sh` | `pid` → `pgid` |
| `src/scripts/game_action.sh` | `pid` → `pgid` |
| `src/scripts/steamcmd_install.sh` | `pid` → `pgid`; schreibt `.steam_app_id` |
| `src/scripts/steamcmd_control.sh` | Neues Argument-Layout: `action job_dir unix_user server_dir`; liest `.steam_app_id` für update; schreibt pgid/output/status |
| `t/test_jobs.pl` | Erweitert auf 28 Tests |

---

## Task 1: Lang-Strings

**Files:**
- Modify: `src/lang/de`
- Modify: `src/lang/en`

- [ ] **Step 1: Keys in `src/lang/de` einfügen**

Nach der letzten Zeile der Datei anhängen:

```
jobs_title=Job-Übersicht
jobs_col_instance=Instanz
jobs_col_action=Aktion
jobs_col_started=Gestartet
jobs_col_status=Status
jobs_col_output=Ausgabe
jobs_col_actions=Aktionen
jobs_status_running=Läuft…
jobs_status_ok=Erfolgreich
jobs_status_failed=Fehlgeschlagen
jobs_status_aborted=Abgebrochen
jobs_abort_btn=Abbrechen
jobs_abort_confirm=Job wirklich abbrechen?
jobs_delete_btn=Löschen
jobs_output_title=Job-Ausgabe
jobs_no_jobs=Keine Jobs vorhanden.
jobs_action_install_game=Spiel installieren
jobs_action_setup_lgsm=LGSM einrichten
jobs_action_update=Update
jobs_action_validate=Dateien prüfen
jobs_action_reinstall=Neu installieren
jobs_action_start=Starten
jobs_action_stop=Stoppen
hint_zombie=Prozess unerwartet beendet — Worker-Prozess ist nicht mehr aktiv.
```

- [ ] **Step 2: Keys in `src/lang/en` einfügen**

Nach der letzten Zeile anhängen:

```
jobs_title=Job Overview
jobs_col_instance=Instance
jobs_col_action=Action
jobs_col_started=Started
jobs_col_status=Status
jobs_col_output=Output
jobs_col_actions=Actions
jobs_status_running=Running…
jobs_status_ok=Completed
jobs_status_failed=Failed
jobs_status_aborted=Aborted
jobs_abort_btn=Abort
jobs_abort_confirm=Really abort this job?
jobs_delete_btn=Delete
jobs_output_title=Job Output
jobs_no_jobs=No jobs found.
jobs_action_install_game=Install game
jobs_action_setup_lgsm=Set up LGSM
jobs_action_update=Update
jobs_action_validate=Validate files
jobs_action_reinstall=Reinstall
jobs_action_start=Start
jobs_action_stop=Stop
hint_zombie=Process ended unexpectedly — worker process is no longer active.
```

- [ ] **Step 3: Commit**

```bash
git add src/lang/de src/lang/en
git commit -m "feat: job-manager lang strings (de + en)

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 2: `jobs.pl` — Metadaten + Übersicht + Zombie-Erkennung

**Files:**
- Modify: `src/lib/jobs.pl`
- Modify: `t/test_jobs.pl`

Kontext: `src/lib/jobs.pl` hat aktuell 10 Tests und die Funktionen `create_job`, `get_job_status`, `get_job_output`, `get_job_error_hint`, `finish_job`, `cleanup_old_jobs`. Die Datei verwendet `our $config_directory` und interne Hilfsfunktionen `_jobs_dir()` / `_job_dir($id)`.

- [ ] **Step 1: Failing-Tests schreiben**

`t/test_jobs.pl` — Zeile `use Test::More tests => 10;` auf `tests => 28` ändern, dann am Ende der Datei anhängen:

```perl
# --- Task 2: write_job_meta + get_all_jobs + Zombie ---

# Test 11: write_job_meta erstellt meta-Datei
{
    my $jid = create_job();
    write_job_meta($jid, 'windrose_1', 'install_game', 'wuser');
    ok(-f "$tmp/jobs/$jid/meta", 'write_job_meta: meta file created');
}

# Test 12-15: meta-Inhalt korrekt
{
    my $jid = create_job();
    write_job_meta($jid, 'mc_srv', 'update', 'mcuser');
    my %m;
    open(my $f, '<', "$tmp/jobs/$jid/meta") or die $!;
    while (<$f>) { chomp; my ($k,$v)=split(/=/,$_,2); $m{$k}=$v if $k&&defined $v; }
    close $f;
    is($m{instance_id}, 'mc_srv',    'write_job_meta: instance_id correct');
    is($m{action},      'update',    'write_job_meta: action correct');
    is($m{unix_user},   'mcuser',    'write_job_meta: unix_user correct');
    like($m{started_at}, qr/^\d+$/, 'write_job_meta: started_at is numeric');
}

# Test 16: get_all_jobs findet Job mit meta
{
    my $jid = create_job();
    write_job_meta($jid, 'gs_srv', 'setup_lgsm', 'gsuser');
    finish_job($jid, 'ok');
    my @jobs = get_all_jobs();
    my ($found) = grep { $_->{job_id} eq $jid } @jobs;
    ok(defined $found, 'get_all_jobs: finds job with meta');
}

# Test 17: get_all_jobs: korrekte Felder
{
    my $jid = create_job();
    write_job_meta($jid, 'gs_srv', 'update', 'gsuser');
    finish_job($jid, 'failed');
    my @jobs = get_all_jobs();
    my ($j) = grep { $_->{job_id} eq $jid } @jobs;
    is($j->{status},      'failed', 'get_all_jobs: status correct');
    is($j->{instance_id}, 'gs_srv', 'get_all_jobs: instance_id correct');
}

# Test 19: Zombie-Erkennung — PGID nicht existent → status wird failed
{
    my $jid = create_job();
    write_job_meta($jid, 'test', 'install_game', 'u');
    # Schreibe eine PID die mit Sicherheit nicht läuft
    open(my $pf, '>', "$tmp/jobs/$jid/pgid") or die $!;
    print $pf "99999\n";
    close $pf;
    # Status ist noch 'running', aber Prozess existiert nicht
    my @jobs = get_all_jobs();
    my ($zj) = grep { $_->{job_id} eq $jid } @jobs;
    is($zj->{status}, 'failed', 'get_all_jobs: zombie detected and marked failed');
}
```

- [ ] **Step 2: Tests ausführen — müssen fehlschlagen**

```bash
perl t/test_jobs.pl 2>&1 | head -20
```

Erwartet: Tests 11–19 `not ok` (Funktionen nicht definiert).

- [ ] **Step 3: Neue Funktionen in `src/lib/jobs.pl` implementieren**

Vor der abschließenden `1;`-Zeile einfügen:

```perl
sub write_job_meta {
    my ($job_id, $instance_id, $action, $unix_user) = @_;
    my $job_dir = _job_dir($job_id);
    open(my $fh, '>', "$job_dir/meta") or return;
    print $fh "instance_id=$instance_id\n";
    print $fh "action=$action\n";
    print $fh "started_at=" . time() . "\n";
    print $fh "unix_user=$unix_user\n";
    close($fh);
}

sub _read_meta {
    my ($job_id) = @_;
    my $file = _job_dir($job_id) . "/meta";
    return () unless -f $file;
    my %m;
    open(my $fh, '<', $file) or return ();
    while (<$fh>) {
        chomp;
        next unless /=/;
        my ($k, $v) = split(/=/, $_, 2);
        $m{$k} = $v if defined $k && defined $v;
    }
    close($fh);
    return %m;
}

sub _write_error_hint {
    my ($job_id, $hint) = @_;
    my $file = _job_dir($job_id) . "/error_hint";
    open(my $fh, '>', $file) or return;
    print $fh "$hint\n";
    close($fh);
}

sub get_all_jobs {
    my $jobs_dir = _jobs_dir();
    return () unless -d $jobs_dir;
    my @jobs;
    opendir(my $dh, $jobs_dir) or return ();
    for my $jid (readdir($dh)) {
        next if $jid =~ /^\./;
        my $jdir = "$jobs_dir/$jid";
        next unless -d $jdir;

        my %meta   = _read_meta($jid);
        my $status = get_job_status($jid) // 'unknown';

        # Zombie-Erkennung: status=running aber Prozess tot
        if ($status eq 'running' && -f "$jdir/pgid") {
            open(my $pf, '<', "$jdir/pgid") or do { next };
            my $pgid = <$pf>; close($pf);
            chomp $pgid if defined $pgid;
            if (defined $pgid && $pgid =~ /^\d+$/) {
                my $alive = kill(0, -$pgid);
                unless ($alive) {
                    finish_job($jid, 'failed');
                    _write_error_hint($jid, 'hint_zombie');
                    $status = 'failed';
                }
            }
        }

        push @jobs, {
            job_id      => $jid,
            instance_id => $meta{instance_id} // '',
            action      => $meta{action}      // '',
            unix_user   => $meta{unix_user}   // '',
            started_at  => $meta{started_at}  // 0,
            status      => $status,
        };
    }
    closedir($dh);

    # Neueste zuerst
    return sort { ($b->{started_at} || 0) <=> ($a->{started_at} || 0) } @jobs;
}
```

- [ ] **Step 4: Tests ausführen — Tests 11–19 müssen grün sein**

```bash
perl t/test_jobs.pl 2>&1
```

Erwartet: Tests 1–19 `ok` (Tests 20–28 noch `not ok`).

---

## Task 3: `jobs.pl` — abort_job + delete_job + _auto_cleanup_jobs + create_job

**Files:**
- Modify: `src/lib/jobs.pl`
- Modify: `t/test_jobs.pl`

- [ ] **Step 1: Failing-Tests am Ende von `t/test_jobs.pl` anhängen**

```perl
# --- Task 3: abort_job + delete_job + _auto_cleanup ---

# Test 20: abort_job setzt status=aborted
{
    my $jid = create_job();
    write_job_meta($jid, 'test', 'install_game', 'u');
    open(my $pf, '>', "$tmp/jobs/$jid/pgid") or die $!;
    print $pf "99999\n";   # nicht existent, kill schlägt lautlos fehl
    close $pf;
    abort_job($jid);
    is(get_job_status($jid), 'aborted', 'abort_job: sets status=aborted');
}

# Test 21: delete_job entfernt Job-Dir
{
    my $jid = create_job();
    write_job_meta($jid, 'test', 'update', 'u');
    finish_job($jid, 'ok');
    delete_job($jid);
    ok(!-d "$tmp/jobs/$jid", 'delete_job: removes job directory');
}

# Test 22: delete_job verweigert laufenden Job (gibt 0 zurück)
{
    my $jid = create_job();
    write_job_meta($jid, 'test', 'update', 'u');
    my $result = delete_job($jid);   # status=running
    is($result, 0, 'delete_job: refuses running job');
}

# Test 23: Job-Dir bleibt erhalten nach verweigertem delete
{
    my $jid = create_job();
    write_job_meta($jid, 'test', 'update', 'u');
    delete_job($jid);
    ok(-d "$tmp/jobs/$jid", 'delete_job: running job dir still exists');
}

# Test 24-25: _auto_cleanup_jobs behält max 10 abgeschlossene Jobs
{
    # Lösche alle bestehenden Jobs zuerst (sauberer Zustand)
    opendir(my $dh, "$tmp/jobs") or die $!;
    for my $jid (readdir($dh)) {
        next if $jid =~ /^\./;
        my $jdir = "$tmp/jobs/$jid";
        unlink "$jdir/$_" for qw(meta pgid status output error_hint pid);
        rmdir $jdir;
    }
    closedir $dh;

    # Erstelle 11 abgeschlossene Jobs (kein create_job, direkt anlegen)
    for my $i (1..11) {
        my $jid = sprintf('deadbeef%08d', $i);
        mkdir "$tmp/jobs/$jid", 0700 or next;
        open(my $sf, '>', "$tmp/jobs/$jid/status") or next;
        print $sf "ok\n"; close $sf;
        open(my $mf, '>', "$tmp/jobs/$jid/meta") or next;
        print $mf "instance_id=t\naction=update\nstarted_at=$i\nunix_user=u\n";
        close $mf;
    }
    # create_job löst _auto_cleanup_jobs aus
    my $new_jid = create_job();
    finish_job($new_jid, 'ok');

    my @done = grep { $_->{status} ne 'running' } get_all_jobs();
    ok(scalar(@done) <= 10, '_auto_cleanup_jobs: keeps max 10 completed jobs');
    ok(scalar(@done) >= 1,  '_auto_cleanup_jobs: keeps at least the newest job');
}
```

- [ ] **Step 2: Tests ausführen — Tests 20–25 müssen fehlschlagen**

```bash
perl t/test_jobs.pl 2>&1 | grep -E "^(ok|not ok) (2[0-5])"
```

Erwartet: `not ok 20` bis `not ok 25`.

- [ ] **Step 3: abort_job + delete_job + _auto_cleanup_jobs in `src/lib/jobs.pl` implementieren**

Vor der abschließenden `1;`-Zeile einfügen:

```perl
sub abort_job {
    my ($job_id) = @_;
    my $jdir = _job_dir($job_id);
    if (-f "$jdir/pgid") {
        open(my $fh, '<', "$jdir/pgid") or do { finish_job($job_id, 'aborted'); return; };
        my $pgid = <$fh>; close($fh);
        chomp $pgid if defined $pgid;
        if (defined $pgid && $pgid =~ /^\d+$/) {
            kill(9, -$pgid);   # SIGKILL gesamte Process Group
        }
    }
    finish_job($job_id, 'aborted');
}

sub delete_job {
    my ($job_id) = @_;
    my $jdir = _job_dir($job_id);
    return 0 unless -d $jdir;
    my $status = get_job_status($job_id) // '';
    return 0 if $status eq 'running';
    unlink "$jdir/$_" for qw(meta pgid status output error_hint pid);
    rmdir $jdir;
    return 1;
}

sub _auto_cleanup_jobs {
    my $jobs_dir = _jobs_dir();
    return unless -d $jobs_dir;
    my @done;
    opendir(my $dh, $jobs_dir) or return;
    for my $jid (readdir($dh)) {
        next if $jid =~ /^\./;
        my $jdir = "$jobs_dir/$jid";
        next unless -d $jdir;
        my $status = get_job_status($jid) // '';
        next if $status eq 'running' || $status eq '';
        my %meta = _read_meta($jid);
        my $ts   = $meta{started_at} // (stat($jdir))[9] // 0;
        push @done, { job_id => $jid, started_at => $ts };
    }
    closedir($dh);
    return if @done <= 10;

    # Älteste zuerst, löschen bis 10 übrig
    @done = sort { ($a->{started_at} || 0) <=> ($b->{started_at} || 0) } @done;
    my $excess = @done - 10;
    for my $j (@done[0 .. $excess - 1]) {
        my $jdir = "$jobs_dir/" . $j->{job_id};
        unlink "$jdir/$_" for qw(meta pgid status output error_hint pid);
        rmdir $jdir;
    }
}
```

- [ ] **Step 4: `create_job` um `_auto_cleanup_jobs()`-Aufruf erweitern**

In `src/lib/jobs.pl` die `create_job`-Funktion so ändern, dass nach dem `close($fh)` ein `_auto_cleanup_jobs();` folgt:

```perl
sub create_job {
    my $raw;
    open(my $f, '<', '/dev/urandom') or die "Cannot read /dev/urandom\n";
    read($f, $raw, 8);
    close($f);
    my $job_id = lc(unpack('H*', $raw));

    my $jobs_dir = _jobs_dir();
    mkdir($jobs_dir, 0700) unless -d $jobs_dir;
    my $job_dir = _job_dir($job_id);
    mkdir($job_dir, 0700) or die "Cannot create job dir: $!\n";

    open(my $fh, '>', "$job_dir/status") or die "Cannot write status: $!\n";
    print $fh "running\n";
    close($fh);

    _auto_cleanup_jobs();

    return $job_id;
}
```

- [ ] **Step 5: Alle 28 Tests grün**

```bash
perl t/test_jobs.pl 2>&1
```

Erwartet: `1..28`, alle `ok`.

- [ ] **Step 6: Syntax-Check**

```bash
perl -c src/lib/jobs.pl
```

Erwartet: `syntax OK`

- [ ] **Step 7: Commit**

```bash
git add src/lib/jobs.pl t/test_jobs.pl
git commit -m "feat: jobs.pl — write_job_meta, get_all_jobs, abort_job, delete_job, auto-cleanup

Zombie-Erkennung in get_all_jobs via kill(0,-pgid).
Auto-Cleanup: maximal 10 abgeschlossene Jobs, älteste fliegen raus.

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 4: Worker-Scripts — pid→pgid + steamcmd_control.sh-Fix

**Files:**
- Modify: `src/scripts/setup_lgsm.sh`
- Modify: `src/scripts/game_action.sh`
- Modify: `src/scripts/steamcmd_install.sh`
- Modify: `src/scripts/steamcmd_control.sh`

Kontext: Alle Worker-Scripts haben aktuell `echo $$ > "$JOB_DIR/pid"`. Das muss zu `echo $$ > "$JOB_DIR/pgid"` werden. `steamcmd_control.sh` hat zusätzlich ein falsches Argument-Layout (erwartet `action server_dir unix_user app_id`, aber `manage.cgi` übergibt `action job_dir unix_user server_dir`). Das wird hier korrigiert. `steamcmd_install.sh` schreibt außerdem die App-ID für späteres Verwenden durch `steamcmd_control.sh`.

- [ ] **Step 1: `setup_lgsm.sh` — pid → pgid**

Zeile `echo $$ > "$JOB_DIR/pid"` ersetzen durch:

```bash
echo $$ > "$JOB_DIR/pgid"
```

- [ ] **Step 2: `game_action.sh` — pid → pgid**

Zeile `echo $$ > "$JOB_DIR/pid"` ersetzen durch:

```bash
echo $$ > "$JOB_DIR/pgid"
```

- [ ] **Step 3: `steamcmd_install.sh` — pid → pgid + .steam_app_id schreiben**

Zeile `echo $$ > "$JOB_DIR/pid"` ersetzen durch:

```bash
echo $$ > "$JOB_DIR/pgid"
```

Direkt vor der letzten Zeile `echo "ok" > "$JOB_DIR/status"` einfügen:

```bash
echo "$STEAM_APP_ID" > "$SERVER_DIR/.steam_app_id"
```

- [ ] **Step 4: `steamcmd_control.sh` komplett ersetzen**

Das gesamte Script ersetzen — neues Argument-Layout: `action job_dir unix_user server_dir`. PGID, Output und Status werden in JOB_DIR geschrieben. STEAM_APP_ID für update kommt aus `$SERVER_DIR/.steam_app_id`.

```bash
#!/bin/bash
# steamcmd_control.sh — start/stop/update for non-LGSM games
# Usage: steamcmd_control.sh <action> <job_dir> <unix_user> <server_dir>
set -euo pipefail

ACTION="$1"
JOB_DIR="$2"
UNIX_USER="$3"
SERVER_DIR="$4"

echo $$ > "$JOB_DIR/pgid"
exec >> "$JOB_DIR/output" 2>&1

SERVERFILES="$SERVER_DIR/serverfiles"
PIDFILE="$SERVER_DIR/run.pid"
LOGFILE="$SERVER_DIR/server.log"

_find_binary() {
    find "$SERVERFILES" -maxdepth 3 -type f \( -name "*.x86_64" -o -name "*Server.sh" \) \
        -perm /0111 2>/dev/null | head -1
}

case "$ACTION" in
    start)
        BINARY=$(_find_binary)
        if [ -z "$BINARY" ]; then
            echo "ERROR: No server binary found in $SERVERFILES" >&2
            echo "failed" > "$JOB_DIR/status"
            exit 1
        fi
        # shellcheck disable=SC2086
        su -s /bin/bash -c "
            cd '$SERVER_DIR' &&
            nohup '$BINARY' >> '$LOGFILE' 2>&1 &
            echo \$! > '$PIDFILE'
        " "$UNIX_USER"
        echo "Server started (PID $(cat "$PIDFILE" 2>/dev/null || echo unknown))"
        echo "ok" > "$JOB_DIR/status"
        ;;

    stop)
        if [ -f "$PIDFILE" ]; then
            PID=$(cat "$PIDFILE")
            kill "$PID" 2>/dev/null && echo "Server stopped (PID $PID)" || echo "Process not running"
            rm -f "$PIDFILE"
        else
            echo "No PID file — server may not be running"
        fi
        echo "ok" > "$JOB_DIR/status"
        ;;

    update)
        APP_ID_FILE="$SERVER_DIR/.steam_app_id"
        if [ ! -f "$APP_ID_FILE" ]; then
            echo "ERROR: .steam_app_id not found in $SERVER_DIR" >&2
            echo "failed" > "$JOB_DIR/status"
            exit 1
        fi
        STEAM_APP_ID=$(cat "$APP_ID_FILE")
        echo "=== Updating App ID $STEAM_APP_ID via SteamCMD ==="
        if ! su -s /bin/bash -c "
            steamcmd +force_install_dir '$SERVERFILES' \
                     +login anonymous \
                     +app_update '$STEAM_APP_ID' validate \
                     +quit
        " "$UNIX_USER"; then
            echo "hint_steamcmd_login" > "$JOB_DIR/error_hint"
            echo "failed" > "$JOB_DIR/status"
            exit 1
        fi
        echo "=== Update complete ==="
        echo "ok" > "$JOB_DIR/status"
        ;;

    *)
        echo "Unknown action: $ACTION" >&2
        echo "failed" > "$JOB_DIR/status"
        exit 1
        ;;
esac
```

- [ ] **Step 5: Commit**

```bash
git add src/scripts/setup_lgsm.sh src/scripts/game_action.sh \
        src/scripts/steamcmd_install.sh src/scripts/steamcmd_control.sh
git commit -m "fix: worker-scripts pid→pgid; steamcmd_control.sh JOB_DIR-Argument

Alle Worker schreiben PGID statt PID → kill -9 -PGID tötet kompletten Baum.
steamcmd_control.sh: neues Argument-Layout action/job_dir/unix_user/server_dir
(war falsch: server_dir/unix_user/app_id). STEAM_APP_ID aus .steam_app_id-Datei.

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 5: `manage.cgi` — setsid + write_job_meta + abort + per-Instanz-Liste

**Files:**
- Modify: `src/manage.cgi`

Kontext: `manage.cgi` startet Worker mit `nohup bash ...`. Das muss zu `setsid nohup bash ...` werden, damit der Worker eine eigene Process Group bekommt. Nach jedem `create_job()` muss `write_job_meta(...)` aufgerufen werden. Dazu kommen: eine neue `abort_job`-Action, ein "Abbrechen"-Button in `poll_job`, und eine per-Instanz-Job-Liste vor dem Footer.

- [ ] **Step 1: `require './lib/jobs.pl'` ist bereits vorhanden — prüfen**

```bash
grep -n "require.*jobs" src/manage.cgi
```

Erwartet: eine Zeile mit `require './lib/jobs.pl';`. Falls nicht vorhanden, nach den anderen `require`-Zeilen (Zeilen ~17-26) einfügen:

```perl
require './lib/jobs.pl';
```

- [ ] **Step 2: Alle `nohup bash` durch `setsid nohup bash` ersetzen**

In `src/manage.cgi` alle Vorkommen von `"nohup bash "` ersetzen durch `"setsid nohup bash "`. Es gibt 5 Stellen (setup_lgsm, install_game lgsm-Pfad, update lgsm-Pfad, validate, reinstall). Für die steamcmd-Pfade (`"nohup bash "` gefolgt von quotemeta): gleiche Ersetzung.

Einfachste Prüfung vorher:
```bash
grep -n '"nohup bash' src/manage.cgi
```

Dann alle ersetzen (jede Zeile einzeln mit Edit-Tool).

- [ ] **Step 3: `write_job_meta` nach jedem `create_job()` einfügen**

Es gibt 5 Stellen mit `my $job_id = &create_job();`. Nach jeder dieser Zeilen die folgende Zeile einfügen (Aktion-String anpassen):

Für `setup_lgsm`:
```perl
my $job_id = &create_job();
write_job_meta($job_id, $instance_id, 'setup_lgsm', $unix_user);
```

Für `install_game`:
```perl
my $job_id = &create_job();
write_job_meta($job_id, $instance_id, 'install_game', $unix_user);
```

Für `update`:
```perl
my $job_id = &create_job();
write_job_meta($job_id, $instance_id, 'update', $unix_user);
```

Für `validate`:
```perl
my $job_id = &create_job();
write_job_meta($job_id, $instance_id, 'validate', $unix_user);
```

Für `reinstall`:
```perl
my $job_id = &create_job();
write_job_meta($job_id, $instance_id, 'reinstall', $unix_user);
```

Für `start`/`stop` (steamcmd-Pfad):
```perl
my $job_id = &create_job();
write_job_meta($job_id, $instance_id, $action, $unix_user);
```

- [ ] **Step 4: `abort_job`-Action in den POST-Dispatch einfügen**

Im `if ($in{'action'} && ...)` Block, nach dem `elsif ($action eq 'reinstall')` Block, vor dem `elsif ($action eq 'init_game_config')` Block einfügen:

```perl
    elsif ($action eq 'abort_job') {
        my $job_id = $in{'job'} // '';
        $job_id =~ s/[^0-9a-f]//g;
        $job_id or &error($text{'err_invalid_input'});
        abort_job($job_id);
        &redirect("manage.cgi?instance_id=" . &html_escape($instance_id));
        exit;
    }
```

- [ ] **Step 5: "Abbrechen"-Button in `poll_job` einfügen**

Im `poll_job`-Block, in der `if ($status eq 'running')` Sektion, nach der `<meta http-equiv="refresh">`-Zeile und dem `<p>Läuft…</p>` einfügen:

```perl
    if ($status eq 'running') {
        my $poll_url = "manage.cgi?instance_id=" . &html_escape($instance_id)
            . "&action=poll_job&job=" . &html_escape($job_id)
            . "&next_status=" . &html_escape($next_status);
        print "<meta http-equiv=\"refresh\" content=\"3;url=$poll_url\">\n";
        print "<p>" . &html_escape($text{'job_running'}) . "</p>\n";
        print &ui_form_start('manage.cgi', 'post', undef,
            "onsubmit=\"return confirm('" . &html_escape($text{'jobs_abort_confirm'} || 'Abbrechen?') . "')\"");
        print &ui_hidden('instance_id', &html_escape($instance_id));
        print &ui_hidden('action', 'abort_job');
        print &ui_hidden('job', &html_escape($job_id));
        print &ui_submit($text{'jobs_abort_btn'} || 'Abbrechen', undef, undef, undef, 'btn-danger');
        print &ui_form_end();
    }
```

- [ ] **Step 6: Per-Instanz-Job-Liste vor `&footer()` einfügen**

Direkt vor der letzten Zeile `&footer('index.cgi', $text{'index_title'});` einfügen:

```perl
# Per-instance job list (operators and admins only)
unless (&user_is_readonly($instance_id)) {
    my @inst_jobs = grep { ($_->{instance_id} // '') eq $instance_id }
                    get_all_jobs();
    @inst_jobs = @inst_jobs[0..4] if @inst_jobs > 5;

    if (@inst_jobs) {
        print "<h3>" . &html_escape($text{'jobs_title'} || 'Jobs') . "</h3>\n";
        my %status_icons = (
            running => '&#x23F3;',
            ok      => '&#x2705;',
            failed  => '&#x1F534;',
            aborted => '&#x1F6AB;',
        );
        my @rows;
        for my $job (@inst_jobs) {
            my $jid    = $job->{job_id};
            my $status = $job->{status};
            my $ts     = $job->{started_at} || 0;
            my @lt     = localtime($ts);
            my $ts_str = $ts ? sprintf('%02d:%02d', $lt[2], $lt[1]) : '—';
            my $st_icon = $status_icons{$status} // '';
            my $out_cell = '—';
            if ($status eq 'running') {
                $out_cell = "<a href='manage.cgi?instance_id=" . &html_escape($instance_id)
                    . "&amp;action=poll_job&amp;job=" . &html_escape($jid) . "'>Live</a>";
            } elsif ($status eq 'failed' || $status eq 'aborted') {
                $out_cell = "<a href='jobs.cgi?action=view_output&amp;job_id="
                    . &html_escape($jid) . "'>Log</a>";
            }
            push @rows, [
                &html_escape($job->{action} || '—'),
                $ts_str,
                "$st_icon " . &html_escape($status),
                $out_cell,
            ];
        }
        print &ui_columns_table(
            [
                $text{'jobs_col_action'}  || 'Aktion',
                $text{'jobs_col_started'} || 'Gestartet',
                $text{'jobs_col_status'}  || 'Status',
                $text{'jobs_col_output'}  || 'Ausgabe',
            ],
            "100%",
            \@rows,
        );
    }
}
```

- [ ] **Step 7: Syntax-Check**

```bash
perl -c src/manage.cgi
```

Erwartet: `syntax OK`

- [ ] **Step 8: Commit**

```bash
git add src/manage.cgi
git commit -m "feat: manage.cgi — setsid, write_job_meta, abort_job, per-Instanz-Job-Liste

Worker-Starts via setsid. Nach create_job() sofort write_job_meta().
abort_job-Action + Abbrechen-Button in poll_job.
Per-Instanz-Job-Liste (letzte 5) am Ende der Manage-Seite.

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 6: `jobs.cgi` — globale Job-Übersicht

**Files:**
- Create: `src/jobs.cgi`

- [ ] **Step 1: `src/jobs.cgi` erstellen**

```perl
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

    abort_job($job_id);
    &redirect('jobs.cgi');
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

    delete_job($job_id)
        or &error($text{'err_invalid_action'} || 'Cannot delete running job');
    &redirect('jobs.cgi');
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

    my ($out, undef) = get_job_output($job_id, 0);
    &header($text{'jobs_output_title'} || 'Job Output', '');
    print "<h3>" . &html_escape($text{'jobs_output_title'} || 'Job Output') . "</h3>\n";
    print "<p><a href='jobs.cgi'>&larr; "
        . &html_escape($text{'jobs_title'} || 'Jobs') . "</a></p>\n";
    if (defined $out && $out ne '') {
        print "<pre style='background:#111;color:#eee;padding:8px;overflow:auto;max-height:600px'>"
            . &html_escape($out) . "</pre>\n";
    } else {
        print "<p><i>" . &html_escape('Keine Ausgabe vorhanden.') . "</i></p>\n";
    }
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

my %action_labels = (
    install_game => $text{'jobs_action_install_game'} || 'Spiel installieren',
    setup_lgsm   => $text{'jobs_action_setup_lgsm'}   || 'LGSM einrichten',
    update       => $text{'jobs_action_update'}        || 'Update',
    validate     => $text{'jobs_action_validate'}      || 'Dateien prüfen',
    reinstall    => $text{'jobs_action_reinstall'}     || 'Neu installieren',
    start        => $text{'jobs_action_start'}         || 'Starten',
    stop         => $text{'jobs_action_stop'}          || 'Stoppen',
);

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
            $out_cell = "<a href='manage.cgi?instance_id="
                . &html_escape($job->{instance_id} // '')
                . "&amp;action=poll_job&amp;job=" . &html_escape($jid) . "'>Live</a>";
        } elsif ($status eq 'failed' || $status eq 'aborted') {
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
```

- [ ] **Step 2: Syntax-Check**

```bash
perl -c src/jobs.cgi
```

Erwartet: `src/jobs.cgi syntax OK`

- [ ] **Step 3: Commit**

```bash
git add src/jobs.cgi
git commit -m "feat: jobs.cgi — globale Job-Übersicht mit abort, delete, view_output

ACL: Viewer kein Zugriff, Operator sieht nur eigene Instanzen, Admin alles.

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 7: `index.cgi` — Jobs-Button

**Files:**
- Modify: `src/index.cgi`

- [ ] **Step 1: Jobs-Button nach dem `can_scan()`-Block einfügen**

In `src/index.cgi` nach dem `if (&can_scan())` Block (nach Zeile mit `print &ui_form_end();` für `steam_settings.cgi`) und vor dem `if (&is_admin())` Block einfügen:

```perl
if (&effective_role() ne 'viewer') {
    print &ui_form_start('jobs.cgi', 'get');
    print &ui_submit($text{'jobs_title'} || 'Job-Übersicht', undef, undef, undef, 'btn-default');
    print &ui_form_end();
}
```

- [ ] **Step 2: Syntax-Check**

```bash
perl -c src/index.cgi
```

Erwartet: `src/index.cgi syntax OK`

- [ ] **Step 3: Commit**

```bash
git add src/index.cgi
git commit -m "feat: index.cgi — Job-Übersicht-Button für Admins und Operatoren

Co-authored-by: Claude <claude-code@anthropic.com>"
```

---

## Task 8: Verifikation + Build

**Files:** keine Änderungen

- [ ] **Step 1: Alle Tests grün**

```bash
perl t/test_jobs.pl
```

Erwartet: `1..28`, alle `ok`.

- [ ] **Step 2: verify.sh**

```bash
bash scripts/verify.sh
```

Erwartet: `[verify] completed` ohne Fehler.

- [ ] **Step 3: Perl-Syntax aller neuen/geänderten Dateien**

```bash
perl -c src/jobs.cgi && \
perl -c src/manage.cgi && \
perl -c src/index.cgi && \
perl -c src/lib/jobs.pl
```

Erwartet: alle `syntax OK`.

- [ ] **Step 4: Build**

```bash
bash scripts/build.sh
```

Erwartet: `==> Built: dist/linuxgsm-webcore-0.1.0.wbm`

- [ ] **Step 5: Deploy**

```bash
scp dist/linuxgsm-webcore-0.1.0.wbm root@SERVER:/tmp/
# Auf Server:
# /usr/share/webmin/install-module.pl /tmp/linuxgsm-webcore-0.1.0.wbm
```

- [ ] **Step 6: End-to-End Verifikation auf Server**

1. Browser → `index.cgi` → Button "Job-Übersicht" sichtbar (als Admin und Operator, nicht als Viewer)
2. "Game-Server installieren" klicken → `poll_job`-Seite zeigt "Abbrechen"-Button
3. "Abbrechen" klicken → Job-Status wird `aborted`
4. `jobs.cgi` → Job erscheint mit Status 🚫 Abgebrochen, "Log"-Link
5. "Log"-Link → Job-Output sichtbar
6. "Löschen"-Button → Job verschwindet aus Liste
7. 11 Jobs anlegen → Auto-Cleanup hält maximal 10 abgeschlossene

---

## Self-Review Ergebnisse

**Spec-Coverage:** ✅ Alle Anforderungen abgedeckt — Metadaten-Datei, PGID, Zombie-Erkennung, global + per-Instanz, ACL, abort, delete, Auto-Cleanup (10), lang-Strings.

**Placeholder-Scan:** Keine TBD, keine vagen Formulierungen.

**Typ-Konsistenz:** `write_job_meta($job_id, $instance_id, $action, $unix_user)` — 4 Parameter, konsistent in allen Aufrufen. `abort_job($job_id)`, `delete_job($job_id)` — 1 Parameter, konsistent. `get_all_jobs()` gibt Liste von Hashrefs zurück mit Feldern: `job_id`, `instance_id`, `action`, `unix_user`, `started_at`, `status` — konsistent in jobs.cgi und manage.cgi verwendet.
