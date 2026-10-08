# Decision: Which recovery problem should FlowTrace prove first?

**Status:** Historical proposal from 6 October 2026. The product owner subsequently prioritized screenshot recall; the recommendation below was not adopted for the current source.

## Context

The current macOS app can surface active coding places, browse recent Claude Code and Codex places, recover local Git and agent context, and find notes the user wrote. At the time of this proposal, it could not capture or retrieve screenshots. Current source now includes deliberate paste/import, local OCR, search, detail, and deletion. The published v0.1.0 and earlier build 13 do not include that flow. Earlier strategy notes name screenshot memory as core, while the current README and app lead with recovering coding work across agents and repositories. Shipping both messages would make the first beta hard to interpret: success on one job would not validate the other.

Claude Code already resumes known sessions through its [CLI](https://docs.anthropic.com/en/docs/claude-code/cli-usage), and the [Codex app](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex) organizes parallel threads across projects. [Pieces](https://docs.pieces.app/products/desktop) and [screenpipe](https://docs.screenpi.pe/search-screen-history) already offer broad workflow or screen-history retrieval. **Inference:** FlowTrace has the clearest testable opening in *finding which repository and agent context to return to across tools when the user does not know the session to resume*. That advantage is unproven.

## Constraints

- No observed target-user recovery sessions or retention cohort exists yet.
- The current public ZIP needs a Gatekeeper workaround; a Developer ID signed, notarized build is still required for easy broad sharing.
- At the time of the proposal, none of the screenshot loop was implemented. Current source has deliberate screenshot saving and retrieval, with integration and release validation still open.
- The product is local-first and opt-in. Research must not require participants to share transcript contents.

## Options

| Option | Benefit | Cost and risk | Effort | Reversibility |
| --- | --- | --- | --- | --- |
| **A. Prove agent-work recovery first** | Uses the existing product to test one narrow, frequent developer job. A beta can expose failures in discovery, handoff, and return action. | Native agent resume tools may already be sufficient; the original screenshot problem remains unsolved. | Small engineering work plus recruiting, 8–10 observed sessions, and seven-day follow-up. | Easy before a broad launch. |
| **B. Build screenshot memory first** | Tests the original problem directly and could produce a more visual, shareable demonstration. | A partial capture feature without reliable retrieval adds permission and storage cost; larger build delays evidence on the working recovery path. Broad memory competitors already offer screen history. | Large: a complete capture-to-retrieval loop is several product and engineering stages. | Moderate; data model, permissions, and messaging would become commitments. |
| **C. Test both jobs before choosing** | Reduces risk of committing to the wrong problem. | Splits a small beta and delays a clear value proposition; feedback may be too shallow on either job. | Medium research effort; little immediate engineering. | Easy. |

## Original recommendation (superseded)

**Choose A for the next beta, with a fixed evidence gate.** The app is closest to a complete agent-work recovery loop, so this yields the fastest honest test of whether FlowTrace helps someone act on forgotten work. Do not present a clean repository or an agent session as “unfinished” merely because it exists; ask participants to recover a real item and show what they did next. Keep screenshot memory as a serious candidate, and use beta misses involving visual material to decide whether it should become the next complete loop.

## What this gives up

FlowTrace would not immediately solve “find the screenshot I took of that design or error,” despite that being the product's origin. The beta's developer cohort would also say little about designers and researchers who may need visual recall more often.

## Reversibility and decision gate

The sequence can change after the first 8–10 observed sessions, before broad launch messaging hardens. Evidence for A: participants recover a real item, identify the right place without coaching, and take an action to resume; repeat use after seven days matters more than praise. Evidence for B: repeated failures because the missing object was visual, plus willingness to grant explicit screenshot access. If neither job produces a meaningful recovery moment, reconsider the target problem before expanding features.

## Next actions after the owner chooses

1. Recruit the qualified beta cohort and run the script in [BETA_STUDY.md](BETA_STUDY.md), including a clean-repository recovery task.
2. Record misses and time to useful context; fix the weakest step in the chosen loop.
3. Prepare a Developer ID signed and notarized ZIP, then verify installation in a clean macOS user account before broad distribution.

## Decision update, 8 October 2026

The product owner chose screenshot recall. PR #11 merged explicit image paste/import, local OCR, text retrieval, detail, export, and deletion without background screenshots. An isolated UI walkthrough confirmed import, OCR, description, and search; build 14 was created from the merged source, and main CI passed. Paste, export, deletion, relaunch, target-user retrieval, Developer ID signing, notarization, and clean-account installation remain open. The options above document the earlier trade-off rather than the active sequence.
