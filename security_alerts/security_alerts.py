#!/usr/bin/env python3
"""Watch vulnerability feeds for a fixed list of products and post new findings to Slack.

Sources:
  * NVD CVE API 2.0       - every newly published CVE, matched by vendor/product, CPE or description
  * CISA KEV              - vulnerabilities confirmed as exploited in the wild
  * GitHub advisories     - repository security advisories (Claude Code, Cursor, Codex, VS Code)
  * Vendor bulletins      - Apple security releases, Mozilla advisories, Chrome Releases blog

Only the Python 3.9+ standard library is used, so it runs on macOS, Linux and GitHub Actions as is.
See README.md for setup.
"""

import argparse
import datetime as dt
import fnmatch
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
USER_AGENT = "cd.scripts-security-alerts/1.0 (+https://github.com/esm0x/cd.scripts)"

NVD_URL = "https://services.nvd.nist.gov/rest/json/cves/2.0"
KEV_URL = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
APPLE_URL = "https://support.apple.com/en-us/100100"
MOZILLA_URL = "https://www.mozilla.org/en-US/security/advisories/"
CHROME_URL = "https://chromereleases.googleblog.com/feeds/posts/default"
GITHUB_API = "https://api.github.com"

NVD_MAX_WINDOW = dt.timedelta(days=119)  # the API refuses ranges over 120 days
EXPLOITED_RX = re.compile(
    r"(?<!not )(?:exploited in the wild|actively exploited|may have been exploited|"
    r"exploit for CVE-\d+-\d+ exists in the wild|known to be exploited)",
    re.I,
)
EMPTY_VENDORS = {"", "n/a", "unknown", "none"}
SEVERITY_PL = {"CRITICAL": "krytyczna", "HIGH": "wysoka", "MEDIUM": "średnia", "LOW": "niska", "NONE": "brak"}
SEVERITY_EMOJI = {"CRITICAL": ":red_circle:", "HIGH": ":large_orange_circle:", "MEDIUM": ":large_yellow_circle:",
                  "LOW": ":white_circle:", "NONE": ":white_circle:", None: ":grey_question:"}
GHSA_SCORE = {"critical": 9.0, "high": 7.0, "medium": 4.0, "low": 0.1}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def warn(msg):
    # Shows up as an annotation when run in GitHub Actions.
    prefix = "::warning::" if os.environ.get("GITHUB_ACTIONS") else "WARNING: "
    log(prefix + msg)


# --------------------------------------------------------------------------- HTTP

def http_get(url, headers=None, retries=3, timeout=60, retry_codes=(429, 500, 502, 503, 504)):
    hdrs = {"User-Agent": USER_AGENT}
    hdrs.update(headers or {})
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code in retry_codes and attempt < retries:
                time.sleep(6 * (attempt + 1))
                continue
            raise
        except (urllib.error.URLError, TimeoutError):
            if attempt < retries:
                time.sleep(6 * (attempt + 1))
                continue
            raise


def http_get_json(url, headers=None, **kwargs):
    return json.loads(http_get(url, headers, **kwargs))


def http_post_json(url, payload, headers=None):
    hdrs = {"User-Agent": USER_AGENT, "Content-Type": "application/json; charset=utf-8"}
    hdrs.update(headers or {})
    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=hdrs, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8", "replace")


# --------------------------------------------------------------------------- helpers

def utcnow():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def parse_iso(value):
    if not value:
        return None
    value = value.strip().replace("Z", "+00:00")
    try:
        d = dt.datetime.fromisoformat(value)
    except ValueError:
        # Python < 3.11 cannot parse fractional seconds with other than 3/6 digits.
        d = dt.datetime.fromisoformat(re.sub(r"\.\d+", "", value))
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d.astimezone(dt.timezone.utc)


def version_tuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", str(v))[:4])


