# Trolley for Mac

The Mac product is **Trolley.app**. Its bundle identifier remains
`com.patbarlow.shoppinglist.mac` so renaming it preserves the existing sandbox,
sign-in and preferences. The Xcode target/scheme retains its internal name,
`Shopping List macOS`, to keep existing build automation compatible.

## Build and run against the live service

From this checkout:

```sh
xcodegen generate
xcodebuild -project 'Shopping List.xcodeproj' \
  -scheme 'Shopping List macOS' -configuration Debug \
  -derivedDataPath /tmp/trolley-mac-dev build
open '/tmp/trolley-mac-dev/Build/Products/Debug/Trolley.app'
```

Do not set `TROLLEY_UI_TEST` for a real account session. Debug builds use the
normal production service and existing session. A fresh session uses the same
email-code sign-in as iPhone. Debug builds do not automatically check Sparkle.

The desktop workspace includes List, Insights, Price check, Forecast, Purchase
history and Recipes. Use **⌘1–6** to navigate, **⌘N** to add an item, **⌘I** to
import a receipt, and **⌘,** for Settings. Return submits an item and keeps the
field ready for the next one; Escape cancels editing. Price check accepts image
files, dropped files and pasted images. Receipt import accepts images, text PDFs
and scanned PDFs, with a review step before saving.

## Development builds versus released updates

Version 1.9.0 (204) is a local Mac development build. Creating or running it does
not publish a Sparkle update. The public appcast still points at the released
1.8.0 (200) package until a separate signed, notarized release is published.
The iOS and macOS targets have independent version settings and release paths.
