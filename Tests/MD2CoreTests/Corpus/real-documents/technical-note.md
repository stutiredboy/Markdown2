# Recovering an interrupted spool rotation

During the overnight run the worker created `events.next` and then exited
before it wrote a new checkpoint. The next start refused to send the file
because the old checkpoint still named `events.current`. The ingestion logs
showed that the endpoint had received the last batch from the old file.

## Recovery procedure

Pause incoming events and make a read-only copy of the spool. Copy data files
and `checkpoint.json` together so that a later check can tie the byte offset
back to the file that was actually acknowledged.

1. Confirm the inode of `events.current` against the checkpoint.
   - If they match, keep `events.current` as the active file.
   - If they differ, compare the recorded batch ID with the ingestion logs.
2. Put `events.next` aside until the active file is drained.
3. Start the worker with the producer still paused and observe one full poll.

Keep the following example in the incident ticket when reporting an inode
mismatch. The outer fence makes the entire template copyable as Markdown.

````markdown
### Sample incident entry

```text
acknowledged batch: 42
active file: events.current
```
````

## Checks before releasing the hold

The first poll should advance the offset exactly once for each acknowledged
batch. Compare the counters before reopening the producer. A temporary rise in
the queued counter is expected while the worker drains its old file.

| Check | Expected result | Evidence |
| --- | --- | --- |
| Checkpoint | Offset moves forward | `waypost status` |
| Duplicate delivery | No repeated batch ID | Ingestion log |
| Rotation | Only one active spool file | Directory listing |
## Results | next steps

The recovered worker processed the remaining 180 records and then started a
rotation with a fresh checkpoint. Leave both copies in the incident folder
until the next automated rotation completes. Send the next operator the batch
ID and timestamp so they can check it against the ingestion log.

The [Waypost README](project-readme.md) describes the normal rollout sequence.