def version_cmp(a, b):
    ta, tb = version_tuple(a), version_tuple(b)
    n = max(len(ta), len(tb))
    ta, tb = ta + (0,) * (n - len(ta)), tb + (0,) * (n - len(tb))
    return (ta > tb) - (ta < tb)


def strip_tags(text):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", text or ""))).strip()


def shorten(text, limit):
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def slack_escape(text):
    return (text or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def severity_for(score):
    if score is None:
        return None
    if score >= 9.0:
        return "CRITICAL"
    if score >= 7.0:
        return "HIGH"
    if score >= 4.0:
        return "MEDIUM"
    if score > 0:
        return "LOW"
    return "NONE"


def rx(pattern):
    return re.compile(pattern, re.I) if pattern else None


# --------------------------------------------------------------------------- products

class Product:
    def __init__(self, cfg):
        self.id = cfg["id"]
        self.name = cfg["name"]
        self.emoji = cfg.get("emoji", ":shield:")
        self.min_version = cfg.get("min_version")
        nvd = cfg.get("nvd", {})
        self.affected = [(rx(a["vendor"]), rx(a["product"])) for a in nvd.get("affected", [])]
        self.cpes = [c.lower() for c in nvd.get("cpe", [])]
        self.description = rx(nvd.get("description"))
        kev = cfg.get("kev")
        self.kev_vendor = rx(kev["vendor"]) if kev else None
        self.kev_text = rx(kev.get("text")) if kev else None
        self.github_repos = cfg.get("github_repos", [])
        self.bulletins = [(b["source"], rx(b["title"])) for b in cfg.get("bulletins", [])]

    # -- NVD
    def matches_cve(self, cve):
        affected = [a for s in cve.get("affected", []) for a in s.get("affectedData", [])]
        cpe_matches = [m for c in cve.get("configurations", []) for n in c.get("nodes", [])
                       for m in n.get("cpeMatch", []) if m.get("vulnerable", True)]
        matched_old_only = False

        for a in affected:
            vendor, prod = a.get("vendor", ""), a.get("product", "")
            if any(v.search(vendor) and p.search(prod) for v, p in self.affected):
                if self._affected_reaches(a.get("versions") or []):
                    return True
                matched_old_only = True

        for m in cpe_matches:
            parts = m.get("criteria", "").lower().split(":")
            if len(parts) < 6:
                continue
            vp = parts[3] + ":" + parts[4]
            if any(fnmatch.fnmatchcase(vp, pat) for pat in self.cpes):
                if self._cpe_reaches(m, parts[5]):
                    return True
                matched_old_only = True

        if matched_old_only:
            return False
        # Free-text fallback only for CVEs that carry no structured product data at all,
        # otherwise third-party tools that merely mention a product would match too.
        if self.description and not cpe_matches and \
                all(a.get("vendor", "").strip().lower() in EMPTY_VENDORS for a in affected):
            return bool(self.description.search(english_description(cve)))
        return False

    def _affected_reaches(self, versions):
        if not self.min_version:
            return True
        relevant = [v for v in versions if v.get("status", "affected") == "affected"]
        if not relevant:
            return True
        for v in relevant:
            if v.get("lessThan") and v["lessThan"] not in ("*",):
                if version_cmp(v["lessThan"], self.min_version) > 0:
                    return True
            elif v.get("lessThanOrEqual") and v["lessThanOrEqual"] not in ("*",):
                if version_cmp(v["lessThanOrEqual"], self.min_version) >= 0:
                    return True
            else:
                ver = str(v.get("version", "*"))
                if ver in ("*", "0", "", "-") or not version_tuple(ver) or version_cmp(ver, self.min_version) >= 0:
                    return True
        return False

    def _cpe_reaches(self, m, cpe_version):
        if not self.min_version:
            return True
        if m.get("versionEndExcluding"):
            return version_cmp(m["versionEndExcluding"], self.min_version) > 0
        if m.get("versionEndIncluding"):
            return version_cmp(m["versionEndIncluding"], self.min_version) >= 0
        if cpe_version in ("*", "-", "") or not version_tuple(cpe_version):
            return True
        return version_cmp(cpe_version, self.min_version) >= 0

    # -- CISA KEV
    def matches_kev(self, entry):
        if not self.kev_vendor or not self.kev_vendor.search(entry.get("vendorProject", "")):
            return False
        if not self.kev_text:
            return True
        text = " ".join(entry.get(k, "") for k in ("product", "vulnerabilityName", "shortDescription"))
        return bool(self.kev_text.search(text))

    # -- vendor bulletins
    def matches_bulletin(self, source, title):
        for src, title_rx in self.bulletins:
            if src == source and title_rx.search(title):
                if self.min_version:
                    found = re.search(r"\d+(?:\.\d+)*", title)
                    if found and version_cmp(found.group(0), self.min_version) < 0:
                        return False
                return True
        return False


def english_description(cve):
    for d in cve.get("descriptions", []):
        if d.get("lang") == "en":
            return d.get("value", "")
    return ""


# --------------------------------------------------------------------------- alerts

class Alert:
    """One thing to tell the channel about. `key` deduplicates across runs and sources."""

    def __init__(self, key, kind, ident, url, title="", summary="", score=None, exploited=False,
                 exploited_note="", date=None, extra=""):
        self.key = key
        self.kind = kind            # "vuln", "kev" or "bulletin"
        self.ident = ident
        self.url = url
        self.title = title
        self.summary = summary
        self.score = score
        self.severity = severity_for(score)
        self.exploited = exploited
        self.exploited_note = exploited_note
        self.date = date
        self.extra = extra
        self.products = []          # Product objects, in config order

    def sort_key(self):
        kind_rank = {"kev": 0, "vuln": 1, "bulletin": 2}[self.kind]
        return (not self.exploited, kind_rank, -(self.score or 0), self.ident)


def cvss_score(metrics):
    for key in ("cvssMetricV40", "cvssMetricV31", "cvssMetricV30", "cvssMetricV2"):
        scores = [m.get("cvssData", {}).get("baseScore") for m in metrics.get(key, [])]
        scores = [s for s in scores if isinstance(s, (int, float))]
        if scores:
            return float(max(scores))
    return None


def ssvc_active(metrics):
    for m in metrics.get("ssvcV203", []) + metrics.get("ssvcV202", []):
        for opt in m.get("ssvcData", {}).get("options", []):
            if str(opt.get("exploitation", "")).lower() == "active":
                return True
    return False


# --------------------------------------------------------------------------- sources

def fetch_kev():
    data = http_get_json(KEV_URL)
    return data.get("vulnerabilities", [])


def source_nvd(products, since, now, kev_ids):
    headers = {}
    if os.environ.get("NVD_API_KEY"):
        headers["apiKey"] = os.environ["NVD_API_KEY"]
    alerts = []
    start = max(since, now - NVD_MAX_WINDOW)
    fmt = "%Y-%m-%dT%H:%M:%S.000Z"
    index, total = 0, None
    while total is None or index < total:
        query = urllib.parse.urlencode({
            "pubStartDate": start.strftime(fmt), "pubEndDate": now.strftime(fmt),
            "resultsPerPage": 2000, "startIndex": index,
        })
        # NVD answers 403 when it throttles, so that one is worth retrying here.
        page = http_get_json(NVD_URL + "?" + query, headers, retry_codes=(403, 429, 500, 502, 503, 504))
        total = page.get("totalResults", 0)
        vulns = page.get("vulnerabilities", [])
        if not vulns:
            break
        index += len(vulns)
        for item in vulns:
            cve = item["cve"]
            if cve.get("vulnStatus") == "Rejected":
                continue
            matched = [p for p in products if p.matches_cve(cve)]
            if not matched:
                continue
            desc = english_description(cve)
            metrics = cve.get("metrics", {})
            exploited, note = False, ""
            if cve["id"] in kev_ids or cve.get("cisaExploitAdd"):
                exploited, note = True, "CISA KEV"
            elif ssvc_active(metrics):
                exploited, note = True, "CISA SSVC: exploitation active"
            elif EXPLOITED_RX.search(desc):
                exploited, note = True, "wg opisu producenta"
            a = Alert("vuln:" + cve["id"], "vuln", cve["id"], "https://nvd.nist.gov/vuln/detail/" + cve["id"],
                      summary=desc, score=cvss_score(metrics), exploited=exploited, exploited_note=note,
                      date=parse_iso(cve.get("published")))
            a.products = matched
            alerts.append(a)
        if total > index:
            time.sleep(6 if "apiKey" not in headers else 1)
    log(f"nvd: {total or 0} CVE opublikowanych od {start:%Y-%m-%d %H:%M}Z, {len(alerts)} pasuje")
    return alerts


def source_kev(products, since, kev_entries):
    alerts = []
    since_day = since.date()
    for e in kev_entries:
        try:
            added = dt.date.fromisoformat(e.get("dateAdded", ""))
        except ValueError:
            continue
        if added < since_day:
            continue
        matched = [p for p in products if p.matches_kev(e)]
        if not matched:
            continue
        cve = e["cveID"]
        extra = f"Dodano do KEV: {e.get('dateAdded')} · termin CISA: {e.get('dueDate')}"
        if str(e.get("knownRansomwareCampaignUse", "")).lower() == "known":
            extra += " · :skull: używana w kampaniach ransomware"
        a = Alert("kev:" + cve, "kev", cve, "https://nvd.nist.gov/vuln/detail/" + cve,
                  title=e.get("vulnerabilityName", ""), summary=e.get("shortDescription", ""),
                  exploited=True, exploited_note="CISA KEV", date=parse_iso(e.get("dateAdded")), extra=extra)
        a.products = matched
        alerts.append(a)
    log(f"kev: {len(alerts)} nowych wpisów dla monitorowanych produktów")
    return alerts


def source_github(products, since):
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    by_key, failures = {}, []
    repos = []
    for p in products:
        for r in p.github_repos:
            if r not in repos:
                repos.append(r)
    for repo in repos:
        url = (f"{GITHUB_API}/repos/{repo}/security-advisories"
               "?state=published&sort=published&direction=desc&per_page=100")
        try:
            advisories = http_get_json(url, headers, retries=1)
        except Exception as e:  # one repo must not take the others down
            failures.append(f"{repo}: {e}")
            continue
        for adv in advisories:
            published = parse_iso(adv.get("published_at"))
            if not published or published < since:
                continue
            ident = adv.get("cve_id") or adv.get("ghsa_id")
            key = "vuln:" + ident
            sev = adv.get("cvss_severities") or {}
            score = ((sev.get("cvss_v4") or {}).get("score") or (sev.get("cvss_v3") or {}).get("score")
                     or (adv.get("cvss") or {}).get("score") or GHSA_SCORE.get(str(adv.get("severity")).lower()))
            if key not in by_key:
                by_key[key] = Alert(key, "vuln", ident, adv.get("html_url", ""), title=adv.get("summary", ""),
                                    summary=adv.get("description") or adv.get("summary", ""), score=score,
                                    date=published)
            alert = by_key[key]
            for p in products:
                if repo in p.github_repos and p not in alert.products:
                    alert.products.append(p)
    log(f"github: {len(by_key)} nowych advisory z {len(repos)} repozytoriów")
    if failures:
        raise PartialFailure(list(by_key.values()), "; ".join(failures))
    return list(by_key.values())


def source_apple(products, since):
    page = http_get(APPLE_URL)
    alerts = []
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", page, re.S):
        cells = re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)
        if len(cells) < 3:
            continue
        link = re.search(r'href="([^"]+)"', cells[0])
        no_cve = "no published CVE entries" in cells[0]
        name = strip_tags(re.sub(r'<div class="note.*', "", cells[0], flags=re.S))
        try:
            released = dt.datetime.strptime(strip_tags(cells[2]), "%d %b %Y").replace(tzinfo=dt.timezone.utc)
        except ValueError:
            continue
        if released.date() < since.date():
            continue
        matched = [p for p in products if p.matches_bulletin("apple", name)]
        if not matched:
            continue
        a = Alert("apple:" + name, "bulletin", name, link.group(1) if link else APPLE_URL, title=name,
                  date=released, extra="Brak opublikowanych CVE w tej aktualizacji." if no_cve else
                  "Aktualizacja bezpieczeństwa Apple, szczegóły i lista CVE pod linkiem.")
        a.products = matched
        alerts.append(a)
    log(f"apple: {len(alerts)} nowych biuletynów")
    return alerts


