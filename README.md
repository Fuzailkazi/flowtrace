# FlowTrace

**Remember what you were doing. Find it when you forget.**

FlowTrace is a native macOS memory and retrieval tool for your work.

It captures useful context from the things you interact with on your computer, stores it locally, and lets you recover that context later when you no longer remember where something came from.

The goal is simple:

> **You shouldn't have to remember where you saw something in order to find it again.**

---

## Why FlowTrace?

A lot of useful information passes through our computers every day:

- A screenshot of a product or pricing page

- An error message

- A useful AI response

- A piece of code

- A design

- An article

- A browser page

- A terminal session

- An idea or thought

- Something you were working on earlier

We often recognize that something is useful and intend to come back to it.

Then we forget.

We don't remember the exact application, window, URL, project, or time when we saw it.

FlowTrace is designed to preserve enough context that the memory can be recovered later.

---

## The Core Experience

FlowTrace revolves around a simple loop:

```text
See something
     ↓
Remember it
     ↓
FlowTrace captures useful context
     ↓
Continue working
     ↓
Forget where / why
     ↓
Retrieve it
     ↓
Recover the context
```

The ideal outcome is:

**"Thank god FlowTrace remembered that."**

---

## Capture

FlowTrace provides a lightweight Quick Capture experience that lets you save something without leaving the application you're currently using.

There are two capture intentions.

### Remember this

Designed for things you want to visually remember.

The screenshot is the primary memory.

FlowTrace can also capture useful surrounding context such as:

- Application

- Window

- Browser page

- URL

- Project or repository

- Relevant activity

- Agent context when available

You can optionally add a note.

### Take a note

Designed for capturing a thought or piece of information.

The text is the primary memory.

Useful surrounding context is captured automatically, while screenshots remain optional and are off by default.

This distinction keeps capture intentional rather than turning every note into a screenshot.

---

## Memory

FlowTrace treats a saved item as a **Memory**.

A memory can contain multiple types of evidence and context.

For example:

```text
Memory
├── Primary content
│   ├── Screenshot
│   └── Note
│
├── Application context
│   ├── Application
│   └── Window
│
├── Browser context
│   ├── URL
│   └── Page title
│
├── Development context
│   ├── Repository
│   └── Project
│
└── Agent context
    ├── Agent
    ├── Session
    └── Working directory
```

The purpose isn't to build a giant knowledge graph.

It is to preserve enough evidence to reconstruct **what you were looking at and what you were doing**.

---

## Retrieval

Capturing something is only useful if you can find it again.

FlowTrace provides local retrieval through the macOS application and CLI.

You can search for memories using the information you remember.

For example:

```text
"that Stripe pricing screenshot"

"the error I saw yesterday"

"that black keyboard"

"the article about AI agents"

"what was I working on in the terminal?"
```

The more useful context FlowTrace has captured, the less you need to remember yourself.

---

## Product Surfaces

FlowTrace currently has three primary surfaces.

### macOS App

The native macOS application is the primary user experience.

It provides:

- Quick Capture

- Current activity context

- Memory history

- Retrieval and search

- Settings

- Onboarding

### CLI

The `flowtrace` CLI provides a power-user interface for interacting with FlowTrace from the terminal.

This makes FlowTrace useful inside developer workflows and automation.

### Browser Extension

The browser extension acts as a context bridge between browser activity and the native FlowTrace application.

It provides browser-specific information such as pages, URLs, and titles that can become part of a memory.

---

## Architecture

FlowTrace is designed as a local-first macOS application.

```text
                   ┌─────────────────────┐
                   │      macOS App       │
                   │                     │
                   │  Capture / Now /     │
                   │  History / Search    │
                   └──────────┬──────────┘
                              │
                              ▼
                   ┌─────────────────────┐
                   │    FlowTraceCore    │
                   │                     │
                   │ Activity / Context   │
                   │ Capture / Retrieval │
                   │ Privacy / Storage   │
                   └───────┬─────┬───────┘
                           │     │
             ┌─────────────┘     └─────────────┐
             ▼                                 ▼
     ┌───────────────┐                 ┌───────────────┐
     │ SQLite / FTS5 │                 │ Browser       │
     │ Local Memory  │                 │ Extension     │
     └───────────────┘                 └───────────────┘
```

The core logic lives in `FlowTraceCore`, which is shared across the application and CLI.

---

## Local-First

FlowTrace is designed around local data storage.

Memory is stored in a local SQLite database with FTS5-powered search.

This architecture keeps the core experience:

- Fast

- Private

- Available offline

- Independent of a cloud backend

Privacy-sensitive context is processed through the application's privacy and redaction layers before being persisted.

---

## Project Structure

A simplified view of the repository:

```text
FlowTrace/
├── FlowTrace/
│   └── macOS application
│
├── FlowTraceCore/
│   └── shared application logic
│
├── flowtrace/
│   └── CLI
│
├── BrowserExtension/
│   └── browser context bridge
│
├── Tests/
│   └── unit and integration tests
│
└── README.md
```

The exact structure may evolve as the application develops.

---

## Development

FlowTrace is a native macOS project built primarily with Swift and SwiftUI.

The project uses:

- Swift

- SwiftUI

- SQLite

- SQLite FTS5

- macOS APIs

- WebExtension APIs

### Requirements

- macOS

- Xcode

- Swift toolchain

### Build

Open the project in Xcode and build the macOS application normally.

The CLI can be built and run independently using the project's Swift tooling.

### Tests

Run the project's test suite through Xcode or the appropriate Swift Package Manager commands.

The test suite covers core functionality including memory capture, activity tracking, retrieval, storage, and privacy-related behavior.

---

## Design Principles

FlowTrace is built around a few simple principles.

### Capture should be lightweight

Saving something should not interrupt the user's workflow.

### Context should be automatic

Users shouldn't have to manually describe where they were every time they save something.

### Memory should be useful later

The value of a memory comes from being able to recover it after the original context is gone.

### Retrieval should reduce remembering

The user should be able to search using what they remember, rather than reconstructing exactly where something happened.

### Privacy should be fundamental

Computer context can be extremely sensitive. Local storage and controlled data handling are therefore fundamental parts of the architecture.

### Keep the product focused

FlowTrace is about **memory and retrieval**.

It is not intended to become a generic task manager, chat assistant, collaboration platform, or cloud knowledge-management system.

---

## Project Status

FlowTrace is an actively developed macOS application.

The repository contains the native application, shared core, CLI, browser extension, local storage, activity tracking, capture, and retrieval infrastructure.

The product and implementation continue to evolve as the core memory experience is refined.

---

## License

See the repository's license information for details.