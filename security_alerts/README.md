# Powiadomienia o podatnościach → Slack

Skrypt co godzinę sprawdza publiczne źródła informacji o podatnościach i wysyła na wybrany kanał Slacka wiadomość, gdy pojawi się coś nowego dla monitorowanych produktów:

| Produkt | Skąd bierze dane |
|---|---|
| macOS 14 i nowsze | NVD, CISA KEV, biuletyny Apple |
| iOS | NVD, CISA KEV, biuletyny Apple |
| Google Chrome | NVD, CISA KEV, blog Chrome Releases (Stable Desktop) |
| Mozilla Firefox | NVD, CISA KEV, Mozilla Security Advisories |
| Brave | NVD, CISA KEV (w tym exploity Chromium, które dotyczą też Brave) |
| Ubiquiti / UniFi | NVD, CISA KEV |
| Xcode | NVD, CISA KEV, biuletyny Apple |
| Android Studio | NVD, CISA KEV |
| Visual Studio Code | NVD, CISA KEV, GitHub Security Advisories `microsoft/vscode` |
| Claude (Code / Desktop / SDK) | NVD, CISA KEV, GitHub Security Advisories `anthropics/claude-code` |
| Cursor | NVD, CISA KEV, GitHub Security Advisories `cursor/cursor` |
| OpenAI Codex | NVD, CISA KEV, GitHub Security Advisories `openai/codex` |

Źródła:

* **NVD** (National Vulnerability Database): każdy nowo opublikowany CVE. Dopasowanie po danych producenta (vendor/product), po CPE, a gdy CVE nie ma żadnych danych strukturalnych, po opisie. Dla macOS brane są tylko CVE dotyczące wersji 14+.
* **CISA KEV**: podatności potwierdzone jako **aktywnie wykorzystywane w atakach**. Takie wpisy idą zawsze, niezależnie od progu CVSS, z oznaczeniem 🚨 i opcjonalnym `@channel`.
* **GitHub Security Advisories**: advisory publikowane w repozytoriach narzędzi deweloperskich, zwykle zanim CVE trafi do NVD.
* **Biuletyny producentów**: nowa aktualizacja bezpieczeństwa od Apple, Mozilli i Google (Chrome). To sygnał „łatka jest dostępna, aktualizuj”.

Podatności są oznaczane jako wykorzystywane w atakach, gdy są w KEV, gdy CISA SSVC ma `exploitation: active` albo gdy producent pisze o tym w opisie (np. Apple: „may have been exploited”, Chrome: „exploit … exists in the wild”).

## Jak wygląda wiadomość

Jedna wiadomość na produkt na jedno uruchomienie:

```
🚨 Google Chrome: 2 nowe podatności, 1 aktualizacja (wykorzystywane w atakach: 1)
@channel co najmniej jedna z poniższych podatności jest aktywnie wykorzystywana.
🚨 CVE-2026-87491 — wykorzystywana w atakach (CISA KEV) · także: Brave
   Google Chromium V8 Out of Bounds Write Vulnerability …
🔴 CVE-2026-110922 — CVSS 9.6 (krytyczna)
   Use after free in Prerender in Google Chrome prior to 155.0.8059.84 …
📦 Stable Channel Update for Desktop — Chrome 155.0.8059.84 — 2026-10-15
   10 poprawek bezpieczeństwa · krytyczne: 1, wysokie: 6
```

Jeśli pozycji jest więcej niż `max_items_per_message` (domyślnie 15), reszta trafia na koniec jako lista linków.

## Uruchomienie w GitHub Actions (zalecane)

Workflow `.github/workflows/security-alerts.yml` uruchamia skrypt co godzinę, nic nie trzeba stawiać. Stan (co już zostało wysłane) trzymany jest w cache GitHub Actions.

1. **Utwórz webhook w Slacku**
   * https://api.slack.com/apps → *Create New App* → *From scratch*, wybierz workspace.
   * *Incoming Webhooks* → włącz → *Add New Webhook to Workspace* → wybierz kanał, np. `#security-alerts`.
   * Skopiuj adres `https://hooks.slack.com/services/...`.
2. **Dodaj sekret w repozytorium**: *Settings → Secrets and variables → Actions → New repository secret*
   * `SLACK_WEBHOOK_URL` = adres webhooka.
   * (opcjonalnie) `NVD_API_KEY`: darmowy klucz z https://nvd.nist.gov/developers/request-an-api-key, podnosi limity zapytań do NVD.
3. **Sprawdź działanie**: *Actions → Security alerts -> Slack → Run workflow*.
   * Zaznacz `dry_run` i wpisz np. `7` w `since_days`, żeby zobaczyć w logu, co zostałoby wysłane z ostatnich 7 dni.
   * Potem uruchom bez `dry_run`. Pierwsze normalne uruchomienie wysyła to, co pojawiło się w ostatnich 3 dniach (`initial_lookback_days`), kolejne już tylko nowości.