def source_mozilla(products, since):
    page = http_get(MOZILLA_URL)
    alerts = []
    token_rx = re.compile(
        r'<h2>(?P<date>[^<]+)</h2>|<a href="(?P<href>/[^"]*/security/advisories/(?P<id>mfsa[\d-]+)/)">\s*'
        r'<span class="level (?P<level>\w+)">[^<]*</span>\s*(?P<title>[^<]+)</a>')
    current = None
    for m in token_rx.finditer(page):
        if m.group("date"):
            try:
                current = dt.datetime.strptime(" ".join(m.group("date").split()), "%B %d, %Y") \
                    .replace(tzinfo=dt.timezone.utc)
            except ValueError:
                current = None
            continue
        if current is None or current.date() < since.date():
            continue
        title = " ".join(m.group("title").split())
        matched = [p for p in products if p.matches_bulletin("mozilla", title)]
        if not matched:
            continue
        ident = m.group("id").upper().replace("MFSA", "MFSA ")
        level = m.group("level").upper().replace("MODERATE", "MEDIUM")
        a = Alert("mozilla:" + m.group("id"), "bulletin", ident, "https://www.mozilla.org" + m.group("href"),
                  title=f"{ident}: {title}", date=current,
                  extra=f"Najwyższy poziom zagrożenia wg Mozilli: {SEVERITY_PL.get(level, level.lower())}")
        a.products = matched
        alerts.append(a)
    log(f"mozilla: {len(alerts)} nowych biuletynów")
    return alerts


