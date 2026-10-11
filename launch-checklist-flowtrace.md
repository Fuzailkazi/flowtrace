# FlowTrace observed beta launch checklist

**Launch type:** private, observed beta for Mac developers recovering coding work across agents and repositories. The screenshot build 15 archive is retired from this beta plan. A new candidate must be built from the merged removal revision.

## Before inviting participants

- [ ] Freeze the merged source revision, assign a unique version and build number, and build the app and CLI from that exact revision.
- [ ] Run the full test suite, verify the bundle, and walk through first launch, source consent, Quick Capture, Now, an earlier clean repository, note search, relaunch, JSON export, and Delete everything in a disposable profile.
- [ ] Confirm that the screenshot library, import and paste actions, OCR, and image search are absent. In a profile containing an image saved by an earlier internal build, confirm that JSON export retains it and Delete everything removes it.
- [ ] Check installation and permissions in a clean macOS user account. Record failures and the exact build ID.
- [ ] Recruit 8–10 developers who use several coding agent sessions across multiple repositories. Use [BETA_STUDY.md](BETA_STUDY.md) for the observed session and seven-day follow-up.
- [ ] Prepare install, privacy, support, and deletion instructions for the exact archive participants receive.

## After observed sessions

- [ ] Review time to a useful place, recovery action, note retrieval, misses, trust concerns, and repeat use by build ID.
- [ ] Fix the weakest step in discovery, recovery detail, or search, and update [PRODUCT_AUDIT.md](PRODUCT_AUDIT.md) with contrary evidence.

## Public release gate

- [ ] Obtain a Developer ID Application identity and notarization credentials.
- [ ] Sign with hardened runtime and timestamp, notarize, and verify the final ZIP with `Scripts/verify-public-release.sh`.
- [ ] Install that exact ZIP in a clean account without a quarantine workaround; repeat permissions, recovery, export, and deletion checks.
- [ ] Publish the verified archive and accurate release notes.
