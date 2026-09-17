#!/bin/zsh
# Buduje podpisany pakiet, pakuje go do ZIP-a i (opcjonalnie) publikuje wydanie na GitHubie.
#
#   ./release.sh                      – buduje i pakuje do build/Vitals-<wersja>.zip
#   ./release.sh --publish            – dodatkowo tworzy wydanie przez gh (tag v<wersja>)
#   ./release.sh --publish --notes "Opis zmian"
#
# Updater w aplikacji czyta https://api.github.com/repos/<REPO>/releases/latest
# i pobiera pierwszy załącznik .zip, więc nazwa pliku może być dowolna.
set -e
cd "$(dirname "$0")"

REPO="slawek19926/Vitals"     # musi być zgodne z Updater.repository w Sources/App/Updater.swift
PUBLISH=0
NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1 ;;
    --notes) shift; NOTES="$1" ;;
    --repo) shift; REPO="$1" ;;
    *) echo "Nieznany argument: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ -z "$CODESIGN_IDENTITY" ]; then
  echo "BŁĄD: ustaw CODESIGN_IDENTITY – wydanie bez podpisu zostanie odrzucone przez updater." >&2
  exit 1
fi

./build.sh release
source Resources/Version.config
VERSION="$MAJOR.$MINOR.$PATCH.$BUILD"
ZIP="build/Vitals-$VERSION.zip"

rm -f "$ZIP"
# ditto zachowuje podpis i uprawnienia – zwykły zip potrafi je zgubić
/usr/bin/ditto -c -k --sequesterRsrc --keepParent build/Vitals.app "$ZIP"
echo "Spakowano: $ZIP"

# kontrola: to, co trafia do wydania, musi mieć ważny podpis
codesign --verify --deep --strict build/Vitals.app
echo "Podpis pakietu OK"

if [ "$PUBLISH" = "1" ]; then
  command -v gh >/dev/null || { echo "BŁĄD: brak narzędzia gh." >&2; exit 1; }
  [ -n "$NOTES" ] || NOTES="Wersja $VERSION"
  gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "Vitals $VERSION" --notes "$NOTES"
  echo "Opublikowano wydanie v$VERSION w $REPO"
else
  echo "Aby opublikować: ./release.sh --publish --notes \"Opis zmian\""
fi