Zamiast webhooka można użyć bota: sekret `SLACK_BOT_TOKEN` (`xoxb-…`, uprawnienie `chat:write`, bot zaproszony na kanał) i zmienna repozytorium `SLACK_CHANNEL` (np. `C0123456789` albo `#security-alerts`).

> GitHub wyłącza zaplanowane workflowy w repozytoriach publicznych po 60 dniach bez żadnej aktywności w repo. Jeśli powiadomienia ucichną, sprawdź zakładkę *Actions* i włącz workflow ponownie.

## Uruchomienie lokalne (macOS / Linux)

Wymaga tylko Pythona 3.9+ (bez dodatkowych pakietów).

```bash
export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...'
python3 security_alerts/security_alerts.py --test-slack          # wiadomość testowa
python3 security_alerts/security_alerts.py --dry-run --since-days 7   # podgląd bez wysyłania
python3 security_alerts/security_alerts.py                       # normalne uruchomienie
```

Co godzinę z crona (`crontab -e`):

```
17 * * * * SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...' /usr/bin/python3 /ścieżka/do/security_alerts/security_alerts.py >> /tmp/security_alerts.log 2>&1
```

Stan zapisywany jest w `security_alerts/state.json` (inną ścieżkę można podać przez `--state` lub zmienną `SECURITY_ALERTS_STATE`).

| Opcja | Działanie |
|---|---|
| `--dry-run` | wypisuje wiadomości w terminalu, nic nie wysyła i nie zapisuje stanu |
| `--since-days N` | sprawdza ostatnie N dni zamiast okna od ostatniego uruchomienia |
| `--test-slack` | wysyła wiadomość testową i kończy |
| `--strict` | kod wyjścia 1, gdy któreś ze źródeł nie odpowie |
| `--config PLIK` / `--state PLIK` | inny plik konfiguracji / stanu |

## Konfiguracja (`config.json`)

`settings`:

| Klucz | Domyślnie | Znaczenie |
|---|---|---|
| `min_cvss` | `7.0` | minimalny wynik CVSS dla zwykłych CVE. `0` = wszystko. Wykorzystywane w atakach idą zawsze |
| `include_unscored` | `true` | czy wysyłać CVE, które nie mają jeszcze oceny CVSS |
| `max_items_per_message` | `15` | ile pozycji opisać w jednej wiadomości |
| `initial_lookback_days` | `3` | ile dni wstecz sprawdzić przy pierwszym uruchomieniu |
| `overlap_hours` | `24` | zakładka czasowa między uruchomieniami (duplikaty są i tak odfiltrowane) |
| `mention_on_exploited` | `<!channel>` | wzmianka przy podatnościach wykorzystywanych w atakach; `""` wyłącza, `<!here>` tylko aktywni, `<@U012ABC>` konkretna osoba |

Każdy produkt w `products` ma:

* `nvd.affected`: lista par wyrażeń regularnych `vendor` / `product` porównywanych z danymi producenta w CVE,
* `nvd.cpe`: wzorce `vendor:product` z CPE (dozwolone `*`, np. `ui:*`),
* `nvd.description`: wyrażenie dla CVE bez danych strukturalnych (opcjonalne),
* `min_version`: najniższa wersja, która nas interesuje (np. `"14"` dla macOS),
* `kev`: `vendor` i opcjonalnie `text` (szukany w nazwie produktu, nazwie i opisie podatności w KEV),
* `github_repos`: repozytoria, z których czytane są GitHub Security Advisories,
* `bulletins`: biuletyny producenta (`apple`, `mozilla`, `chrome`) i wyrażenie na tytuł.

Przykład: dodanie Slacka (aplikacji) jako produktu:

```json
{
  "id": "slack",
  "name": "Slack",
  "nvd": {"affected": [{"vendor": "^Slack", "product": "Slack"}], "cpe": ["slack:slack"]},
  "kev": {"vendor": "^Slack"}
}
```

## Ograniczenia

* NVD ma zaległości w analizie: CVE bez danych producenta i bez CPE są dopasowywane tylko po opisie. Główni producenci (Apple, Google, Mozilla, Microsoft, GitHub, HackerOne dla Ubiquiti) podają te dane od razu, więc w praktyce dotyczy to rzadkich przypadków.
* Duże wydanie Chrome to kilkadziesiąt CVE naraz. Wiadomość pokazuje wtedy 15 najpoważniejszych, resztę jako linki. Jeśli to za dużo, podnieś `min_cvss` albo usuń `nvd` z produktu Chrome i zostaw tylko biuletyny + KEV.
* Brave korzysta z Chromium: aktywnie wykorzystywane podatności Chromium (KEV) są oznaczane też jako dotyczące Brave, zwykłe CVE Chrome nie.
* Android Studio nie ma osobnego kanału z biuletynami; podatności są wyłapywane tylko z NVD i KEV.
