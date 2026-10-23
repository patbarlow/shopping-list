# App icons and media controls

App-owned icons use the MIT-licensed stroke-rounded vectors from `@hugeicons/core-free-icons` 4.3.5. The source paths are preserved in Shared/HugeIcons.xcassets, with template rendering for adaptive foreground colours. The package licence is included in both apps. Aisle emoji remain emoji.

Regenerate with `npm pack @hugeicons/core-free-icons@4.3.5`, extract the archive, then run `node scripts/import-hugeicons.mjs /path/to/package`. Run `xcodegen generate` after adding Swift files or resources.

The four native iOS tabs display only icons, with accessibility labels:

| Tab | Hugeicon |
| --- | --- |
| List | ShoppingCart01Icon |
| Insights | Chart01Icon |
| Price check | SearchDollarIcon |
| Forecast | CalendarClockIcon |

Settings uses Settings01Icon; receipt import uses AddInvoiceIcon, ScanTextIcon, Album01Icon and Folder01Icon. Forecast additions use PlusIcon.

Camera and photos open compact, expandable sheets. The photo grid embeds Apple's private picker, so browsing and selecting a photo does not grant the app access to the whole library. Automatic recent-photo suggestions separately need normal PhotoKit authorization; there is no additional app toggle. Camera capture uses AVFoundation without writing to Photos.

The composer dismiss gesture observes downward drags that begin within the input area, including UIKit text fields. The List's upward-swipe gesture uses global coordinates so movement of the composer while dismissing the keyboard cannot reverse the gesture and reopen it.

## Local checks

Use the `Shopping List` scheme's ReceiptTests and PriceCheckUITests targets. The UI tests replace networking with deterministic fixtures. Photo-selection tests need at least one image in the simulator photo library; the standard simulator samples work. The local acceptance run also seeded the supplied Red Bull screenshot with `xcrun simctl addmedia`.

Camera opening, dismissal and the no-camera fallback can be checked in Simulator. Actual image capture, camera permission behaviour and returning from device interruptions require a physical iPhone.
