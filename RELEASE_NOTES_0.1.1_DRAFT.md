# Draft release notes: FlowTrace v0.1.1

**Do not publish yet.** Replace this header only after a Developer ID signed, notarized archive passes the public verifier and a clean-account install. The current build 16 archive is an ad hoc signed internal beta.

## New: find screenshots you chose to save

Open **Screenshots** to import an image or paste one from the clipboard. FlowTrace recognizes visible text on your Mac, lets you add a description, and searches those words when you need the image later. Open a result to view the full image, edit its description, retry text recognition if it failed, or delete it.

Screenshots are saved only when you choose **Import image** or **Paste screenshot**. FlowTrace does not capture the screen in the background. **Quick Capture** saves a note with available app or browser context; it does not take a screenshot.

## Your data

Screenshot images, recognized text, and descriptions stay in FlowTrace's local database without encryption. No account or cloud sync is required. In **Settings → What FlowTrace knows**, **JSON with images…** exports recoverable image bytes; **Markdown text only…** exports text and metadata without image bytes. You can delete one screenshot from its detail view or use **Delete everything…** to remove all stored FlowTrace data.

Search uses recognized text and descriptions. It does not understand the visual meaning of an image or search images by similarity.

## Install and feedback

After the signed release is ready, download its macOS ZIP, unzip it, move `FlowTrace.app` to `/Applications`, and open it. macOS 14 or later is required. If you have trouble importing or finding an image, [report an issue](https://github.com/Fuzailkazi/flowtrace/issues) with the app build and macOS version; review attachments before sharing private images or exports.
