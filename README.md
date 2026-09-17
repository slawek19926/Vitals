<div align="center">

# Vitals

**Natywny monitor systemu dla macOS.** Procesy, czujniki, dyski, sieć i zdrowie maszyny w jednym oknie — bez Electrona, bez zależności zewnętrznych, bez telemetrii.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://swift.org)
[![AppKit](https://img.shields.io/badge/UI-AppKit-1575F9)](https://developer.apple.com/documentation/appkit)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-natywnie-success)](#)
[![Zero dependencies](https://img.shields.io/badge/zale%C5%BCno%C5%9Bci-brak-lightgrey)](#)

</div>

<!-- Zrzuty ekranu: wrzuć pliki do docs/screenshots/ i odkomentuj
<div align="center">
  <img src="docs/screenshots/summary.png" width="49%" alt="Podsumowanie">
  <img src="docs/screenshots/performance.png" width="49%" alt="Wydajność">
</div>
-->

---

## Co potrafi

| | |
|---|---|
| **Podsumowanie** | Mierniki CPU / GPU / temperatury / RAM, moc systemu z SMC, TOP 15 procesów i kafelki sieci, dysków oraz zasilania. Wykresy reagują na mysz: najechanie cofa listę procesów do wybranej chwili, przeciągnięcie uśrednia przedział. |
| **Wydajność** | Osobna pozycja dla każdego urządzenia: rdzenie P/E, pamięć, GPU, Neural Engine, **każdy dysk fizyczny** (typ, architektura NVMe / USB / SATA / czytnik kart, SMART) i **każdy interfejs sieciowy** (Wi-Fi z SSID, Ethernet, hotspot, Bluetooth PAN, tunel VPN z nazwą profilu). |
| **Procesy** | Drzewo po PPID z ikonami aplikacji, kolumny CPU / pamięć / wątki / dysk R-W / wpływ na energię / wybudzenia, kończenie i sygnały, priorytet (nice), próbkowanie procesu, zakończone podświetlone przez 8 s. |
| **Zasilanie i czujniki** | Pełne drzewo SMC: temperatury, moce, napięcia, prądy, wentylatory — z wartością, minimum i maksimum, kolorowane według progów Apple silicon. |
| **Apple Silicon** | Klastry P/E z wykresem per rdzeń, GPU (urządzenie / renderer / tiler), Neural Engine, silnik multimedialny z listą kodeków. |
| **Miejsce na dysku** | Skanowanie przez `getattrlistbulk` (równolegle), treemap z drążeniem i **powiększaniem**, pierścień kategorii, największe foldery i pliki, usuwanie do Kosza. |
| **Zdrowie systemu** | Kontrole miejsca, SMART, baterii, termiki, pamięci, obciążenia, procesów zombie i zabezpieczeń (SIP, FileVault, Gatekeeper, zapora) z dziennikiem zdarzeń. |
| **Alerty** | Progi temperatury, CPU, swapu, wolnego miejsca, baterii i pojedynczego procesu — z powiadomieniami macOS. |
| **Benchmarki** | Wybierane testy: CPU (jeden rdzeń / wszystkie), przepustowość pamięci, zapis i odczyt dysku, obliczenia GPU w Metalu. Historia wyników i eksport CSV. |
| **Reszta** | Usługi launchd z akcjami, użytkownicy z procesami, połączenia TCP/UDP, Bluetooth, elementy startowe, zainstalowane aplikacje, sterowniki i rozszerzenia jądra, informacje o systemie i sprzęcie. |

Dodatkowo: **polski i angielski przełączane w locie** (bez restartu), motywy jasny / ciemny / monochromatyczny fosfor, konfigurowalne kolumny w każdej tabeli, ikona w pasku menu, eksport historii pomiarów do CSV.

## Instalacja

Pobierz `Vitals-<wersja>.zip` z [wydań](../../releases/latest), rozpakuj i przenieś **Vitals.app** do `/Applications`.

Aplikacja sama sprawdza aktualizacje (raz na dobę i na żądanie z menu **Vitals → Sprawdź aktualizacje…**). Nowa wersja pobiera się dopiero po Twojej zgodzie, a przed instalacją sprawdzany jest podpis, identyfikator zespołu i identyfikator pakietu.

## Uprawnienia

macOS pokazuje CPU i pamięć procesów innych użytkowników oraz liczniki energii CPU / GPU / Neural Engine tylko procesom z uprawnieniami administratora. Bez nich część pól pokaże „Brak dostępu”. Są dwa sposoby:

- **Pomocnik uprzywilejowany** (zalecany) — jednorazowa autoryzacja, potem żadnych monitów przy starcie.
- **Uruchom ponownie jako administrator** — hasło przy każdym uruchomieniu.

<details>
<summary>Jak włączyć pomocnika i co robi</summary>

Pakiet zawiera demona `online.equishow.vitals.helper`. Aplikacja próbuje najpierw `SMAppService` (zatwierdzenie w Elementach logowania), a gdy macOS odrzuci demona podpisanego certyfikatem zespołu osobistego, używa `SMJobBless`: jednorazowa autoryzacja instaluje pomocnika do `/Library/PrivilegedHelperTools`. Pomocnik udostępnia przez XPC pełną listę procesów, odczyty mocy (`powermetrics`) i akcje na usługach launchd. Włączenie: **Ustawienia → Pomocnik i uprawnienia → „Włącz pomocnika…”**, wyłączenie tym samym przyciskiem (usuwa plist i binarkę).

Do zbudowania pomocnika potrzebny jest certyfikat **Apple Development** (darmowe konto Apple ID wystarczy) — reguły `SMAuthorizedClients` / `SMPrivilegedExecutables` są generowane z OU certyfikatu przy budowaniu:

1. Xcode → Settings… → Accounts → „+” → zaloguj się Apple ID.
2. Personal Team → Manage Certificates… → „+” → **Apple Development**.
3. `security find-identity -v -p codesigning` pokaże np. `"Apple Development: Jan Kowalski (ABCDE12345)"`.
4. `CODESIGN_IDENTITY="Apple Development: Jan Kowalski (ABCDE12345)" ./build.sh`

Gdy `security find-identity -v` zgłasza „0 valid identities”, brakuje certyfikatu pośredniego Apple WWDR G3:
`curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer && security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db`

Bez certyfikatu pakiet dostaje podpis ad-hoc: aplikacja działa, ale pomocnika nie da się zainstalować.

</details>

> **Uwaga o licznikach energii**: IOReport „Energy Model” jest na macOS 26/27 zamrożony dla wszystkiego poza narzędziami Apple, także dla roota — bez pomocnika pola mocy CPU / GPU / ANE pokazują „—”. Moc systemu i zasilacza pochodzi z SMC i działa zawsze. Z pomocnikiem aplikacja czyta `powermetrics` i pokazuje moc oraz rzeczywiste taktowanie klastrów P/E i GPU.

## Budowanie ze źródeł

Wymagane: Xcode 15+ (Swift 5.9+). Bez zależności zewnętrznych.

```bash
git clone https://github.com/slawek19926/Vitals.git
cd Vitals
./build.sh                                   # release → build/Vitals.app
open build/Vitals.app
```

Z podpisem (konieczny dla pomocnika) i wydanie na GitHuba:

```bash
CODESIGN_IDENTITY="Apple Development: Imię Nazwisko (TEAMID)" ./build.sh
CODESIGN_IDENTITY="Apple Development: Imię Nazwisko (TEAMID)" ./release.sh --publish --notes "Opis zmian"
```

`open Package.swift` otwiera projekt w Xcode (schemat `Vitals`). Punkty przerwania działają zarówno w Swifcie, jak i w C++ w `Sources/SysCore`.

## Jak to działa

```
Sources/SysCore    C++17: libproc / sysctl / Mach (procesy, CPU, pamięć), IOKit (dyski, bateria,
                   GPU, ANE), AppleSMC (temperatury, moce), IOReport (energia). Czyste C API.
Sources/App        Swift + AppKit: Monitor (próbkowanie w tle), Theme (palety), L10n (tłumaczenia),
                   SystemHealth, Alerts, HistoryExport, Updater, Views/, Controllers/ (strony).
Sources/Helper     Pomocnik uprzywilejowany (XPC), Sources/HelperKit – wspólny protokół i wersja.
```

Pomiary chodzą w tle na własnej kolejce (domyślnie 10 razy na sekundę dla tanich odczytów, rzadziej dla SMC i XPC), wykresy rysuje Core Animation, a strony odświeżają się tylko gdy są widoczne — dzięki temu aplikacja zjada ułamek rdzenia zamiast go grzać.

`Resources/Version.config` trzyma `MAJOR.MINOR.PATCH.BUILD`; numer kompilacji rośnie przy każdym `./build.sh` i trafia do `Info.plist`, okna „O programie” oraz tagów wydań.

## Prywatność

Aplikacja nie wysyła nigdzie żadnych danych. Jedyne połączenie sieciowe to sprawdzenie najnowszego wydania w API GitHuba — można je wyłączyć w Ustawieniach.

---

<div align="center">
<sub>Zbudowane w Swifcie i C++ dla macOS na Apple silicon.</sub>
</div>
