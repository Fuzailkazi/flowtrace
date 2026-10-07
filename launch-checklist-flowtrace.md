# FlowTrace observed beta launch checklist

**Launch type:** private, observed beta for 8–10 Mac developers using several coding-agent sessions across at least two repositories. **Date:** TBD after the product owner chooses the first problem to prove. **Public release:** separate gate.

**Current internal candidate:** `/tmp/flowtrace-beta-frozen-21a805b.uEUQm5/dist/FlowTrace-0.1.1-build13-macOS.zip` (SHA-256 `98f43627cb713bf659f25ccc905aa7d8fc2c847b36bb213b9bc0e5fb3c329e88`). It contains an ad-hoc signed app with bundle version `0.1.1` and build number `13`, built from a clean export of merge commit `21a805b` on `main`. That exact source passed 377 tests and debug/release app builds; the release bundler also built the CLI. The extracted ZIP passed plist and signature-integrity checks, has the production bundle ID, and contains no debug support-directory key. `verify-public-release.sh` correctly rejected it for lacking a Developer ID signature, and macOS Gatekeeper rejected the extracted app. **This is a reproducible internal artifact, not yet a participant-ready or public download.**

Build 13 includes the merged recorder Stop/restart write gate from PR #8. Build 12 remains at `/tmp/flowtrace-beta-frozen-86108a/dist/FlowTrace-0.1.1-build12-macOS.zip` (SHA-256 `4785b1fd36eb3b09987bf8144557ea1113d9ac9f32c1ac3f786e5bd497dcbf15`) as the previous verified internal candidate. It includes the merged recovery-beta preparation, CI workflow, fast editor capture wait, and corrected place-specific capture destination.

Earlier ad-hoc candidates were built from a dirty working tree. Builds 3 through 13 came from committed source. Build 13 excludes a pre-existing clickable-title edit still present in the primary working tree; that separate edit is not in this archive.

## Before inviting participants (T-2w to T-1d)

### Product and engineering

- [ ] Choose the beta's primary recovery job from [PRODUCT_DIRECTION_DECISION.md](PRODUCT_DIRECTION_DECISION.md). — **Owner:** Product owner — **Blocking:** Yes — **Due:** T-2w
- [x] Freeze a reviewable source revision and assign a unique beta version and build number; rebuild the archive from that exact revision. Commit `21a805b`, 0.1.1 build 13. — **Owner:** Engineering — **Blocking:** Yes — **Due:** T-1w
- [x] Run the full test suite, debug/release app builds, release CLI build, and extracted-archive integrity checks on the frozen revision. — **Owner:** Engineering — **Blocking:** Yes — **Due:** T-1w
- [ ] Run a fresh-profile capture → search → recovery walkthrough on the exact build 13 release app. — **Owner:** Engineering — **Blocking:** Yes — **Due:** T-1w
- [ ] Check a clean macOS user account for first launch, source consent, shortcut, history scan including a clean repository, handoff, relaunch, export, and delete. Record failures. — **Owner:** Engineering — **Blocking:** Yes — **Due:** T-1w
- [ ] Decide the install route: use a Developer ID signed and notarized ZIP for unassisted installs; if an observed technical beta uses ad-hoc signing, disclose the extra macOS opening step and record it as install friction. — **Owner:** Product owner + Engineering — **Blocking:** Yes — **Due:** T-1w
- [ ] Keep the previous tested archive and a copy of the new release notes for rollback; do not overwrite the existing GitHub v0.1.0 asset. — **Owner:** Engineering — **Blocking:** Yes — **Due:** T-1d

### Research, documentation, and support

- [ ] Recruit 8–10 qualified developers who did not watch FlowTrace being built; confirm their macOS version, agent tools, and repository count without requesting transcripts. — **Owner:** Product owner — **Blocking:** Yes — **Due:** T-1w
- [ ] Use [BETA_STUDY.md](BETA_STUDY.md) to schedule a 30-minute observed first run and a seven-day follow-up; assign anonymous participant codes. — **Owner:** Research observer — **Blocking:** Yes — **Due:** T-1w
- [ ] Give participants truthful install, privacy, export, and deletion instructions that match the exact beta archive. — **Owner:** Product owner — **Blocking:** Yes — **Due:** T-1d
- [ ] Prepare one support path for install or data-read failures, plus a way to report a miss without copying transcript text. — **Owner:** Product owner — **Blocking:** Yes — **Due:** T-1d
- [ ] Draft a short private invitation naming the chosen recovery job and 30-minute study commitment; the draft in [BETA_STUDY.md](BETA_STUDY.md) is the starting point. — **Owner:** Product owner — **Blocking:** No — **Due:** T-1w

## Session day (T-0)

- [ ] Send the exact frozen archive and its checksum only to scheduled participants; record build ID per person. — **Owner:** Research observer — **Blocking:** Yes
- [ ] Observe install and source choice without coaching unless stuck; log each intervention and Gatekeeper prompt. — **Owner:** Research observer — **Blocking:** Yes
- [ ] Ask for one real recovery and one clean-repository or stopped-agent example; record whether the participant resumed work. — **Owner:** Research observer — **Blocking:** Yes
- [ ] Ask the participant to capture a useful note and later search using their own words. Log misses and confusing result labels. — **Owner:** Research observer — **Blocking:** Yes
- [ ] Triage crashes, privacy surprises, and data-loss reports the same day; pause further sessions if any of these appear. — **Owner:** Engineering + Product owner — **Blocking:** Yes

## After sessions (T+1d to T+2w)

- [ ] Review install completion, time to first useful place, recovery action, note retrieval, and every failure by build ID. — **Owner:** Product owner — **Due:** T+1d
- [ ] Follow up after seven days about actual repeat recovery and alternatives used when FlowTrace failed. — **Owner:** Research observer — **Due:** T+1w
- [ ] Decide whether to fix discovery, recovery detail, search, or the target problem itself before adding screenshot capture. — **Owner:** Product owner + Engineering — **Due:** T+1w
- [ ] Update [PRODUCT_AUDIT.md](PRODUCT_AUDIT.md) with observed evidence, including contrary quotes, and revise the next build's exit gate. — **Owner:** Product owner — **Due:** T+2w

## Public-sharing gate

- [ ] Obtain a Developer ID Application identity and notarization credentials. — **Owner:** Product owner — **Blocking:** Yes for public sharing
- [ ] Developer ID sign with hardened runtime and timestamp, run `Scripts/notarize-release.sh` with a configured keychain profile, and test its verified `-notarized.zip` output. — **Owner:** Engineering — **Blocking:** Yes for public sharing
- [ ] Install the exact ZIP in a clean account without a quarantine-removal command, then repeat permissions, capture, recovery, export, and deletion checks. — **Owner:** Engineering — **Blocking:** Yes for public sharing
- [ ] Publish release notes and download instructions only after the public gate passes. — **Owner:** Product owner — **Blocking:** Yes for public sharing

## Handoff

| Stakeholder | What they need | When | Owner | Status |
| --- | --- | --- | --- | --- |
| Product owner | Choose the beta recovery job, invite the cohort, and decide the install route. | T-2w to T-1w | Product owner | Open |
| Engineering | Frozen revision, unique build ID, clean-account results, and archive checksum. | T-1w | Engineering | Open |
| Research observer | Exact build, session script, privacy boundaries, and failure log. | T-1d | Product owner | Open |
| Beta participant | Honest install instructions, source choices, and support path. | T-0 | Research observer | Open |
