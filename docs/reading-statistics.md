# Reading statistics

The Me tab contains the overview card. Tap it for period summaries, the last
30 days of the selected period, recently finished books and searchable history.
The shelf long-press menu opens each book's reading details.

Reading runs automatically while the loaded reading page is foreground-visible.
Backgrounding, locking, navigating away, opening a directory/settings panel and
inactivity pause tracking. Footnote content remains eligible. The reading page
has only a Mark as finished action: no timer indicator or pause/resume control.
Tracking is automatic, with a fixed five-minute idle limit matching desktop.
There are no statistics settings; legacy enable/idle preferences are ignored.
Pointer-down and scroll activity renew the deadline.

Durations use a monotonic clock. Gaps over five seconds are not charged. Events
are checkpointed every fifteen seconds and on pause/exit. A crash can lose the
uncheckpointed interval. This estimates engagement, not eye attention.

The SQLite event log uses the desktop's reading-statistics-v1 wire schema:
Metadata, Reading, Status and Clear externally tagged variants. Reading intervals
record session UUID, UTC millisecond boundaries, local UTC offset in seconds and
the current source-book position. Translated and original views share identity.
Sessions shorter than 30 seconds retain time but do not count as a reading day
or establish a start date. Completion is explicit and supports backdated dates.
Reopening a finished book retains its completion.

Durations union overlapping intervals per book and across books; the personal
total need not equal the sum of book totals. Local-midnight splitting and stable
offset allocation match desktop. No historical duration is inferred from
existing progress. Removing a book retains history.

Existing cloud sync creates statistics/ and merges device-month JSON shards
before publishing only this device's shards. UUID insertion is idempotent.
Status edits resolve in (timestamp, event ID) order. Clear markers suppress
older reading/status events while retaining metadata and synchronization evidence.
Clear statistics requires confirmation and retains files, progress and annotations.

Validation covers desktop JSON compatibility, duplicate shard imports, own-device
history recovery, cross-book overlap, midnight, short sessions, idle/suspension,
clear markers, rereading and a narrow dark overview/detail layout.
