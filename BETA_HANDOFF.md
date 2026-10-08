# FlowTrace screenshot recall: supervised beta handoff

Use this with scheduled participants in [BETA_STUDY.md](BETA_STUDY.md). It describes an internal test build, not the published download. Do not post the archive as a public release.

## Exact candidate

- Archive: `FlowTrace-0.1.1-build16-ad-hoc-macOS.zip`
- SHA-256: `81f75ee5659a76fae69c14fee9d005039cefabb58809b8656865edafc48a918a`
- Source: merge commit `7a20c58` (PR #17). Its PR head passed 387 local tests, a debug app build, and hosted macOS CI. This exact merge commit passed local app/CLI release bundle checks. Its post-merge `main` check is running as this handoff is prepared.
- Requirement: macOS 14 or later. The archive is ad hoc signed; it is not Developer ID signed or notarized.

The owner should send the exact archive privately to each scheduled participant and record the build ID. The current copy is in `~/Documents/FlowTrace Internal Builds/` on the build Mac. Do not substitute the v0.1.0 GitHub download: that version has no screenshot library.

## Install during the observed session

1. Download the archive the owner sent. Optionally compare its SHA-256 with the value above using `shasum -a 256 <archive path>`.
2. Unzip it, move `FlowTrace.app` to `/Applications`, and open it. Record the exact macOS message if launch is blocked. A participant may try Finder's right-click **Open** once; if the app still cannot open, stop and report the friction. Do not tell participants to disable Gatekeeper or clear quarantine.
3. On first launch, continue without agent transcript sources unless the participant independently wants them. Screenshot recall does not require those sources.
4. Open **Screenshots** in the sidebar. Choose **Import image** or **Paste screenshot**, then search for a word visible in the image or a description the participant adds. The app does not capture the screen in the background.

The observer should let the participant find each action themselves and record any help given. Use their own retrieval clue and [session record](BETA_STUDY.md); do not ask for a copy of their image.

## Privacy, support, and removal

- Images, recognized text, descriptions, and other FlowTrace data stay on the Mac in a local database without encryption. There is no FlowTrace account, sync, or telemetry. The selected agent sources can read local transcript metadata and prompts; leave them off for a screenshot-only session.
- **Settings → What FlowTrace knows → Export… → JSON with images…** saves image bytes with the data. **Markdown text only…** saves text and metadata without image bytes. A copied export needs the same care as the participant's screenshots.
- To remove stored data, use **Settings → What FlowTrace knows → Delete everything…** and follow the app's confirmation. Then quit FlowTrace and move the app to Trash. Do this before removing the app if the participant wants to use its data controls.
- For help, use the scheduled observer or [open a GitHub issue](https://github.com/Fuzailkazi/flowtrace/issues). Include macOS version, build 16, the action, and the exact error. Do not attach private screenshots, exports, or logs without reviewing their contents.

## Stop and report

Stop the session and tell engineering if the app loses an image, exposes data the participant did not choose to save, or cannot open after the one Finder retry. Record the failure in the study sheet. Do not count an assisted demo as an unassisted recovery.

The remaining engineering and public release gates are in [launch-checklist-flowtrace.md](launch-checklist-flowtrace.md).
