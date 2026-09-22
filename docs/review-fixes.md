# Poprawki po przeglądzie — 22.09.2026

## Zmiany

- Automatyczna aktualizacja starszego pomocnika po odczycie jego wersji przez XPC, niezależnie od dekodowania listy procesów. Aktualizacja zachowuje dotychczasowy instalator: `SMJobBless` dla pomocnika w `/Library`, `SMAppService` dla demona w pakiecie. W drugim przypadku rejestracja czeka na zakończenie asynchronicznego wyrejestrowania. Sukces wymaga odpowiedzi nowej wersji przez XPC; sprawdzanie ma limit prób. Anulowanie/błąd nie uruchamia pętli instalacji, ręczne ponowienie pozostaje dostępne. Aplikacja respektuje cofnięte zatwierdzenie demona `SMAppService` w ustawieniach systemu i nie obniża wersji pomocnika. Autoryzacja `SMJobBless` pozostaje osobna: na sprawdzonym komputerze `statusForLegacyPlist` zwracał `requiresApproval` mimo uruchomionego pomocnika, więc nie jest używany do blokowania zapytania XPC ani jego aktualizacji.
- Pomocnik i aplikacja weryfikują podpis, identyfikator pakietu oraz zespół drugiej strony XPC. Pomocnik bez zaufanego podpisu nie uruchamia usługi. Dostęp do domen `gui`/`user` jest ograniczony do UID wywołującego; domena `system` pozostaje dostępna dla zaufanej aplikacji.
- Akcje procesów odrzucają PID ≤ 1 i brak tożsamości. Czas utworzenia procesu ma precyzję mikrosekund i jest ponownie sprawdzany bezpośrednio przed sygnałem lub zmianą priorytetu. Nowy pomocnik obsługuje zmianę priorytetu bez przekazywania PID przez opóźniony dialog `osascript`. Kontrola i syscall są osobnymi operacjami systemowymi: nie stanowi to gwarancji atomowej ochrony przed każdą możliwą zmianą PID.
- Wskaźniki Authorization Services pozostają ważne przez cały czas wywołania.
- Polecenia zwracają stdout, stderr, kod wyjścia, informację o timeout i błędzie uruchomienia. Oba potoki są odczytywane równolegle z działaniem procesu. Timeout obejmuje także proces, który zamknął wyjście, ale nadal działa.
- Aktualizator przejmuje plik URLSession przed końcem callbacka, przygotowuje i weryfikuje pakiet w tle oraz wymaga podpisu Apple zgodnego z zespołem i identyfikatorem aplikacji. Sprawdza także wersję pakietu względem wydania.
- Podmiana korzysta z argumentów powłoki, bez interpolacji ścieżek w kodzie. Stara wersja jest przenoszona do osobnego pakietu `Vitals-previous-<UUID>.app`. Błąd podmiany lub uruchomienia powoduje próbę przywrócenia starego pakietu. Po udanej aktualizacji kopia pozostaje obok aplikacji; można ją usunąć po sprawdzeniu nowej wersji. Nie gwarantuje to transakcyjności w razie utraty zasilania/SIGKILL między operacjami.
- Moc wygasa po sześciu sekundach od pozyskania próbki, również przy powtarzaniu tego samego wyniku. Widok czujników rozróżnia nieaktualne dane od braku danych i pokazuje źródło.
- Synchronizacja stanu XPC, anulowania skanera i benchmarków oraz liczników użytkowników czujników usuwa niesynchronizowane odczyty tych pól.
- Dyski fizyczne są odczytywane co około dwie sekundy, interfejsy co pół sekundy. Ich wykresy otrzymują tylko nowe próbki.
- Benchmark dysku obsługuje częściowe zapisy, błędy, anulowanie, rzeczywistą liczbę bajtów i sprzątanie pliku. CPU/RAM używają rzeczywistego czasu testu. Nieudane testy nie są zapisywane jako poprawne zera.
- CSV zachowuje cudzysłowy, separatory i nowe linie. Niedostępne pomiary mają puste komórki. Błędy uruchomienia i zapisu nagrywania są zgłaszane.
- Ustawienia zawierają profile Oszczędny/Standardowy/Diagnostyczny. Nagłówki kolumn wyjaśniają skalę CPU i szacunkowy charakter wskaźników energii/wybudzeń. Historia w pamięci obejmuje maksymalnie dziesięć minut i 6000 próbek, zamiast 1500 próbek.
- Poprawiono wielkość liter w nagłówkach C++, porównywanie równych wartości przy sortowaniu malejącym i ikony dysków po zmianie języka. Pakowanie włącza Hardened Runtime. Budowanie nie ukrywa niepowodzenia podpisu i nie powtarza kompilacji bez potrzeby.

## Sprawdzanie

```sh
swift test
swift build -c release
zsh -n build.sh release.sh
```

Testy obejmują odrzucenie niezaufanego połączenia przez rzeczywisty listener XPC (bez instalacji demona), walidację domen i PID, zgodność tożsamości z odczytem jądra, stderr/timeout/duże wyjście poleceń, wygasanie mocy, przejęcie pobranego pliku, podmianę pakietu i rollback, ścieżki ze znakami powłoki, CSV, skaner oraz błędy i anulowanie benchmarku.

Testy aktualizacji pomocnika używają wstrzykniętych operacji instalatora i XPC: obejmują wybór właściwego instalatora, kolejność zatrzymanie → rejestracja, brak ponowień po anulowaniu, ręczne ponowienie, oczekiwanie na zatwierdzenie, spóźniony restart, limit prób oraz ochronę przed obniżeniem wersji. Nie zastępują próby z rzeczywistym demonem i systemowym dialogiem autoryzacji.

Czysta kopia źródeł może uruchomić `swift test` bez `Resources/gen`. Plist deweloperski służy wyłącznie do budowania; nie umożliwia instalacji zaufanego pomocnika. Workflow CI jest zapisany lokalnie; nie został wysłany na serwer.

## Weryfikacja wymagająca podpisanej aplikacji

Przed wydaniem należy zbudować aplikację z właściwym certyfikatem, zaktualizować zainstalowanego pomocnika i sprawdzić autoryzowany klient → pomocnik, instalację/odinstalowanie demona oraz aktualizację rzeczywistego podpisanego pakietu. Nie wykonywano tych operacji na systemie użytkownika. Starszy pomocnik bez nowego pola tożsamości powoduje celowe wyłączenie akcji procesów do czasu aktualizacji.

Rozbudowa historii do godziny/doby z agregacją, wspólna oś alertów, automatyczne wskazywanie przyczyny spowolnienia oraz dodatkowe grupowanie aplikacji pozostają osobnymi propozycjami rozwoju; nie są częścią tego pakietu napraw.
