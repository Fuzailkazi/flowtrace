# Decision: Prove recovery of coding work

**Status:** Decided 11 October 2026. FlowTrace focuses on finding notes and coding work across repositories and agents. Screenshot capture and retrieval are outside the product direction.

## Context

The current macOS app surfaces active coding places, browses recent Claude Code and Codex places, recovers local Git and agent context, and finds notes the user wrote. This is the loop the next beta should test. Its value to users beyond the author remains unproven.

Claude Code already resumes known sessions through its [CLI](https://docs.anthropic.com/en/docs/claude-code/cli-usage), and the [Codex app](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex) organizes parallel threads across projects. **Inference:** FlowTrace has the clearest testable opening in finding which repository and agent context to return to across tools when the user does not know the session to resume.

## Beta decision

Run a small observed beta around one real recovery task per participant. Do not present a clean repository or an agent session as “unfinished” merely because it exists. Ask participants to find a real item and show what they did next.

Recruit 8–10 qualified developers. Record whether each person identifies the right place without coaching, takes an action to resume, and returns after seven days. Improve discovery, recovery detail, or search according to observed misses.

The product remains local-first and opt-in. Research must not require participants to share transcript contents. A Developer ID signed and notarized build is still needed for easy broad sharing.

## Next actions

1. Run the script in [BETA_STUDY.md](BETA_STUDY.md), including a clean-repository recovery task.
2. Record misses and time to useful context; fix the weakest step in the recovery loop.
3. Prepare a Developer ID signed and notarized ZIP, then verify installation in a clean macOS user account before broad distribution.
