# Habit and adoption

An honest read of what FlowTrace's own data says about whether people will use it, written before any of it is built. Uses the Aha-Moment Smallest Loop framework (Ch 4, *Building Rocketships*).

## Verdict: NEEDS_MORE_EVIDENCE on the aha, but the existing data already rules one candidate out

The framework says: find the aha by looking at what the 80–90th percentile of *activated* users actually did. FlowTrace has no activated users. It has one user, the author, and the honest reading is that **he is not activated either**.

That is not a reason to stop. It is a reason not to invent an aha and design a funnel around it. But there is real evidence on the one machine that has run this software for weeks, and it is decisive about one thing.

## The evidence

From the author's live database:

| what | count | what it means |
|---|---|---|
| ambient activity rows | 1,181 | the machine watching, no human effort |
| agent sessions imported | 32 | read from transcripts, no human effort |
| **notes written** | **4** | the human writing. Last one 28 August. |
| **project notes** | **0** | never once used |

And from `flowtrace now` on the same machine, in 0.8 s with no permission granted: **17 places, 11 agents, 8 servers, 7 left running and forgotten.** From `flowtrace scan`: 175 agent sessions across 23 repositories in 0.5 s, with three genuinely abandoned pieces of work surfaced and correctly described.

Two loops exist in this product, and the data separates them cleanly.

### Loop A — "capture why" · costs the user a sentence

Press a key, type why you are here, it lands on the timeline. This is the loop the app is designed around, the one the README leads with, and the one every sub-project so far has improved.

**It has not formed as a habit in ~2 weeks on the author's own machine.** Four notes, none in the last week, zero project notes.

The reason is structural, not a bug: the cost is **now** (interrupt yourself, compose a sentence), the benefit is **later** and **probabilistic** (you might come back to this tab; you might not). That is the canonical shape of a habit that does not form. Every capture is a small act of faith that the future you will care.

The recent work is not wasted — before sub-project A, a second note *overwrote the first*, so the loop was actively broken and no habit could have formed. But fixing it does not change the cost/benefit shape.

### Loop B — "see what you forgot" · costs the user nothing

Open the app (or run `flowtrace now`). See eleven agents, seven of them idle for days, and eight servers holding ports. Recognise something you had genuinely lost.

**This loop is already populated, entirely without the user writing anything.** 1,181 ambient rows and 32 imported sessions are the raw material, and they accumulate whether or not the human participates. The cost is zero, the benefit is immediate, and — critically — the *surprise* is the payoff. "Seven left running and forgotten" is information you did not have and would not have got another way.

## The finding

**The morning ritual the owner describes is Loop B, and it needs no notes at all.**

> "They start their day with FlowTrace, come and see what they were doing, etc., and then they go back and continue the work."

Read that again against the data. Nothing in it requires a note to have been written. It requires the app to *tell you* what you were doing — which it can already do, from agent transcripts and git state, for free.

So the aha candidate with evidence behind it is:

> **The user sees a piece of their own work they had forgotten, and acts on it.**

Not "the user captures why." Capturing why is the *deepening* behaviour that makes Loop B better over time, and it belongs after the habit exists, not before it.

This inverts the current build order. Every sub-project so far — Smart Capture, A (capture lands where you pressed the key), A2 (a capture knows its place) — improves Loop A. They are all correct work on the wrong loop for *adoption*. They matter enormously for retention, once someone is already opening the app daily.

## The smallest loop, as the evidence supports it

1. **Install, open.** No account, no permission, no configuration. `LiveStateReader` needs none — this is FlowTrace's single biggest structural advantage and the current onboarding throws it away by opening on a consent screen. *Budget: 60 seconds, install included.*
2. **See your own machine, described in your own terms.** Places, not processes. "`tulu` — agent idle 4d, server on :3000." *Budget: instant. This is the aha.*
3. **Recognise one thing you had lost.** The system has to make at least one row *surprising*. On the author's machine, seven candidates existed on the first run.
4. **Act on it** — open the repo, kill the server, or (the natural entry to Loop A) say what it was for. *The action closes the loop and creates the note as a byproduct rather than a chore.*

