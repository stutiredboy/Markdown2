# Folder workflow

Choose **File → Open Folder…** (`Shift+Cmd+O`) to browse one Markdown folder in the document window's sidebar. Use the sidebar button to hide or show it, and switch between **Files** and **Outline** at the top.

- Click a file to preview it and keep focus in the tree. With the keyboard, move the selection with Up and Down, then press Space to preview. Use the disclosure triangle or Right Arrow to expand a folder.
- Markdown2 uses one italic preview tab in the folder's native tab group. The next preview replaces it. Double-click a file, press Return, or edit the document to keep that tab open. Return also focuses the document. Already-open documents are reused with their edits intact.
- Press `Shift+Cmd+B` (**File → Focus Folder Browser**) to return to the tree. The File menu shows the active shortcut if your mode shortcuts use this key combination. The current document has a highlight separate from the keyboard selection. Choose **File → Reveal in Folder Browser** to expand the current file's path and select it in the tree.

**File → Quick Open…** (`Shift+Cmd+P`) focuses the search field. Type part of a filename or relative path, use the arrow keys to select a result, then press Return to keep the file open and focus the document. Matching ignores case, accents and character width. Clear the field to return to the tree. If no folder is open, Quick Open asks you to choose one.

## Favorite folders

Select the star beside the browser’s path to add the current folder to your favorites. Select the filled star to remove it. The same actions appear at the top of **File → Favorite Folders** as **Favorite Current Folder** or **Remove Current Folder from Favorites** while a folder is open.

Choose a favorite from that submenu to load its Markdown tree into the sidebar. Open documents stay open. Favorites appear in the order you added them and persist across launches. When folders share a name, the menu includes their parent folder names. Hover over an entry to see its full path.

Use **Remove a Favorite** to remove an individual folder or **Clear Favorite Folders** to empty the list. Markdown2 saves each folder’s canonical path in its local preferences and checks that path again when you open a favorite. If the path is missing, inaccessible, or now points through a symbolic link or to a Finder alias, the alert explains the problem. Choose **Keep** if the folder may become available again, for example when you reconnect an external drive, or **Remove from Favorites** to drop the entry.

## Scope and limits

- One folder session belongs to one native tab group. Opening a different folder replaces the current session. Closing the group's last tab ends the session and cancels its work. Hiding the sidebar keeps the session available.
- The index reads names and metadata for regular `.md` and `.markdown` files. The tree shows folders that contain indexed files. The scan skips hidden entries, packages, `node_modules`, Finder aliases, symbolic links, files with multiple hard links, and nested volumes.
- A scan examines up to 20,000 entries, lists up to 2,000 files and goes up to 24 levels below the selected folder. The window reports partial results and inaccessible items. You can cancel a scan or choose a narrower folder. Files over 32 MiB can be opened directly with **File → Open**.
- Relevant filesystem changes refresh the list after a short delay. You can also select **Refresh**. Switching tabs or returning to the sidebar reuses the existing index. A file that moves, is replaced, or becomes a link between indexing and opening must be refreshed and selected again. Choose the folder again if its root was moved or replaced.
- A document opened from the browser is tied to the verified file. If that file disappears or becomes hard-linked, edits stay in the editor and a different save location can be chosen. If a replacement is explicitly opened from the refreshed list, any unavailable editor for the old file is kept as an untitled draft.

Quick Open searches filenames and paths. Folder-wide content search, renaming, and updating links between documents are separate follow-up work.
