# Changelog

## 1.2.0.151 — 2026-10-08

### English

This release adds Simplified Chinese, improves connection inspection and Bluetooth discovery, and makes hardware readings more reliable. It includes changes since 1.1.1.143.

#### New and improved

- **Simplified Chinese:** a new language option covers menus, settings, alerts, tooltips, sidebar labels and floating panel titles. Chinese headings use native system fonts, and privacy descriptions are localized in Polish, English and Simplified Chinese. The original localization was contributed by @macong0420 in [PR #3](https://github.com/slawek19926/Vitals/pull/3).
- **Connection inspection:** TCP/UDP sockets are grouped by application and destination. Expand a destination to inspect individual sockets and local ports, or switch to the socket view. Remote, listening and local filters, search and sorting make the list easier to navigate; the grouped table uses a more compact layout.
- **Bluetooth:** connected and paired devices have separate sections. On-demand BLE scanning runs for 12 seconds and displays available names and signal strength. Devices that do not broadcast a name are identified as unknown; paired devices remain visible without a scan.
- **Power and sensors:** show measured SMC temperatures, fan speeds and verified power-rail readings. Summary counts distinguish temperatures, voltages, power and currents, and omit fans when none are available. macOS does not expose every physical hardware sensor.

#### Fixes

- System language selection follows the complete preferred-language list, skipping unsupported locales and Traditional Chinese. Explicit user choices are preserved; English is the final fallback and the bundle development language.
- Quick Action installation and removal clean up every known Polish, English and Simplified Chinese workflow name. Reinstallation after a language change leaves exactly one workflow.
- Unavailable Bluetooth RSSI values are no longer presented as strong signals. Battery readings require an unambiguous product-name match.
- SMC numeric decoding supports signed and fixed-point values; opaque keys and temperature setpoints are excluded from measured readings.
- Duplicate file descriptors no longer inflate socket counts.

#### Downloads and verification

- Use Vitals-1.2.0.151.zip for extraction or the in-app updater, or open Vitals-1.2.0.151.dmg and drag Vitals into Applications.
- All 57 regression tests passed. Release packaging, code signatures and all three localized privacy resources were verified. Chinese → English → Polish → Chinese switching was checked in an isolated app copy on macOS.
- The app is signed with an Apple Development certificate and is not notarized. Updating the privileged helper may require macOS authorization.

<details>
<summary>Polski — rozwiń changelog</summary>

To wydanie dodaje chiński uproszczony, ułatwia przeglądanie połączeń i wykrywanie urządzeń Bluetooth oraz poprawia wiarygodność odczytów sprzętu. Obejmuje zmiany od wersji 1.1.1.143.

#### Nowości i usprawnienia

- **Chiński uproszczony:** nowy język obejmuje menu, ustawienia, alerty, podpowiedzi, etykiety paska bocznego i tytuły paneli. Chińskie nagłówki korzystają z systemowych czcionek, a opisy uprawnień są dostępne po polsku, angielsku i chińsku uproszczonym. Autorem pierwotnego tłumaczenia w [PR #3](https://github.com/slawek19926/Vitals/pull/3) jest @macong0420.
- **Przeglądanie połączeń:** gniazda TCP/UDP są pogrupowane według aplikacji i celu. Cel można rozwinąć, aby zobaczyć gniazda i porty lokalne, albo przełączyć się na widok gniazd. Filtry połączeń zdalnych, nasłuchujących i lokalnych, wyszukiwanie oraz sortowanie ułatwiają przeglądanie; tabela grup ma bardziej zwarty układ.
- **Bluetooth:** osobne sekcje urządzeń połączonych i sparowanych. Skanowanie BLE na żądanie trwa 12 sekund i pokazuje dostępne nazwy oraz siłę sygnału. Urządzenia bez nadawanej nazwy są oznaczone jako nieznane; lista sparowanych jest widoczna bez skanowania.
- **Zasilanie i czujniki:** wyświetlane są zmierzone temperatury SMC, obroty wentylatorów i potwierdzone odczyty szyn zasilania. Podsumowanie rozróżnia liczbę temperatur, napięć, mocy i prądów oraz pomija wentylatory, jeśli ich nie ma. macOS nie udostępnia każdego fizycznego czujnika.

#### Poprawki

- Wybór języka systemowego uwzględnia całą listę preferencji, pomija nieobsługiwane języki i chiński tradycyjny. Ręczny wybór pozostaje zachowany; angielski jest językiem zapasowym i bazowym pakietu.
- Instalowanie i usuwanie akcji szybkiej sprząta wszystkie znane polskie, angielskie i chińskie nazwy workflow. Ponowna instalacja po zmianie języka pozostawia dokładnie jedną akcję.
- Niedostępny odczyt RSSI Bluetooth nie jest już pokazywany jako mocny sygnał. Odczyt baterii wymaga jednoznacznego dopasowania nazwy produktu.
- Dekodowanie SMC obsługuje wartości ze znakiem i stałoprzecinkowe; niezrozumiałe klucze oraz docelowe temperatury są pomijane wśród pomiarów.
- Powielone deskryptory plików nie zawyżają już liczby gniazd.

#### Pobieranie i weryfikacja

- Użyj Vitals-1.2.0.151.zip do rozpakowania lub aktualizacji w aplikacji albo otwórz Vitals-1.2.0.151.dmg i przeciągnij Vitals do Aplikacji.
- Wszystkie 57 testów regresyjnych przeszło. Sprawdzono pakowanie release, podpisy i opisy uprawnień we wszystkich trzech językach. Przełączanie chiński → angielski → polski → chiński sprawdzono w osobnej kopii aplikacji na macOS.
- Aplikacja jest podpisana certyfikatem Apple Development i nie jest notaryzowana. Aktualizacja pomocnika uprzywilejowanego może wymagać autoryzacji macOS.

</details>

## 1.1.1.143 — 2026-09-22

### English

This release adds automatic helper updates, faster access to Vitals, and reliability improvements across monitoring, process actions and application updates. Changes below cover the releases since 1.1.0.137.

#### New and improved

- **Automatic helper updates:** Vitals detects an older running helper, updates it using its existing installation method, and verifies the new version over XPC. Installation progress and failures appear in Settings. Cancelling does not cause repeated prompts in the same session; manual retry remains available. Newer helpers are not downgraded.
- **Keyboard access:** a configurable global shortcut shows Vitals while it is running. An optional “Show Vitals” Quick Action can also launch the app after it has been fully closed; assign its shortcut in macOS Keyboard settings.
- **Monitoring profiles:** Power saving, Standard and Diagnostic presets make it easier to choose the sampling rate. Measurement history now retains up to ten minutes, capped at 6,000 samples.
- **Clearer readings:** CPU tooltips explain the per-core percentage scale, energy and wakeup indicators are identified as estimates, and sensor views distinguish stale readings from missing data.

#### Fixes

- Strengthened app–helper XPC authentication with Apple signing, bundle identifier and team checks; user service actions are restricted to the caller's user domain.
- Process actions validate PID and process start time before acting. Priority changes use the helper, and actions without a known process identity are disabled.
- Fixed update download handling and package validation. Replacing the app retains a backup of the previous version and attempts to restore it if replacement or launch fails.
- Power readings expire after six seconds instead of leaving stale values on screen. Disk and network graphs receive new samples at their intended intervals.
- Improved command timeout handling, output capture and error reporting, including service and startup-item operations.
- Fixed disk benchmark handling of partial reads/writes, cancellation and cleanup. Failed benchmarks are no longer saved as valid zero results; CPU and memory throughput use actual elapsed time.
- Improved CSV escaping, preserved empty fields for unavailable measurements, and added recording failure reporting.
- Fixed sorting edge cases and disk icons after language changes. Signed packages enable Hardened Runtime, and packaging stops if signing fails.
- Added 37 regression tests, a build/test CI workflow, and updated English and Polish documentation.

#### Updating and verification

- Download `Vitals-1.1.1.143.zip`, extract it and move `Vitals.app` to `/Applications`, or use the app's update check.
- Updating an installed helper may require a macOS administrator password or approval in Login Items. If cancelled, retry in **Settings → Helper and privileges → Update helper…**.
- The package is signed with an Apple Development certificate; it is not notarized. macOS may display its usual security prompt.
- All 37 local regression tests passed, and the release bundle's signature was verified. Full helper replacement with system authorization and an end-to-end update of an installed app have not been verified for this release.

<details>
<summary>Polski — rozwiń changelog</summary>

To wydanie dodaje automatyczną aktualizację pomocnika, szybszy dostęp do Vitals oraz poprawki niezawodności pomiarów, akcji procesów i aktualizacji aplikacji. Poniższa lista obejmuje zmiany od wersji 1.1.0.137.

#### Nowości i usprawnienia

- **Automatyczna aktualizacja pomocnika:** Vitals wykrywa starszego działającego pomocnika, aktualizuje go dotychczasową metodą instalacji i potwierdza nową wersję przez XPC. Postęp i błędy są widoczne w Ustawieniach. Anulowanie nie powoduje kolejnych monitów w tej samej sesji; pozostaje możliwość ręcznego ponowienia. Nowszy pomocnik nie jest zastępowany starszym.
- **Dostęp z klawiatury:** konfigurowalny skrót globalny pokazuje okno działającego Vitals. Opcjonalna akcja szybka „Pokaż Vitals” uruchamia aplikację również po jej całkowitym zamknięciu; skrót przypisuje się w ustawieniach klawiatury macOS.
- **Profile monitorowania:** Oszczędny, Standardowy i Diagnostyczny ułatwiają wybór częstotliwości pomiarów. Historia przechowuje teraz do dziesięciu minut danych, maksymalnie 6000 próbek.
- **Czytelniejsze odczyty:** podpowiedzi CPU wyjaśniają skalę procentową na rdzeń, wskaźniki energii i wybudzeń są opisane jako szacunkowe, a widoki czujników rozróżniają nieaktualne odczyty od braku danych.

#### Poprawki

- Wzmocniono uwierzytelnianie XPC aplikacja–pomocnik: sprawdzane są podpis Apple, identyfikator pakietu i zespół. Akcje na usługach użytkownika są ograniczone do domeny wywołującego użytkownika.
- Akcje procesów sprawdzają PID i czas utworzenia procesu przed wykonaniem. Zmiana priorytetu korzysta z pomocnika, a akcje bez ustalonej tożsamości procesu są wyłączone.
- Poprawiono obsługę pobranego pliku aktualizacji i weryfikację pakietu. Podmiana aplikacji zachowuje kopię poprzedniej wersji i podejmuje próbę jej przywrócenia po błędzie podmiany lub uruchomienia.
- Odczyty mocy wygasają po sześciu sekundach zamiast pozostawiać stare wartości na ekranie. Wykresy dysków i sieci otrzymują nowe próbki zgodnie z harmonogramem pomiarów.
- Poprawiono limity czasu poleceń, przechwytywanie wyjścia i raportowanie błędów, także przy operacjach na usługach i elementach startowych.
- Poprawiono obsługę częściowych zapisów i odczytów, anulowania i sprzątania w benchmarku dysku. Nieudane testy nie są zapisywane jako poprawne wyniki zerowe; przepustowość CPU i pamięci uwzględnia rzeczywisty czas testu.
- Poprawiono zapis znaków specjalnych w CSV, zachowano puste pola dla niedostępnych pomiarów i dodano zgłaszanie błędów nagrywania.
- Poprawiono przypadki brzegowe sortowania i ikony dysków po zmianie języka. Podpisane pakiety korzystają z Hardened Runtime, a błąd podpisu przerywa pakowanie.
- Dodano 37 testów regresyjnych, workflow CI do budowania i testowania oraz aktualizacje dokumentacji angielskiej i polskiej.

#### Aktualizacja i weryfikacja

- Pobierz `Vitals-1.1.1.143.zip`, rozpakuj i przenieś `Vitals.app` do `/Applications` lub użyj sprawdzania aktualizacji w aplikacji.
- Aktualizacja zainstalowanego pomocnika może wymagać hasła administratora macOS lub zatwierdzenia w Elementach logowania. Po anulowaniu ponów próbę w **Ustawienia → Pomocnik i uprawnienia → Zaktualizuj pomocnika…**.
- Pakiet jest podpisany certyfikatem Apple Development; nie jest notaryzowany. macOS może wyświetlić standardowy komunikat bezpieczeństwa.
- Wszystkie 37 lokalnych testów regresyjnych przeszło, a podpis pakietu wydania został zweryfikowany. Pełna wymiana pomocnika z autoryzacją systemową oraz aktualizacja zainstalowanej aplikacji od początku do końca nie zostały zweryfikowane dla tego wydania.

</details>
