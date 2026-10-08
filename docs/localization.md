# Adding and maintaining Vitals languages

The translation catalog is [translations.csv](../Sources/App/Localization/translations.csv).
Language definitions are in [languages.json](../Sources/App/Localization/languages.json).
Both files are bundled with the app. Adding a language does not require a new Swift enum
case or changes to Settings, fonts, locale resolution, or Quick Action discovery.

## Add a language

From the repository root:

    swift run LocalizationTool add-language --code de --name Deutsch

This creates a new CSV column and a draft language definition with a fresh, stable
preference ID. Draft languages are hidden from Settings and system-language detection.
For a script-specific language:

    swift run LocalizationTool add-language --code zh-Hant --name "繁體中文"

The default match is the language code. A script-specific match such as zh-Hans also
matches system locales that infer that script, such as zh-CN and zh-SG, while excluding
zh-Hant and zh-TW. A region-specific match such as pt-BR matches that region. If both
generic and specific entries match the same system preference, the more specific
language wins. Unsupported preferences are skipped in order; the fallback is English.

Fill the new CSV column, including both privacy-description rows. Import the CSV as
UTF-8 with text columns to preserve labels, punctuation and formatting markers.
Use the report command to find unfinished entries:

    swift run LocalizationTool report --code de

When complete:

    swift run LocalizationTool enable-language --code de
    swift run LocalizationTool validate
    swift test -c debug
    NO_BUMP=1 ./build.sh

Enabling fails until every message has a nonempty translation with valid format
parameters and paragraph breaks. A subsequent build automatically adds the language
to the app selector, bundle localizations and localized macOS privacy resources.
There is no need to edit a Swift table or create separate InfoPlist.strings files.

## CSV columns

| Column | Purpose |
| --- | --- |
| id | Stable identifier, for example page.summary or action.show_vitals. Never rename an existing ID when changing wording. |
| en | English text and fallback; also the reference for format validation. |
| pl | Polish text. |
| zh-Hans | Simplified Chinese text. |
| Other language codes | Additional translation columns created by the tool. |
| legacy_key | Historical Polish source key used by existing app code. Keep it unchanged; leave it empty for new messages that use IDs. |

CSV quoting follows RFC 4180: cells containing commas, quotes or line breaks are
quoted, and quotes inside cells are doubled. Multiline descriptions stay in one row.
Blank translations in a draft language fall back to English.

## Add or edit a message

Add a CSV row with a descriptive ID and translations for every enabled language.
New code should use the ID:

    L("page.summary")

Older calls such as L("Podsumowanie") remain compatible through legacy_key.
Editing the Polish translation therefore does not break those call sites.
Strings that are not catalog IDs or legacy keys pass through unchanged, including
process names, device names and technical values.

Preserve formatting parameters such as %@, %d, %.1f and %% as well as paragraph
breaks. To reorder arguments, use positional parameters. For example, an English
format of "%@ has %d files" can become "%2$d Dateien: %1$@" without changing
argument types. Validation rejects missing or mismatched parameters.

The privacy.location_usage and privacy.bluetooth_usage rows are used to generate
NSLocationWhenInUseUsageDescription and NSBluetoothAlwaysUsageDescription in the
base Info.plist and each enabled language's InfoPlist.strings.

## Language metadata

- id is the persisted preference value. IDs 1, 2 and 3 remain reserved for Polish,
  English and Simplified Chinese. The system option uses 0. Never reuse IDs or
  reorder preferences by assigning an existing language a new ID.
- code is the CSV column and bundle locale identifier.
- nativeName is the name shown in the language selector.
- matches lists language/script/region patterns for system preferences. It defaults
  to the language code; the tool also accepts --matches de,de-DE.
- enabled controls whether the language is selectable. Disable an unfinished
  language rather than deleting its historical definition.
- prefersSystemFont selects native system fonts for headings. The tool enables
  this automatically for Chinese, Japanese and Korean; --system-font enables it
  for other languages.
- pluralRule supports oneOther and polish, matching the application's current
  quantity-label forms.
- csvSeparator and decimalComma control numeric history exports. Existing Polish
  headers remain compatible; other languages use stable English column names.

## Validation and packaging

LocalizationTool validates duplicate IDs, legacy aliases, language definitions,
column coverage, missing enabled translations, format parameters and line breaks.
The same reader is used by the app, tests and the tool. CI runs validation and the
packaging script stops on catalog errors.

The app's SwiftPM resource bundle is copied into Contents/Resources. Packaging
derives CFBundleLocalizations and the localized privacy resources from the catalog
before code signing. The development and fallback language stays English.
