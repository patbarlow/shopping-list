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

Camera and photos zoom from their initiating control into compact sheets, using the system's device-concentric corners. The photo grid scrolls at its compact height; only All Photos expands it, and Recents restores the compact view. It embeds Apple's privacy-preserving picker, so browsing and selecting a photo does not grant the app access to the whole library. Automatic recent-photo suggestions separately need normal PhotoKit authorization; there is no additional app toggle. Suggestions expire after 30 minutes and disappear once the user starts a different message or attachment, without a close button.

The shared AVFoundation camera serves price photos, receipt scans and recipe imports without writing to Photos. Its ellipsis reveals camera switching, flash mode and document mode. Document mode straightens a confidently detected paper boundary, preserving the whole photo when there is no reliable boundary. Capture, attachment and camera controls provide restrained haptics and respect Reduce Motion for their small animations.

Price check's introduction is fixed in the available space and disappears during composition. Attachment selection focuses the keyboard, and a photo can be sent by itself. The attachment menu has large rows and opens over its circular plus target with no pointer; tapping outside dismisses it while retaining keyboard focus. Photos and camera share a 480-point compact height, with the photo controls inset over the lower corners. Receipt/photo import remains coordinated at the app root so processing survives picker dismissal.

The composer dismiss gesture observes downward drags that begin within the input area, including UIKit text fields. The List's upward-swipe gesture uses global coordinates so movement of the composer while dismissing the keyboard cannot reverse the gesture and reopen it.

Return in the List composer submits the item and keeps the keyboard ready for the next one. Direct actions have light haptic feedback: adding/checking items, collapsing aisles, tab selection, attachment controls, send and reply. Background refreshes do not trigger feedback.

## Local checks

Use the `Shopping List` scheme's ReceiptTests and PriceCheckUITests targets. The UI tests replace networking with deterministic fixtures. Photo-selection tests need at least one image in the simulator photo library; the scrolling test needs at least 12 images so the compact grid has overflow. The local acceptance run seeded the supplied Red Bull screenshot and QA screenshots with `xcrun simctl addmedia`.

Camera opening, dismissal and the no-camera fallback can be checked in Simulator. Actual image capture, camera permission behaviour and returning from device interruptions require a physical iPhone.
