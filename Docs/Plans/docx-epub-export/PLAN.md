# DOCX and EPUB export acceptance

## Behavior

- File → Export To offers DOCX and EPUB alongside PDF and HTML. The commands
  stay visible without Pandoc and explain how to install it. Check the usual
  macOS installation paths and the app's absolute PATH entries at invocation.
  Markdown2 ships without Pandoc and does not install it.
- The native destination picker explains that Pandoc converts Markdown source
  with its own layout and syntax support. Markdown2 preview diagrams and
  styling may be omitted or appear differently. Pandoc cannot fetch remote
  images. Successful exports explain that Word and EPUB readers may fetch
  resources when opening the result.
- Export the current editor text, including unsaved edits, using the document
  folder for relative resources. Untitled documents can export directly with
  no Markdown save. Use the system save panel's filename/type and overwrite
  confirmation. Canceling the picker leaves the source and destination alone.
- Keep conversion responsive and cancellable. Cancel on source changes, reload,
  replacement or close. One operation at a time owns the export flow for a
  window. Publish only a completed, current result through an atomic rename
  on the destination volume. Failures and cancellations preserve an existing
  destination.
- Apply the fixed network-deny sandbox to version queries, conversion and
  child processes. Stop if the wrapper cannot be used. The operating-system
  sandbox is a conversion-time network control. DOCX and EPUB archives may
  retain links and resources that independent readers handle themselves.

## Verification

| Risk | Check |
| --- | --- |
| Menu action missing, mistargeted or gated on an installation | Launch the app and invoke both native menu items via Accessibility before and after installing Pandoc on macOS 15 CI. Check installation guidance and the native destination flow. |
| Broken or incomplete archive | Inspect actual DOCX/EPUB artifacts and verify local image handling, including a read-only source directory. |
| Unconfined execution | Exercise existing positive-control HTTP tests, denied parent/child requests, and missing or rejecting confinement. Exercise actual Pandoc conversion with a counted remote image URL. |
| Stale export or data loss | Drive delayed conversion and a reentrant destination picker against document changes. Verify cancellation, cleanup, correct source snapshots and byte-for-byte preservation of an existing destination. |
| Regression outside conversion | Run the default, isolated performance and heartbeat, GUI, packaging and artifact handoff gates. Keep the existing PDF, HTML and Print coverage. Review the final diff before merge. |