That loop is end-to-end (it produces a real outcome), repeatable (tomorrow's answer differs because the machine moved), and self-sustaining (acting on one forgotten thing makes you want to check tomorrow). Loop A on its own is none of those three.

## What this says about sticky notes

The idea as stated — "people can add sticky notes in that place" — is **Loop A again**, in a new location. Same cost/benefit shape, same reason it will not form as a habit on its own. Zero project notes on the author's machine is the direct precedent: a free-text field attached to a place, which he built, and never used once.

That does not kill it. It relocates it. Two versions:

- **Sticky note as something you write.** A blank box on a place. Expect it to be used approximately as often as project notes are: never. Do not build this as an adoption feature.
- **Sticky note as something you find and confirm.** The place already knows: the agent's last prompt, the branch, the uncommitted files, when it went quiet. A note that arrives *pre-filled* with "was: add refresh token rotation · 15 uncommitted · stopped 38d ago" and asks only for a correction is a fundamentally different act — editing beats authoring, which is exactly the insight Smart Capture already encodes and which the audit found to be the app's own best pattern (`ProposalCard`'s "Edit first").

The second version is worth building. It is also nearly free, because `BriefBuilder` and `AbandonedWorkDetector` already produce that sentence — `flowtrace scan` prints it today.

## Acceptance criteria

Numbers to hold ourselves to, before deciding this works:

- **Time to aha (median): under 2 minutes from download**, install included. Currently unmeasurable — there is no download (audit item 0.7), and first run opens on consent rather than on the machine.
- **Activation: 80% of first runs surface at least one genuinely forgotten thing.** Testable *today* against real machines, without shipping anything: run `flowtrace scan` on five developers' laptops and count how many are surprised. If it is not most of them, the aha is wrong and everything else is premature.
- **Repeat within 7 days: 40% of first-run users open it again.** This is the number that matters and the one the current design has no answer for. Nothing brings you back — no notification, no menu bar count, no reason to look.
- **Loop A follow-on: 25% of activated users write their first note within a week.** Notes as a consequence of the habit, measured separately, never conflated with activation.

## Free tier

Trivially sound: the whole thing is MIT-licensed and local. Nothing is gated, nothing phones home, there is no account. Worth stating because it is a genuine advantage — the aha loop is complete and free forever by construction, which the framework treats as non-negotiable and most products have to work at.

## What to do next, in order

1. **Test the aha on five machines before building anything.** `flowtrace scan` already runs from source. Watch five developers who run coding agents read its output. Count: did it surface something they had forgotten? That is a day of work and it either validates the aha or saves months. This is the framework's own prescribed step when there are no activated users, and it is skipped at your peril.
2. **Give the habit a reason to recur.** The audit's Tier 2.6 (menu bar as mini-Now, with the forgotten count in the label) is the single highest-leverage retention item in the whole roadmap and it is currently ranked as polish. An amber "7" in your menu bar is a standing, passive, zero-cost invitation to open the app. Nothing else in the product creates a reason to come back.
3. **Reorder the first run around Loop B.** Onboarding currently opens on "You start things and don't finish them" and a consent screen, and lands the user on a view never mentioned. It should open on their own machine — which needs no permission — and let consent follow the aha rather than precede it. That is audit item 0.5, and this analysis raises its priority above the capture work.
4. **Then sticky notes, as the confirm-don't-author version.**
5. **Keep finishing the launch blockers** (B: nothing read before consent; C: redaction). Those are not adoption work, they are "does not embarrass or violate anyone" work, and they gate any public launch regardless of what the aha turns out to be.

## The uncomfortable part

The strongest signal in this document is that the author, who built it, does not use the feature it is designed around. That is not a criticism of the app — it is the most valuable piece of user research available, and it was free.

Treat it as such. If Loop A had been working, there would be hundreds of notes in that database.

## Analogous case

Dropbox's aha was not "store a file" — it was **install on a second device and watch a file appear**. The user does nothing but observe; the system produces the surprise. The file-saving habit follows the moment of belief, not the other way round.

FlowTrace's equivalent is "open it and see the seven things you forgot were running." The notes are the file-saving habit. They come second.