def source_chrome(products, since):
    ns = {"a": "http://www.w3.org/2005/Atom"}
    root = ET.fromstring(http_get(CHROME_URL))
    alerts = []
    for entry in root.findall("a:entry", ns):
        title = (entry.findtext("a:title", "", ns) or "").strip()
        published = parse_iso(entry.findtext("a:published", "", ns))
        if not published or published < since:
            continue
        matched = [p for p in products if p.matches_bulletin("chrome", title)]
        if not matched:
            continue
        content = strip_tags(entry.findtext("a:content", "", ns))
        if "CVE-" not in content:
            continue  # stable updates without security fixes
        link = next((l.get("href") for l in entry.findall("a:link", ns) if l.get("rel") == "alternate"), CHROME_URL)
        version = re.search(r"updated to\s+([\d.]+)", content)
        fixes = re.search(r"includes\s+(\d+)\s+security fix", content)
        crit = len(re.findall(r"\bCritical CVE-", content))
        high = len(re.findall(r"\bHigh CVE-", content))
        wild = re.findall(r"exploit for (CVE-\d+-\d+) exists in the wild", content)
        parts = []
        if fixes:
            parts.append(f"{fixes.group(1)} poprawek bezpieczeństwa")
        if crit or high:
            parts.append(f"krytyczne: {crit}, wysokie: {high}")
        name = title + (f" — Chrome {version.group(1)}" if version else "")
        a = Alert("chrome:" + link, "bulletin", name, link, title=name, date=published,
                  extra=" · ".join(parts), exploited=bool(wild),
                  exploited_note=("exploit in the wild: " + ", ".join(wild)) if wild else "")
        a.products = matched
        alerts.append(a)
    log(f"chrome: {len(alerts)} nowych aktualizacji z poprawkami bezpieczeństwa")
    return alerts


