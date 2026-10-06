# FlowTrace beta study

Use this with a small group before promoting FlowTrace broadly. The aim is to learn whether a developer can recover real work and wants to return. Do not treat installing the app, finishing setup, or polite praise as success.

## Who to invite

Invite 8 to 10 Mac developers who had at least three coding agent sessions across at least two repositories in the past week. Prefer people who have not watched FlowTrace being built. Record the agent tools they actually use, because Claude Code and Codex support more history than OpenCode in the current app. A participant who does not fit this group can still give usability feedback, but keep that result separate from the main cohort.

### Invitation draft

> I'm testing FlowTrace, a local Mac app that helps you find coding work left across agents and repositories. I'm looking for developers who used at least three coding agent sessions across two or more repositories last week. Would you spend 30 minutes trying it on your own Mac while I observe? You can choose which local sources it may read, and I won't ask to copy your transcripts. I'm looking for confusing or disappointing moments as much as useful ones.

## Session script, 30 minutes

1. **Before showing FlowTrace (5 minutes):** “Tell me about the last time you had to reconstruct what an agent was doing. Show me how you found it, if you still can.” Record the tools, time, and whether they succeeded. Do not suggest a workaround.
2. **Install and first run (5 minutes):** Give the participant the release ZIP and ask them to say aloud what they expect each screen to do. Let them choose their own permissions. Record install failures, trust concerns, confusing terms, and time to Now. Help only if they are truly stuck; record every intervention.
3. **Real recovery (10 minutes):** “Find a piece of coding work you left open or stopped, and show me what you would do next.” Observe whether Now identifies the right repository and whether its place detail says enough to act. Ask for a second example whose repository is clean or whose agent has stopped; let the participant discover “From earlier sessions.” Record whether the recent-places list found it, whether the detail was actionable, and what remained missing.
4. **Memory retrieval (5 minutes):** Ask them to save one useful note in their normal workflow, then find it in Memories. Use the words they naturally type. Do not provide a suggested search phrase.
5. **Wrap up (5 minutes):** “What would you use this for tomorrow? What would make you remove it? What information would you not let it read?” Ask whether they would use it for a week. Do not ask whether they “like the idea.”

## Record one sheet per participant

```text
Participant code:
Date and app build:
Agent tools and number of active/recent sessions:
Number of repositories touched last week:
Existing recovery method and time cost:
Installed without help? If not, where did it fail:
Sources they enabled and why:
Time from launch to Now:
Time to first useful recovery result:
What they tried to recover (their own words, no transcript copy):
Was the right place found? Was the context actionable?
Did they actually resume work? What action?
Scan used? Result useful? False positives?
Any expected session missing or source-read warning shown? Which source?
Clean repository or stopped-agent example found? Could they resume it?
Note captured and found later? Search phrase and failure mode:
Unexpected privacy or trust concern:
Observer interventions:
Five or more exact quotes, with permission:
Would they use it for a week? Why or why not?
```

## Follow up after seven days

Ask what they actually reopened or recovered using FlowTrace, how often, and what they used instead when it failed. If they used it at least twice in the last 14 days, ask: “How would you feel if you could no longer use FlowTrace?” Record “very disappointed,” “somewhat disappointed,” or “not disappointed,” then ask why. Do not infer product market fit from fewer than roughly 40 active respondents; this first cohort is for finding the loop and failures.

## Decision rules for the next build

- If users cannot find a real place, fix detection, ranking, and labels before adding more capture types.
- If they find a place but cannot resume, improve the detail and return action; inspect their missing context.
- If they recover work but never return, test whether the problem happens often enough and whether the app is present at the right moment.
- If visual material is repeatedly the thing they cannot recover, test screenshot capture plus OCR and retrieval as a complete loop.
- Keep every failure and contrary quote. A successful beta is a clear decision about what to build, even if the current experience fails.

The current technical and product gaps are in [PRODUCT_AUDIT.md](PRODUCT_AUDIT.md).
