# Live detection for OpenCode, Antigravity, and Cursor

## Goal

Show OpenCode, Cursor, and Antigravity as live coding agents in FlowTrace, associated with the project each process is working in. This extends the existing live process view; it does not import chat history or read transcripts.

## Current behavior

`LiveStateReader` discovers exact process names with `pgrep`, resolves process working directories with a batched `lsof`, groups agents by project, and reads only the allowed source's transcript metadata. OpenCode is already included in process census and live process discovery, and `TranscriptIndex` can read OpenCode's local SQLite session metadata when OpenCode access is enabled. `AgentName` has Cursor and OpenCode values but no Antigravity value. Cursor also has editor-window state support in `EditorPlace`, but that is a separate focused-window feature and is not the source of this live identification behavior.

## Design

Extend the process discovery list to include the executable process names used by Cursor and Antigravity desktop apps. Add an Antigravity `AgentName` case and labels, then classify discovered process names deterministically. Retain the existing project association path: use the process working directory, resolve a repository root with `GitProbe`, and group duplicate processes of the same agent under that place.

OpenCode continues using its existing identification and optional activity metadata. Cursor and Antigravity are identified from process and working-directory data only in this change. No transcript, prompt, or conversation content is read for either. If FlowTrace cannot resolve a process working directory, it omits that process instead of assigning a guessed project.

## Privacy and permissions

Process discovery and working-directory inspection remain the only new data source. They use the existing `pgrep` and `lsof` pattern. Existing transcript consent remains unchanged; no additional folders or files are read for Cursor or Antigravity.

## Failure behavior

Unknown process names are ignored. If the target application is running but process inspection cannot resolve a working directory, it does not produce a project row. Existing behavior for Claude Code, Codex, OpenCode, servers, project grouping, and user consent remains intact.

## Verification

Add focused coverage for process-name-to-agent classification and exercise census discovery names without requiring the apps to be installed. Build the macOS app and manually check that available processes appear with the expected agent label and project association. No conversation-history import is part of acceptance.

## Out of scope

- Importing Cursor or Antigravity conversation history.
- Reading Cursor editor state to infer a focused project for the live-agent list.
- Changing OpenCode transcript/activity consent or storage discovery.
- Identifying an app that is open without an inspectable project working directory.