class PartialFailure(Exception):
    def __init__(self, alerts, message):
        super().__init__(message)
        self.alerts = alerts


# --------------------------------------------------------------------------- Slack

def format_alert(a, primary):
    others = [p.name for p in a.products if p is not primary]
    also = f" · także: {', '.join(others)}" if others else ""
    if a.kind == "kev":
        head = f":rotating_light: *<{a.url}|{a.ident}>* — *wykorzystywana w atakach (CISA KEV)*{also}"
        body = f"*{slack_escape(a.title)}*\n{slack_escape(shorten(a.summary, 400))}\n_{slack_escape(a.extra)}_"
    elif a.kind == "vuln":
        score = f"CVSS {a.score:.1f} ({SEVERITY_PL.get(a.severity)})" if a.score is not None else "CVSS: brak oceny"
        head = f"{SEVERITY_EMOJI[a.severity]} *<{a.url}|{a.ident}>* — {score}"
        if a.exploited:
            head += f" · :rotating_light: *wykorzystywana w atakach* ({slack_escape(a.exploited_note)})"
        head += also
        text = a.summary if not a.title or a.title in a.summary else f"{a.title}. {a.summary}"
        body = slack_escape(shorten(text, 350))
    else:
        head = f":package: *<{a.url}|{slack_escape(a.title)}>*"
        if a.date:
            head += f" — {a.date:%Y-%m-%d}"
        if a.exploited:
            head += f" · :rotating_light: *{slack_escape(a.exploited_note)}*"
        head += also
        body = slack_escape(a.extra)
    return head + ("\n" + body if body else "")


