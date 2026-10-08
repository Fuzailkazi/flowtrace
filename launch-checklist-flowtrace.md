# FlowTrace screenshot recall launch checklist

**Launch type:** observed beta first, then public Mac release. **Target audience:** Mac users who save screenshots and later need to find them. **Target date:** after the release gates below pass. **Owner:** product owner, with engineering where named.

## Current candidate and evidence

- Screenshot recall merged into `main` in [PR #11](https://github.com/Fuzailkazi/flowtrace/pull/11), merge commit `7e1ec7ba478a80dfdd51b8690d1f1d2fe4d018f7`.
- The PR head passed 387 local tests plus debug and release builds. The exact merge commit passed [hosted macOS CI](https://github.com/Fuzailkazi/flowtrace/actions/runs/37735868486) and a local release bundle build.
- An isolated debug app imported a synthetic PNG, recognized `ORBITAL BANANA 4821` locally, displayed the full image and OCR text, saved a description, returned the image for `ORBITAL`, and counted it in Settings. Agent transcript sources remained off. This does not prove paste, export, delete, relaunch, or a fresh account through the UI.
- Internal archive on the build Mac: `~/Documents/FlowTrace Internal Builds/FlowTrace-0.1.1-build14-ad-hoc-macOS.zip`. SHA-256: `5cc5af684bc63c2cbed23b16f13667ae2fc212f969e5ab12fc6e0d366209d216`. It is ad hoc signed and is not a public download. The published v0.1.0 does not contain screenshots.

## Before the observed beta (T-1 week to T-1 day)

- [x] Freeze source, run tests and builds, verify the versioned internal archive. **Owner:** Engineering. **Blocking:** Yes.
- [ ] Run paste, OCR failure and retry, JSON image export, Markdown text export, individual deletion, Delete everything, and relaunch through a disposable UI profile. Record results against build 14 or a newer exact source build. **Owner:** Engineering. **Blocking:** Yes for an unobserved beta.
- [ ] Test first launch, privacy wording, import, search, export, and deletion in a clean macOS account. **Owner:** Engineering. **Blocking:** Yes for public sharing.
- [ ] Recruit 8 to 10 target users who were not involved in building the app; record their current screenshot retrieval method without collecting their images. **Owner:** Product owner. **Blocking:** Yes for the observed beta.
- [ ] Schedule a 30 minute first run and seven day follow up using [BETA_STUDY.md](BETA_STUDY.md). **Owner:** Product owner. **Blocking:** Yes for the observed beta.
- [ ] Prepare install, privacy, support, and data deletion instructions for the exact archive participants receive. **Owner:** Product owner. **Blocking:** Yes.
- [ ] Keep the current public v0.1.0 asset intact as rollback and draft release notes that distinguish deliberate screenshot saving from background capture. **Owner:** Engineering and product owner. **Blocking:** Yes.

## Session day (T-0)

- [ ] Provide the exact candidate and checksum to scheduled participants; record build ID and any install help. **Owner:** Product owner. **Blocking:** Yes.
- [ ] Observe a real screenshot import or paste and an unprompted later search with the participant's own clue. Record first result, top five, miss, and whether the opened image was useful. **Owner:** Research observer. **Blocking:** Yes.
- [ ] Record trust surprises, OCR failures, privacy concerns, and any data loss. Stop further sessions if data loss or an undisclosed read occurs. **Owner:** Product owner and engineering. **Blocking:** Yes.

## First two weeks after beta

- [ ] Review install completion, time to first useful retrieval, misses, and repeat use by build. **Owner:** Product owner. **Due:** T+1 day and T+1 week.
- [ ] Follow up after seven days to learn what people actually retrieved and what they used instead. **Owner:** Research observer. **Due:** T+1 week.
- [ ] Fix the weakest observed step before broadening capture or claiming semantic search. Update [PRODUCT_AUDIT.md](PRODUCT_AUDIT.md) with both successes and failures. **Owner:** Engineering and product owner. **Due:** T+2 weeks.

## Public release gate

- [ ] Obtain a Developer ID Application identity and notarization credentials. No valid signing identity was present on this Mac at the build 14 check. **Owner:** Product owner. **Blocking:** Yes.
- [ ] Rebuild from a frozen commit with Developer ID signing, hardened runtime, and timestamp; run `Scripts/notarize-release.sh` and verify the stapled ZIP. **Owner:** Engineering. **Blocking:** Yes.
- [ ] Download and open that exact ZIP in a clean Mac account without a quarantine workaround. Check first run, permissions, screenshot recovery, relaunch, export, and deletion. **Owner:** Engineering. **Blocking:** Yes.
- [ ] Publish the verified archive and accurate release notes; then invite broader users. **Owner:** Product owner. **Blocking:** Yes.

An ad hoc signed internal build can support a supervised technical study with clear install instructions. It should not be presented as a frictionless public release.
