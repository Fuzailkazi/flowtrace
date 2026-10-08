# Screenshot recall design

## Promise and scope

FlowTrace lets someone deliberately save a screenshot and find it later using words visible in the image or words they add. The first release supports pasting an image from the clipboard and importing a local image. It does not record the screen in the background. The existing agent recovery tools remain available.

## User flow

The Screenshots surface offers **Paste screenshot** and **Import image**. After choosing an image, FlowTrace runs Apple's Vision text recognition locally, stores a compressed image and recognized text on this Mac, and shows a success or error state. OCR failure must not discard the image: the person can still name it and search their own description. A search box finds screenshots by recognized text and added description. Selecting a result opens the full image, recognized text, creation time, and a delete action.

## Architecture and data

A `screenshotMemory` SQLite table owns identity, import time (not the source image's creation time), description, OCR text/status, image MIME type, and image bytes. Keeping bytes in the database makes save and deletion atomic and lets existing full-data deletion clear images. A new FTS index kind makes screenshot text searchable alongside other FlowTrace records, and global results open the corresponding image. The Screenshots search field keeps local query state so it does not invoke the app-wide search overlay. The gallery loads metadata in pages, with bounded thumbnail decode/cache; it reads full image bytes only for selected detail. The Screenshot library performs bounded image conversion and OCR off the main thread, then writes through the Store. The UI never uploads the image or OCR text. Input byte count and decoded pixel count are bounded before full rasterization; output bytes are bounded too. JPEG conversion strips source metadata, including location, and flattens transparency.

JSON export includes screenshots and image bytes. Markdown export queries screenshot metadata without loading blobs, lists recognized text, and explains that the images themselves require JSON export. Large JSON export must not block the UI while encoding and writing. The UI must state that local storage is not encrypted. A failed OCR pass remains visible and retryable, rather than claiming the image contains no text. Description edits and OCR retry update the search index. Settings holdings counts screenshots and does not claim an empty store while they exist.

## Failure and verification

Reject missing, unreadable, or oversized images with an actionable message. Limit stored images to a practical size and convert to JPEG before storage. Search and deletion must work after relaunch. Test storage, retrieval, search, export, deletion, and migrations on a disposable database; run the full suite and app/CLI builds. Inspect a fresh isolated UI profile with a synthetic screenshot before proposing a release archive. Developer ID signing and notarization remain separate public release gates.
