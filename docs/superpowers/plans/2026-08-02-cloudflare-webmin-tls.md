# Cloudflare + Webmin TLS — Neuaufbau & Checkliste

> **Status: erledigt 2026-08-02** — Proxy orange + Origin Rule 52000 + Full Strict + Origin CA (bis 2038) bestätigt; Domain und Instanzseite ok. Kein Cert-Neubau nötig. Incident 31.07./01.08. eher CF-Pfad und/oder Webmin-Last/Reboot, nicht abgelaufenes Cert.
>
> **Ops-Plan (kein Modul-Code).** Checkboxen (`- [ ]`) zum Abhaken.

**Goal:** `https://server.knoellix.net/` (ohne Port) läuft stabil über Cloudflare-Proxy **oder** bewusst ohne Proxy mit gültigem Zertifikat — ohne intermittierende 522.

**Architecture:** Zwei TLS-Strecken — Browser↔Cloudflare (CF-Zertifikat) und Cloudflare↔Origin (Webmin auf `:52000`). Origin Rule mappt Edge-Port 443 → Origin-Port 52000. Optional: Let’s Encrypt am Origin für Full (Strict).

**Ist-Stand (2026-08-01):**
- Webmin: HTTPS auf `0.0.0.0:52000` + `[::]:52000` (MiniServ, Self-Signed)
- HTTP→HTTPS Redirect auf Origin
- UFW: `52000/tcp` ALLOW
- Domain zeitweise 522; Direkt-IP stabil und schnell
- SSL-Modus laut User schon **Full** gewesen; Setup vor längerem „gerade so“ hingebogen
- Authentic Theme + LinuxGSM-WebCore Instanzseiten brauchen Sekunden (normal) — das allein erklärt keinen 522

**Tech Stack:** Cloudflare DNS/Proxy/Origin Rules, Webmin MiniServ SSL, optional certbot/LE

## Global Constraints

- Palworld (`gs_pw_keks`) während Cert/DNS-Arbeit **nicht** unnötig stoppen
- Browser-URL mit Proxy immer **ohne** `:52000`
- Kein Flexible-SSL (Origin spricht HTTPS)
- Modul-Code nur anfassen, wenn nach stabilem TLS noch echte Timeouts auf Origin messbar sind

---

## Zielbild (entscheiden am Anfang)

Zwei gültige Endzustände — **einen** wählen:

| Option | Proxy | Origin-Zertifikat | SSL-Modus | Wann |
|--------|-------|-------------------|-----------|------|
| **A — Proxy an** | orange | Self-Signed ok, besser LE | **Full** (später Strict mit LE) | DDoS/CF-WAF für Webmin gewünscht |
| **B — Direkt** | grau | LE für `server.knoellix.net` empfohlen | n/a (kein CF-TLS) | Stabilität vor Proxy (empfohlen falls 522 bleibt) |

Empfehlung Start: **A sauber neu aufsetzen**; wenn nach Checks weiter 522 → **B** als Fallback.

---

## Task 1: Baseline messen (vor jeder Änderung)

**Deliverable:** Ist-Zustand dokumentiert (Screenshot/Notizen).

**Baseline 2026-08-02 ~07:50 (von außen gemessen):**
- [x] DNS A = `5.180.253.176` → Proxy derzeit **grau (DNS only)**; kein AAAA
- [x] `https://server.knoellix.net/` (Port 443) → **Timeout** (nichts lauscht auf 443 am Origin)
- [x] `https://server.knoellix.net:52000/` → MiniServ **200** (ohne CF)
- [x] `https://5.180.253.176:52000/` → stabil **200**
- [x] Origin-Cert: **Cloudflare Origin CA**, gültig bis **2038-12-07** (Issuer `CloudFlare Origin SSL Certificate Authority`) — Cert selbst ist nicht abgelaufen

Dashboard (User, 2026-08-02):
- [x] SSL/TLS: **Full (Strict)** — ok mit Origin CA
- [x] Origin Rule: `server.knoellix.net` → Port **52000**, aktiv
- [x] Under Attack: aus
- [x] Proxy war grau → Domain:443 Timeout; nach **orange** lädt sauber (07:57)
- [x] Stabilität: 10× curl Domain = 200 (~0,3s); Instanzseite Palworld manage im Browser **superschnell** (07:59)
- [x] Fazit Incident: wahrscheinliche Kombi aus (a) Proxy zeitweise grau / Aufruf ohne Port→443, und/oder (b) temporäres CF-Routing/Origin-Last — Origin-Cert (CF Origin CA bis 2038) und Full Strict waren ok, kein Cert-Neubau nötig

