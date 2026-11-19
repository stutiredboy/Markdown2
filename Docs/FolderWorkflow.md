# Folder workflow

Choose **File → Open Folder…** (`Shift+Cmd+O`) to browse one Markdown folder. Expand a folder with the disclosure triangle or the Right Arrow. Double-click a file or select it and press Return to open it in a document window. If that document is already open, Markdown2 brings its window forward with your edits intact.

**File → Quick Open…** (`Shift+Cmd+P`) focuses the search field. Type part of a filename or relative path, use the arrow keys to select a result, then press Return. Matching ignores case, accents and character width. Clear the field to return to the tree. If the browser is closed, Quick Open asks you to choose a folder.

## Scope and limits

- The browser lives in its own window. Opening a different folder replaces the current folder. Closing the browser ends that session and cancels its work. Open document windows can stay open.
- The index reads names and metadata for regular `.md` and `.markdown` files. The tree shows folders that contain indexed files. The scan skips hidden entries, packages, `node_modules`, Finder aliases, symbolic links, files with multiple hard links, and nested volumes.
- A scan examines up to 20,000 entries, lists up to 2,000 files and goes up to 24 levels below the selected folder. The window reports partial results and inaccessible items. You can cancel a scan or choose a narrower folder. Files over 32 MiB can be opened directly with **File → Open**.
- The list refreshes when you return to the browser or select **Refresh**. A file that moves, is replaced, or becomes a link between indexing and opening must be refreshed and selected again. Choose the folder again if its root was moved or replaced.
- A document opened from the browser is tied to the verified file. If that file disappears or becomes hard-linked, edits stay in the editor and a different save location can be chosen. If a replacement is explicitly opened from the refreshed list, any unavailable editor for the old file is kept as an untitled draft.

Quick Open searches filenames and paths. Folder-wide content search, renaming, and updating links between documents are separate follow-up work.