def build_messages(alerts, settings):
    """Group alerts by their first matching product and render one Slack message per product."""
    groups = {}
    for a in alerts:
        groups.setdefault(a.products[0].id, (a.products[0], []))[1].append(a)
    max_items = int(settings.get("max_items_per_message", 15))
    mention = settings.get("mention_on_exploited", "")
    messages = []
    for product, items in groups.values():
        items.sort(key=Alert.sort_key)
        exploited = sum(1 for a in items if a.exploited)
        n_vuln = sum(1 for a in items if a.kind != "bulletin")
        n_bull = len(items) - n_vuln
        parts = []
        if n_vuln:
            parts.append(f"{n_vuln} {plural(n_vuln, 'nowa podatność', 'nowe podatności', 'nowych podatności')}")
        if n_bull:
            parts.append(f"{n_bull} {plural(n_bull, 'aktualizacja', 'aktualizacje', 'aktualizacji')}")
        header = f"{product.name}: {', '.join(parts)}"
        if exploited:
            header = "🚨 " + header + f" (wykorzystywane w atakach: {exploited})"
        blocks = [{"type": "header", "text": {"type": "plain_text", "text": shorten(header, 150), "emoji": True}}]
        if exploited and mention:
            blocks.append({"type": "section", "text": {"type": "mrkdwn",
                           "text": f"{mention} co najmniej jedna z poniższych podatności jest aktywnie wykorzystywana."}})
        for a in items[:max_items]:
            text = format_alert(a, product)
            if len(text) > 2900:  # Slack's limit is 3000 characters per section
                text = text[:2899] + "…"
            blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text}})
        rest = items[max_items:]
        if rest:
            links = ", ".join(f"<{a.url}|{slack_escape(shorten(a.ident, 60))}>" for a in rest)
            blocks.append({"type": "context", "elements": [{"type": "mrkdwn",
                           "text": shorten(f"…oraz {len(rest)} kolejnych: {links}", 2900)}]})
        blocks.append({"type": "context", "elements": [{"type": "mrkdwn",
                       "text": f"{product.emoji} {product.name} · źródła: NVD, CISA KEV, GitHub, biuletyny producentów · "
                               f"{utcnow():%Y-%m-%d %H:%M} UTC"}]})
        messages.append({"text": header, "blocks": blocks, "keys": [a.key for a in items]})
    return messages


