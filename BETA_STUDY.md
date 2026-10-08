# FlowTrace screenshot recall beta study

Use this with 8 to 10 people before promoting screenshot recall broadly. The question is whether someone can save a useful image, later find it with a clue they remember, and choose FlowTrace again. An import demo or polite praise does not answer that question.

## Who to invite

Invite Mac users who already save screenshots of errors, designs, research, or work in progress and later struggle to find them. Include developers, but do not require coding agent usage. Record their current storage and search method. Keep people who never need to retrieve screenshots separate from the target cohort.

### Invitation draft

> I'm testing FlowTrace, a local Mac app for finding screenshots by words visible in the image or words you add. Do you save screenshots that you later need to find? I would like to watch a 30 minute first use and follow up after a week. You choose what to import; I will not ask you to send me your images.

## Session script, 30 minutes

1. **Current behavior (5 minutes):** Ask for the last screenshot they had trouble finding. Observe how they would search for it now. Record time, result, and what clue they remembered.
2. **Install and trust (5 minutes):** Give the exact beta ZIP and ask them to narrate first run. Record install friction, source consent choices, and whether the local storage and lack of encryption are clear. Do not ask them to enable agent transcript sources.
3. **Save an image (5 minutes):** Ask them to import or paste a screenshot they are comfortable storing locally. Record whether they find the action, whether OCR finishes or fails, and whether they add a description without coaching. Do not record image contents.
4. **Recover it (10 minutes):** Move away from the image, then ask them to find it using their own imperfect clue. Observe the first query, whether the result appears, whether the opened image is the right one, and whether they would use the result in their work. If time permits, try a second image where the useful clue is not visible text and see whether a description helps. Do not supply search words.
5. **Wrap up (5 minutes):** Ask when they would use this again, what would make them remove it, and whether they understand how to export or delete their images. Record any privacy concerns. If they naturally use agent recovery too, note it separately.

## Record one sheet per participant

```text
Participant code, date, macOS version, and exact app build:
Current screenshot storage and search method:
Last real retrieval task, remembered clue, time, and outcome:
Installed without help? If not, where did it fail:
Sources enabled and why:
Understood local unencrypted storage? Their own words:
Import or paste completed? OCR state and any error:
Description added? Why or why not:
First unprompted search phrase:
Right image at first result, within five, or missed:
Could they reopen and use the full image? What action followed:
Second image with a nonvisible clue, if tried:
Export and deletion expectations or confusion:
Unexpected privacy or trust concern:
Observer interventions:
Exact quotes, with permission:
Would they use it for a week? Why or why not:
```

## Follow up after seven days

Ask whether they saved another image without prompting, retrieved one later, what query they tried, and what they used instead when FlowTrace failed. Record actual repeats rather than stated intention. For people who used it at least twice in the last 14 days, ask how they would feel if they could no longer use it: very disappointed, somewhat disappointed, or not disappointed, and why. A small beta can reveal failures; it cannot establish product market fit.

## Decision rules

- If people cannot find the import or search action, fix the first run and navigation.
- If OCR succeeds but their own clues miss, compare visible text, descriptions, query behavior, and ranking before adding another capture source.
- If the image is found but not useful, inspect detail, copy/export needs, and how they return to the original task.
- If they do not return within a week, test whether screenshot retrieval is frequent enough for this audience.
- Keep misses and contrary quotes. Do not claim semantic or visual similarity search; this release searches recognized text and descriptions.

The current product and release gates are in [PRODUCT_AUDIT.md](PRODUCT_AUDIT.md) and [launch-checklist-flowtrace.md](launch-checklist-flowtrace.md).
