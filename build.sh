#!/bin/zsh
# Buduje aplikację i składa bundle build/Vitals.app
set -e
cd "$(dirname "$0")"
CONFIG=${1:-release}
# Identyfikator zespołu z certyfikatu (OU) – wstawiany do reguł podpisu SMJobBless
TEAMID="NOTEAM"
if [ -n "$CODESIGN_IDENTITY" ]; then
  TEAMID=$(security find-certificate -c "$CODESIGN_IDENTITY" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')
  [ -z "$TEAMID" ] && TEAMID="NOTEAM"
fi
# --- wersjonowanie: MAJOR.MINOR.PATCH.BUILD, numer kompilacji rośnie przy każdym budowaniu
VERSION_FILE="Resources/Version.config"
source "$VERSION_FILE"
if [ "$NO_BUMP" != "1" ]; then
  BUILD=$((BUILD + 1))
  cat > "$VERSION_FILE" <<EOV
# Wersja aplikacji. MAJOR/MINOR/PATCH zmieniamy ręcznie,
# BUILD jest inkrementowany automatycznie przy każdym budowaniu (build.sh).
MAJOR=$MAJOR
MINOR=$MINOR
PATCH=$PATCH
BUILD=$BUILD
EOV
fi
SHORT_VERSION="$MAJOR.$MINOR.$PATCH"
FULL_VERSION="$SHORT_VERSION.$BUILD"
BUILD_DATE=$(date "+%Y-%m-%d %H:%M")
echo "Wersja: $FULL_VERSION"

mkdir -p Resources/gen Sources/HelperKit
# Wygenerowana stała wersji – widzi ją aplikacja i pomocnik (wspólny moduł HelperKit)
cat > Sources/HelperKit/Version.swift <<EOV
// Version.swift - PLIK GENEROWANY przez build.sh, nie edytować ręcznie.
import Foundation

public enum AppVersion {
    public static let major = $MAJOR
    public static let minor = $MINOR
    public static let patch = $PATCH
    public static let build = $BUILD
    /// „1.1.0” – wersja widoczna dla użytkownika
    public static let short = "$SHORT_VERSION"
    /// „1.1.0.123” – wersja z numerem kompilacji
    public static let full = "$FULL_VERSION"
    public static let buildDate = "$BUILD_DATE"
}
EOV
sed -e "s/@TEAMID@/$TEAMID/g" -e "s/@SHORT_VERSION@/$SHORT_VERSION/g" -e "s/@BUILD@/$BUILD/g" Resources/Helper-Info.plist.in > Resources/gen/Helper-Info.plist
sed -e "s/@TEAMID@/$TEAMID/g" -e "s/@SHORT_VERSION@/$SHORT_VERSION/g" -e "s/@BUILD@/$BUILD/g" Resources/Info.plist.in > Resources/gen/Info.plist
if ! swift build -c "$CONFIG" 2>&1 | grep -vE '^\[|warning: unsafeFlags'; then :; fi
# błąd kompilacji musi przerwać pakowanie, inaczej powstaje paczka ze starą binarką
if ! swift build -c "$CONFIG" >/dev/null 2>&1; then
    echo "BŁĄD: kompilacja nie powiodła się – pakiet nie został zbudowany." >&2
    swift build -c "$CONFIG" 2>&1 | grep -E "error:" | head -20 >&2
    exit 1
fi
BIN=$(swift build -c "$CONFIG" --show-bin-path)
APP="build/Vitals.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Vitals" "$APP/Contents/MacOS/"
cp "$BIN/VitalsHelper" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Library/LaunchServices"
cp Resources/online.equishow.vitals.helper.plist "$APP/Contents/Library/LaunchDaemons/"
# SMJobBless: pomocnik pod nazwą etykiety w Contents/Library/LaunchServices
cp "$BIN/VitalsHelper" "$APP/Contents/Library/LaunchServices/online.equishow.vitals.helper"
cp Resources/gen/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Podpis: ustaw CODESIGN_IDENTITY="Apple Development: Imię Nazwisko (TEAMID)" aby pomocnik w tle (SMAppService) mógł być zatwierdzony.
# Bez certyfikatu pakiet dostaje podpis ad-hoc (aplikacja działa, ale macOS odrzuci rejestrację LaunchDaemon).
ID="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$ID" --identifier online.equishow.vitals.helper "$APP/Contents/MacOS/VitalsHelper" >/dev/null 2>&1 || true
codesign --force --sign "$ID" --identifier online.equishow.vitals.helper "$APP/Contents/Library/LaunchServices/online.equishow.vitals.helper" >/dev/null 2>&1 || true
codesign --force --sign "$ID" --identifier online.equishow.vitals "$APP" >/dev/null 2>&1 || true
[ "$ID" = "-" ] && echo "Podpis ad-hoc (brak CODESIGN_IDENTITY) – pomocnik w tle wymaga certyfikatu Apple Development." || echo "Podpisano: $ID"
echo "Gotowe: $APP ($FULL_VERSION)"
