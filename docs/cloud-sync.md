# Cloud synchronization

The mobile app keeps the desktop `Rebook/v1` wire format. Transfer caches are
local-only and are scoped by server root, username, and provider compatibility
mode; credentials are not stored in cache keys.

## Scheduling

- Reading changes settle for two seconds before a lightweight sync. A foreground
  fifteen-second poll prevents continuous page turns from postponing sync forever.
- Returning to the shelf flushes reading progress immediately.
- A lightweight sync transfers changed progress and annotations only, without
  scanning the book library or downloading OCR archives. No pending changes means
  no network requests.
- Foreground polling stays reading-only regardless of elapsed time; it does not
  periodically scan the entire library. Startup, library changes, manual sync,
  and account initialization can still request a full check, and failed full
  checks retain their retry behavior. During full checks, statistics transfer is
  throttled to ten minutes unless manual sync explicitly requests it.
- Failed automatic work waits thirty seconds before retrying. Requests arriving
  during a sync are coalesced into one follow-up, retaining full/manual requests.
- Polling stops while the app is not foreground-active. This does not introduce
  an Android background service.

## Transfer behavior

Full sync sends pending reading changes before book scans and uploads. It checks
the library before uploading missing books, reports aggregate book-upload byte
progress, and publishes library membership only after content and manifests
exist. Reading-state merging precedes derived-data downloads.
Independent book and reading-state checks run with at most four books in flight;
derived-data work is limited to two. Transfers drain before failure is reported.

Remote objects with ETags use conditional GETs; 304 reuses cached bytes and 404
invalidates them. Objects without validators are downloaded normally. Cached
response bodies are limited to 2 MiB per object; large OCR archives retain the
existing resumable file-download path.

Unchanged device documents and statistics shards skip PUTs. Only successful PUTs
are remembered. Reading acknowledgments describe the captured outgoing payload,
so edits made during a transfer remain pending. Full checks, including manual
sync, use directory listings to repair missing device documents without forcing
unchanged documents to upload again.

Successful directory checks persist across clients. Missing-parent write errors
repair the parent chain and retry, so a deleted server directory does not leave
the cache permanently stale. Warm reading-only sync also reuses a previously
validated protocol; full checks continue to validate the remote protocol.

Remote reading documents and statistics shards are fingerprinted after successful
merging. Unchanged data skips database merging, including on manual checks.
Statistics acknowledgments live in the statistics database alongside their events.

The shelf keeps its compact sync indicator without displaying stage text.
Successful manual checks finish silently, including when nothing changed;
manual failures still show an error message.
Android logcat messages tagged in their text with `TortoSync` report stage
durations, total duration, and buffered HTTP
request counts; they contain no credentials, server URLs, book IDs, or book titles.

The app does not upload desktop-only derived data that it cannot generate, and
keeps separate OCR download progress rather than treating it as a book upload.

## Verification (2026-09-12)

- Regression coverage includes warm full checks without redundant writes,
  directory and device-document recovery, unchanged statistics without event
  inserts, and bounded concurrent checks that drain safely on failure.
- In the single-book reading test (no other device state), a warm changed reading
  sync uses two requests instead of eighteen; an idle reading check uses none.
- On the connected Android phone using CSTCloud, build 7003 completed consecutive
  manual full checks in 12.868 s, 12.576 s, and 14.379 s. The cache-only intermediate build
  took 46.209 s; the original build was still busy at 64 s and finished by the
  94 s observation. These checks did not transfer new book files.