def plural(n, one, few, many):
    if n == 1:
        return one
    if n % 10 in (2, 3, 4) and n % 100 not in (12, 13, 14):
        return few
    return many


def post_to_slack(message):
    payload = {"text": message["text"], "blocks": message["blocks"], "unfurl_links": False, "unfurl_media": False}
    webhook = os.environ.get("SLACK_WEBHOOK_URL")
    if webhook:
        resp = http_post_json(webhook, payload)
        if resp.strip() != "ok":
            raise RuntimeError(f"Slack webhook odpowiedział: {resp[:200]}")
        return
    token, channel = os.environ.get("SLACK_BOT_TOKEN"), os.environ.get("SLACK_CHANNEL")
    if token and channel:
        payload["channel"] = channel
        resp = json.loads(http_post_json("https://slack.com/api/chat.postMessage", payload,
                                         {"Authorization": "Bearer " + token}))
        if not resp.get("ok"):
            raise RuntimeError(f"Slack API: {resp.get('error')}")
        return
    raise RuntimeError("Brak konfiguracji Slacka: ustaw SLACK_WEBHOOK_URL albo SLACK_BOT_TOKEN + SLACK_CHANNEL")


def print_message(message):
    print("=" * 80)
    for b in message["blocks"]:
        if b["type"] == "header":
            print("## " + b["text"]["text"])
        elif b["type"] == "section":
            print(b["text"]["text"] + "\n")
        else:
            print("   " + b["elements"][0]["text"])


# --------------------------------------------------------------------------- state