---

## Task 2: Origin TLS verstehen / bereinigen

**Deliverable:** Klar welches Origin-Cert läuft (Self-Signed / Cloudflare Origin CA / LE); Redirect-Verhalten bekannt.

**Hinweis:** User erinnert sich an ein **Cloudflare Origin CA**-Zertifikat am Server (älteres Setup). Das ist nur für CF→Origin gültig (Browser direkt zur IP zeigt dann Warnung — erwartet). Morgen zuerst Issuer prüfen, nicht blind neu ausstellen.

- [ ] Webmin → Webmin Configuration → SSL: Pfade zu `key.pem` / `cert.pem` (oder aktuell genutzte Dateien) notieren
- [ ] Issuer + Gültigkeit auf dem Server:
  ```bash
  # Pfade aus Webmin-SSL-Config einsetzen, typisch unter /etc/webmin/
  openssl x509 -in /etc/webmin/miniserv.pem -noout -issuer -subject -dates 2>/dev/null
  # oder getrennt:
  openssl x509 -in /etc/webmin/cert.pem -noout -issuer -subject -dates 2>/dev/null
  echo | openssl s_client -connect 127.0.0.1:52000 -servername server.knoellix.net 2>/dev/null \
    | openssl x509 -noout -issuer -subject -dates
  ```
- [ ] Issuer einordnen:
  | Issuer enthält | Bedeutung | SSL-Modus |
  |----------------|-----------|-----------|
  | `CloudFlare Origin` / `Cloudflare` | Origin CA (nur CF→Origin) | **Full** (Strict nur mit CF Origin CA + CF als Client — Full reicht) |
  | `Let's Encrypt` | öffentliches LE | Full oder **Full (Strict)** |
  | Self-signed / MiniServ / Host | Self-Signed | nur **Full**, nicht Strict |
  | abgelaufen (`notAfter` in Vergangenheit) | **neu ausstellen** | — |
- [ ] Cloudflare Dashboard → SSL/TLS → **Origin Server**: ob dort noch ein Origin CA Cert existiert / abgelaufen; bei Bedarf neues Origin CA Cert erzeugen und in Webmin ersetzen
- [ ] Test lokal:
  ```bash
  curl -k -sI --max-time 5 https://127.0.0.1:52000/ | head -10
  curl -sI --max-time 5 http://127.0.0.1:52000/ | head -10
  ```
- [ ] Erwartung: HTTPS 200/Login; HTTP 302 → `https://…` **ohne** `:52000` in Location
- [ ] Entscheidung dokumentieren: Origin CA behalten/erneuern **oder** auf LE umstellen (Option B / Strict)

---

## Task 3: Cloudflare TLS + Origin Rule neu setzen (Option A)

**Deliverable:** Bekannte gute Konfiguration, dokumentiert.

- [ ] SSL/TLS → **Full** (nicht Flexible; Strict erst nach gültigem Origin-Cert)
- [ ] Edge Certificates: Universal SSL aktiv
- [ ] Origin Rule (neu oder ersetzen):
  - When: Hostname equals `server.knoellix.net`
  - Then: Destination Port = `52000`
- [ ] DNS `server` A → `5.180.253.176`, Proxy **orange**
- [ ] **AAAA löschen oder aus**, solange IPv6-Pfad nicht verifiziert
- [ ] Bot Fight / Under Attack für Test **aus**
- [ ] HTTP/2 to Origin **aus** (Test; bei Stabilität optional wieder an)
- [ ] Cache: Bypass für `server.knoellix.net/*` (Admin-UI nicht cachen)
- [ ] Rocket Loader / Auto Minify für diesen Host **aus**

---

## Task 4: Webmin „öffentliche URL“ ohne Port

**Deliverable:** Keine Redirects mehr auf `:52000` über die Domain.

