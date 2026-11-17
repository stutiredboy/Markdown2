# Native keyboard, Chinese IME and VoiceOver acceptance

Exercise one writing flow in English and one in Simplified Chinese using the
packaged app on a usable macOS desktop. Retain the current document lifecycle,
title dirty marker and native Undo behavior. Fix reproducible defects in this
flow and rerun the affected scenarios on the final candidate.

## Prepare the desktop

- Build in the candidate checkout with `bash Scripts/package_app.sh`. Launch
  `dist/Markdown2.app` explicitly. The development bundle has a separate
  identity from the installed app. Keep installed-app settings and default file
  associations intact. Use a private development profile if the existing one
  contains documents or recovery state. Copy the bundle, set a unique
  `CFBundleIdentifier` in the copy's `Contents/Info.plist`, and ad-hoc sign the
  copy with `codesign --force --deep --sign -` before launching it. Record the
  private identity alongside the candidate commit.
- Record the source commit, app version, bundle identity, macOS version and
  build, input source IDs and versions, VoiceOver version and build, speech
  language and voice, and Keyboard Navigation setting. Use the app's language
  preference and relaunch between English and 简体中文. Confirm visible menus
  are localized before each run.
- Reserve the desktop while running native scenarios. Verify the candidate app
  owns keyboard focus before sending keys. Record whether someone used the
  physical keyboard or software sent virtual key codes through the macOS HID
  event path. Both exercise the normal app input pipeline. A synthetic AppKit
  event, an AX setter, paste and direct text insertion cannot verify IME
  composition. Record physical keyboard results separately if that hardware
  was used.
- Use the built-in Simplified Chinese Pinyin input source
  (`com.apple.inputmethod.SCIM.ITABC`) for candidate selection and commit. Switch
  back to the previous input source when done. Restore the desktop settings
  changed for the run, including VoiceOver and any change to Keyboard Navigation.

## Prepare the documents

Use throwaway copies of [fixture.md](fixture.md). For the image rows, run the
following server in a terminal. It binds a random loopback port and logs each
path requested. Keep its output with the run evidence.

```sh
python3 -u - <<'PY'
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

image = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAIAAAAt/+nTAAAAPklEQVR4nO3PMQ0AMAgAMJxMC2Kmc8lM8aKBg69JDTTOfavq56oQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEJhqkFH0tT754isAAAAASUVORK5CYII="
)

class ImageHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(image)))
        self.end_headers()
        self.wfile.write(image)

with ThreadingHTTPServer(("127.0.0.1", 0), ImageHandler) as server:
    print(f"Listening at http://127.0.0.1:{server.server_port}")
    server.serve_forever()
PY
```

In a second shell, set `port` to the value printed by the server. The control
GET should appear in the server log. Use the printed fixture path when opening
the source files and saving exports.

```sh
port=12345  # Replace with the reported port.
fixture_root="$(mktemp -d -t md2-native-input)"
run_id="$(uuidgen)"
curl --fail --silent --show-error "http://127.0.0.1:$port/control-$run_id.png" \
  -o "$fixture_root/control.png"
for locale in en zh-Hans; do
    fixture_dir="$fixture_root/$locale"
    mkdir -p "$fixture_dir/readonly" "$fixture_dir/exports"
    sed "s|PORT/TOKEN|$port/$run_id-$locale|g" \
        Docs/Plans/native-input-acceptance/fixture.md > "$fixture_dir/Writing.md"
    printf '# Save failure / 保存失败\n' > "$fixture_dir/readonly/SaveFailure.md"
    printf '# Conflict / 冲突\n\nOriginal / 原文\n' > "$fixture_dir/Reload.md"
    cp "$fixture_dir/Reload.md" "$fixture_dir/Keep.md"
done
printf '%s\n' "$fixture_root"
```

## Run in each app language

Use keyboard shortcuts or navigate the actual menus with VoiceOver or the
macOS menu bar shortcut. Switch to the Latin input source for ordinary typing
and use Pinyin for the composition scenario. Compare source text and selection
after each edit and Undo. Save between groups so the next dirty marker has a
known baseline.