def load_state(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {"sources": {}, "seen": {}}


def save_state(path, state, retention_days):
    cutoff = (utcnow() - dt.timedelta(days=retention_days)).strftime("%Y-%m-%d")
    state["seen"] = {k: v for k, v in state["seen"].items() if v >= cutoff}
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


# --------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="Powiadomienia Slack o nowych podatnościach w wybranych produktach.")
    ap.add_argument("--config", default=os.path.join(HERE, "config.json"))
    ap.add_argument("--state", default=os.environ.get("SECURITY_ALERTS_STATE", os.path.join(HERE, "state.json")))
    ap.add_argument("--dry-run", action="store_true", help="wypisz wiadomości zamiast wysyłać; nie zapisuje stanu")
    ap.add_argument("--since-days", type=float, help="sprawdź ostatnie N dni zamiast okna od ostatniego uruchomienia")
    ap.add_argument("--test-slack", action="store_true", help="wyślij wiadomość testową na Slacka i zakończ")
    ap.add_argument("--strict", action="store_true", help="kod wyjścia 1, gdy któreś źródło zawiedzie")
    args = ap.parse_args()

    if args.test_slack:
        post_to_slack({"text": "Test powiadomień o podatnościach", "blocks": [{"type": "section", "text": {
            "type": "mrkdwn", "text": ":white_check_mark: *security_alerts* — połączenie ze Slackiem działa."}}]})
        log("Wiadomość testowa wysłana.")
        return 0

    with open(args.config, encoding="utf-8") as f:
        config = json.load(f)
    settings = config.get("settings", {})
    products = [Product(p) for p in config["products"]]
    state = load_state(args.state)
    first_run = not state["sources"]
    now = utcnow()
    overlap = dt.timedelta(hours=float(settings.get("overlap_hours", 24)))
    initial = dt.timedelta(days=float(settings.get("initial_lookback_days", 3)))

    def since_for(name):
        if args.since_days is not None:
            return now - dt.timedelta(days=args.since_days)
        last = parse_iso(state["sources"].get(name))
        return (last - overlap) if last else (now - initial)

    if first_run and args.since_days is None:
        log(f"Pierwsze uruchomienie: sprawdzam ostatnie {initial.days} dni.")

    alerts, ok_sources, failed = [], [], []
    kev_entries, kev_ids = [], set()
    try:
        kev_entries = fetch_kev()
        kev_ids = {e["cveID"] for e in kev_entries}
    except Exception as e:
        failed.append(f"kev: {e}")

    runners = [("kev", lambda s: source_kev(products, s, kev_entries)),
               ("nvd", lambda s: source_nvd(products, s, now, kev_ids)),
               ("github", lambda s: source_github(products, s)),
               ("apple", lambda s: source_apple(products, s)),
               ("mozilla", lambda s: source_mozilla(products, s)),
               ("chrome", lambda s: source_chrome(products, s))]
    for name, run in runners:
        if name == "kev" and not kev_entries:
            continue
        try:
            alerts += run(since_for(name))
            ok_sources.append(name)
        except PartialFailure as e:
            alerts += e.alerts
            failed.append(f"{name}: {e}")
        except Exception as e:
            failed.append(f"{name}: {e}")
    for f in failed:
        warn("źródło nie odpowiedziało: " + f)

    # Deduplicate: the same CVE from NVD and GitHub, and KEV entries that arrive together with the CVE itself.
    min_cvss = float(settings.get("min_cvss", 0))
    include_unscored = settings.get("include_unscored", True)
    kev_now = {a.ident for a in alerts if a.kind == "kev"}
    merged = {}
    for a in alerts:
        if a.key in state["seen"]:
            continue
        if a.key in merged:
            for p in a.products:
                if p not in merged[a.key].products:
                    merged[a.key].products.append(p)
            continue
        merged[a.key] = a
    fresh = []
    for a in merged.values():
        if a.kind == "vuln" and a.ident in kev_now:
            continue  # the KEV alert for the same CVE says more
        if a.kind == "vuln" and a.ident in kev_ids and not a.exploited:
            a.exploited, a.exploited_note = True, "CISA KEV"
        if a.kind == "vuln" and not a.exploited:
            if a.score is None and not include_unscored:
                continue
            if a.score is not None and a.score < min_cvss:
                state["seen"][a.key] = now.strftime("%Y-%m-%d")  # below threshold: do not re-check
                continue
        order = {p.id: i for i, p in enumerate(products)}
        a.products.sort(key=lambda p: order[p.id])
        fresh.append(a)

    # Mark the CVE itself seen when its KEV alert goes out, so NVD does not report it again later.
    extra_seen = {"vuln:" + i for i in kev_now}
    messages = build_messages(fresh, settings)
    log(f"Do wysłania: {len(fresh)} pozycji w {len(messages)} wiadomościach.")

    if args.dry_run:
        for m in messages:
            print_message(m)
        return 1 if (failed and args.strict) else 0

    all_sent = True
    for m in messages:
        try:
            post_to_slack(m)
            for k in m["keys"]:
                state["seen"][k] = now.strftime("%Y-%m-%d")
            time.sleep(1.1)  # Slack allows about one message per second per channel
        except Exception as e:
            all_sent = False
            warn(f"nie udało się wysłać wiadomości '{m['text']}': {e}")
    if all_sent:
        # Only move the time windows forward once everything found in them reached Slack.
        for k in extra_seen:
            state["seen"][k] = now.strftime("%Y-%m-%d")
        for name in ok_sources:
            state["sources"][name] = now.isoformat()
    save_state(args.state, state, int(settings.get("state_retention_days", 400)))
    if not all_sent:
        return 1
    return 1 if (failed and args.strict) else 0


if __name__ == "__main__":
    sys.exit(main())