- [ ] In Webmin die externe URL / Redirect-Basis auf `https://server.knoellix.net` (ohne Port)
- [ ] Authentic Theme: kein Hardcode auf `:52000`
- [ ] Verify:
  ```bash
  curl -sI --max-time 15 http://server.knoellix.net/ | grep -i location
  # Location soll https://server.knoellix.net/ sein — OHNE :52000
  ```

---

## Task 5: Stabilitäts-Test (Proxy an)

**Deliverable:** Pass/Fail-Protokoll.

Mindestens 10× hintereinander:

```bash
for i in $(seq 1 10); do
  echo -n "$i "; curl -sI --max-time 20 https://server.knoellix.net/ | head -1
  sleep 1
done
```

- [ ] Alle Requests HTTP/2 200 (oder 401/Login), **kein** Timeout
- [ ] Browser: Login → Dashboard → **eine Instanzseite** (`manage.cgi`) laden
- [ ] Sysinfo/`xhr.cgi` 2–3 Min offen: intermittierende Banner-Fehler?
- [ ] Parallel Direkt-IP weiter ok? (Regression)

**Fail-Kriterien:** ≥1 Timeout/522 in 10 curl-Versuchen oder wiederkehrende xhr-522 → Task 6.

---

## Task 6: Fallback Option B (DNS only) — wenn A nicht stabil

**Deliverable:** Stabiler Domain-Zugang ohne CF-Proxy.

- [ ] DNS `server` → Proxy **grau**
- [ ] LE-Zertifikat für Hostname (sonst Browser-Warnung)
- [ ] Webmin SSL = LE-Cert
- [ ] Port in URL: entweder
  - weiterhin `https://server.knoellix.net:52000/`, oder
  - lokaler Reverse-Proxy (nginx/caddy) auf 443 → 52000 **auf dem Server** (dann Domain ohne Port, ohne CF)
- [ ] Verify: `dig` zeigt Origin-IP; `curl -sI` ohne `cf-ray`; Navigation stabil

---

## Task 7: Firewall / Pfad nur wenn nötig

Nur wenn Task 5 scheitert und dig/curl klar CF→Origin betrifft:

- [ ] Cloudflare IP-Ranges in UFW erlauben (nicht „Anywhere entfernen“, sondern CF explizit ok — ist schon Anywhere ALLOW für 52000)
- [ ] fail2ban `webmin-auth`: `ignoreip` um CF-Ranges (auch bei 0 Bans dokumentieren)
- [ ] `ss -tnlp | grep 52000` + Verbindungstests von einem zweiten Netz

---

## Task 8: Modul / Authentic (nur nach stabilem TLS)

Nur wenn Domain mit gutem TLS noch spürbar hängt **und** Origin-`time curl` zur gleichen Zeit hoch ist:

- [ ] Authentic Realtime-Stats Interval erhöhen / aus
- [ ] Optional später: `manage.cgi` leichter (Monitor/Jobs-Cache) — eigener Modul-Plan, nicht mit Cert-Arbeit mischen

---

## Erfolgsdefinition

- [ ] `https://server.knoellix.net/` (gewähltes Zielbild A oder B) lädt Login zuverlässig
- [ ] Instanzseite lädt (darf 1–3 s brauchen) **ohne** 522
- [ ] 10× curl-Loop ohne Timeout
- [ ] Palworld unverändert online
- [ ] Kurze Notiz im Plan oder Audit: finaler Modus (A/B), SSL-Modus, Origin Rule ja/nein, LE ja/nein

---

## Nicht-Ziele

- Cloudflare für Game-Ports (8211) — bleibt Direkt/UDP, kein CF-HTTP-Proxy
- Modul-Refactor „schneller machen“ als Voraussetzung für Domain — erst TLS-Pfad sauber
- Spectrum / Enterprise Custom Timeouts

---

## Morgen: Reihenfolge (kurz)

1. Task 1 Baseline  
2. Task 2 Origin Redirect/Cert  
3. Task 3 CF neu  
4. Task 4 Redirect ohne Port  
5. Task 5 Test  
6. Bei Fail → Task 6 (grau + LE)  
7. Task 8 nur bei Bedarf  

*Erstellt 2026-08-01 nach 522-Incident; Ausführung geplant 2026-08-02.*