| Scenario | Input and expected outcome |
| --- | --- |
| Open and edit | Open `Writing.md` from the app with Cmd+O. Enter Edit/编辑, type a short Latin marker and Undo it. Verify the editor owns focus, the edit adds ` *` to the window title, and the source returns to its previous text. |
| Chinese composition | At the final `-`, insert one space and save. Type `wubi` through Pinyin, observe marked text and candidates, and verify the clean title and disk bytes before commit. The first Return commits the Latin text and does not continue the list. The second Return starts the next item. Type `nihao`, select `你好` from the system candidates with Space or its candidate number, and verify that one Undo removes the committed text. Also cancel one uncommitted composition with Escape and confirm source and disk are preserved. |
| Table | Move to a blank line and insert a table with Option+Cmd+T. Verify first-header selection, Tab and Shift+Tab cell traversal, and traversal past the separator. In Format/格式 → Table Operations/表格操作 choose Insert Row Below/在下方插入行. One Cmd+Z restores text and selection. Tab on the last cell appends a row with one Undo. |
| Paste | Use Edit/编辑 to invoke Paste as Plain Text/粘贴为纯文本, Paste as Markdown/粘贴为 Markdown, and Paste as Table/粘贴为表格. Try distinctive Markdown punctuation, a rich text selection containing bold text and a plain TSV payload with a Chinese cell. Verify literal source, Markdown conversion and a navigable table respectively, each with one Undo. |
| Find and Replace | In source, open Find and Replace with Option+Cmd+F. Find `needle` or `测试词` and verify two matches. Tab and Shift+Tab between the query and replacement controls and confirm their labels. Enter replacement text, invoke Replace All/全部替换, and verify both changes. One Undo restores both matches. Escape closes the bar and returns keyboard focus to the editor. At minimum editor width (360 points), verify both input fields and action controls remain usable. |
| Remote images | In Side by Side/双栏, verify the image placeholder and blocked status without a request for the document token. Operate the localized Remote Images/远程图片 control by keyboard or VoiceOver. Confirm the grant and observe the matching GET and visible image. Revoke and verify the placeholder returns. Compare dirty state, source and Undo history across the policy actions. Then replace the image token with a fresh `-revoked` suffix while blocked. Verify the new path does not appear during the render interval. Undo this source edit before testing export. |
| Save | Type a fresh marker and press Cmd+S. Check exact UTF-8 disk content and the cleared dirty marker. In the separate failure case below, verify the error is announced and the editor preserves the unsaved text. |
| Conflict | Run the conflict procedure below on `Reload.md` and `Keep.md`. Verify the prompt is announced, disk and memory both survive until a choice, and keyboard focus returns to the affected document after closing the prompt. |
| Export | Invoke File/文件 → Export To/导出到 → HTML and PDF. Name files in the locale's `exports` directory. For HTML, first allow preview images and confirm the exported HTML opens with an inert placeholder, with no active image request when reopened. For PDF, revoke preview permission before exporting, then confirm Preview opens the PDF and it contains the document text and expected blocked-image state. Check localized save panels, return focus, source and dirty marker. |

For clipboard input, use one of these commands just before each paste. Run
`pbpaste -Prefer rtf` to confirm the rich sample begins with the RTF header.
Stop the loopback server after both runs.

```sh
printf '%s' '**literal** 中文' | pbcopy
printf '%s' '{\rtf1\ansi Rich \b bold\b0\par}' | pbcopy
printf 'Key\tValue\nName\t中文\n' | pbcopy
```

### Save failure and conflict

Set `fixture_dir="$fixture_root/en"` for the English run and
`fixture_dir="$fixture_root/zh-Hans"` for the Simplified Chinese run.

1. Record the bytes of `readonly/SaveFailure.md`, then make its fixture directory
   non-writable with `chmod 0555 "$fixture_dir/readonly"`. As the regular desktop
   user, open the file, type a unique marker and press Cmd+S. Confirm the localized
   save failure title and useful detail are announced. Dismiss the alert and
   verify the marker is still in the dirty editor while the disk bytes match the
   original. Run `chmod 0755 "$fixture_dir/readonly"`, retry Cmd+S, and verify
   the marker on disk and a clean title.
2. Open `Reload.md` or `Keep.md` and edit it. Within the five-second idle autosave
   window, write different bytes to that exact fixture using a separate process,
   for example `printf '# Outside / 外部\n' > "$fixture_dir/Reload.md"`. Keep the
   document window active and record the dirty buffer, disk bytes and prompt.
   If autosave wins the race, start with a fresh copy. Choose Reload from Disk
   on `Reload.md` and verify the external bytes load and the title is clean.
   Choose Keep My Version on `Keep.md`, then save and verify that the intended
   local bytes reach disk and the title clears. Record the prompt on arrival,
   before moving the VoiceOver cursor to a choice.

## VoiceOver evidence

Start VoiceOver with Cmd+F5. Use VO+M to reach menus, VO+arrow keys to navigate,
VO+Shift+Down Arrow to interact with a group and VO+Space to activate a control.
Capture the spoken label and state at the editor, find fields, remote-image
control, file/export panels and both error prompts. Verify the VoiceOver cursor
and keyboard focus on entry and return where they can differ. Check which
language the app strings are presented in and record the voice used.
[Apple VoiceOver navigation commands](https://support.apple.com/guide/voiceover/navigation-commands-cpvokys04/10/mac/27)

Collect actual VoiceOver output from its caption panel, played speech or its
copy-last-spoken-phrase shortcut (VO+Shift+C). Record the first output on error
arrival separately from speech after navigating to a button or message. An AX
tree can confirm role and keyboard focus. The speech evidence must come from
VoiceOver itself.
[Apple caption panel guide](https://support.apple.com/guide/voiceover/unac078/mac)
[Apple last spoken phrase guide](https://support.apple.com/guide/voiceover/repeat-copy-or-save-the-last-spoken-phrase-vo2725/10/mac/27)

## Verification and evidence

Run the focused system Pinyin regression with the Simplified Chinese Pinyin
source enabled and Quartz event posting available. Run the full gate from the
candidate checkout while the desktop is idle, with no concurrent live probe.
Enable Keyboard Navigation in macOS System Settings under Keyboard before
running the GUI suite locally. The permission sheet test asserts that Cancel
receives keyboard focus. The CI runner enables the same setting before XCTest.

```sh
MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing \
  --filter 'RecentDocumentsMenuGUITests/testPinyinCompositionCommitsWithSpaceAndReturn'
bash Scripts/functional_test.sh --gui
```

The full gate includes the default tests, isolated timing checks, workflow
tests, native GUI tests with the existing skip audit, and development bundle
validation. Record the actual counts and any skips. A conditional Pinyin skip
leaves that run's real IME result unverified.

Attach a two-language observation log for the final source, including focus,
VoiceOver output, original and final file bytes, HTTP paths and export results
as relevant. For each defect record a reproducer, before/after outcomes and a
regression check that would catch a recurrence. Have a non-author review the
final diff, evidence and any gaps before marking the TODO complete.
