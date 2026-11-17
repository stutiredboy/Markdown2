# Native acceptance record — 2026-11-17

The candidate is on `codex/p1-native-input-acceptance`, based on
`4c49cbd14c637740fcafbd56fd59fd1a85e3aac2`. The application source diff
SHA-256 is `973dbf740a001163c8f84924b757cd46545b65ec7964415f938b511007778e3f`.
The ad-hoc signed release build in the separate handoff profile has executable
SHA-256 `3ed5b487e69574c4025c48d456c074d484a8d5d58d619a3a5362425134bd535a`.
Its verified minimum macOS version is 15.0. It was built without installing it or
changing the Markdown file association.

## Manual acceptance

On 2026-11-17, the maintainer confirmed that the writing workflow passed in
English and Simplified Chinese using a physical keyboard. Simplified Chinese
Pinyin composition and VoiceOver also passed the manual review.
The maintainer followed the [physical keyboard checklist](HANDOFF.zh-CN.md).

## Automated acceptance

Environment: Apple silicon; macOS 27.2.1 (26B131); Xcode 27.2 (27B52);
Swift 6.4.2. The unlocked console reported Keyboard Navigation enabled.
Input sources: U.S. (`com.apple.keylayout.US`) and macOS Simplified Pinyin
(`com.apple.inputmethod.SCIM.ITABC`, SCIM 104/519). VoiceOver: 10 (993).
The original system speech settings were used. The configured voice name was
not recorded; the captions show localized app strings and some Chinese system
role descriptions in both app languages.

Keys were posted as virtual hardware key codes through the macOS WindowServer to
the isolated app. AppKit, the system Pinyin input method and VoiceOver itself
handled them. AX served as a focus/source observer for those sequences.
VoiceOver speech below is transcribed from its caption panel. Independently,
AppKit/XCTest and cross-process AX tests cover parts of the flow.

| Area | Observed |
| --- | --- |
| Open, edit, table, paste | Cmd+O opened a test document; a Latin edit added a star and native Undo restored the source. In the English app, Option+Cmd+T inserted a table, and Tab/Shift+Tab moved the selection without another edit. The English Edit menu pasted literal text, converted RTF bold to Markdown, and converted TSV with a Chinese cell to a table. |
| Pinyin | The packaged-app regression used the system IME: the marked reading left the title and file clean; first Return committed Latin text; second Return continued the list; Space committed a Han candidate. A separate live writing exercise committed 你好 and removed it with Undo. The marked-URL paste case was reproduced with an AppKit marked clause, not a physical key sequence. |
| Find | Both app locales exposed a labeled editable source, find field and replacement field. Replace All changed both occurrences and one Undo restored them. In the signed candidate, two keyboard activations of single Replace changed both occurrences. After the last match, focus moved to the replacement field. Escape returned to source; the two Undo steps restored one occurrence at a time. |
| Remote images | In both locales, there was no loopback fixture request before grant, on Return or after Escape cancelled the prompt. Cancel received initial keyboard focus. Tab reached the grant button, Space granted, focus returned to the revoke control, and the server recorded the matching GET. Space revoked and returned focus to the allow control; the preview showed the blocked placeholder again. A separate cross-process test verified that external reload closes an old consent sheet and leaves the new context blocked. |
| Save and conflict | In both locales the read-only fixture produced a permission error, retained the starred editor and preserved disk bytes. After dismissal and permission restoration, Cmd+S wrote the retained edit and cleared the star. Both versions of the conflict prompt preserved the external file until a choice. The signed candidate saved the local edit after Keep My Version in English, and adopted the external bytes after Reload from Disk in Chinese. Focus returned to source and the title cleared in each case. |
| Export | From the keyboard menu, the English PDF export produced a two-page PDF; PDFKit extracted its bilingual text and blocked-image notice. The Chinese HTML export, with preview permission active, contained the expected body and no active image element. Its offline placeholder retained the URL as inert evidence. Existing automated tests also exercise actual reopened HTML and PDF outputs. |

VoiceOver captions included **Markdown Source**, **Markdown 源码**,
**Replace With, text field**, **替换为，编辑文本**, **Allow Remote Images,
button**, and **允许远程图片，按钮**. The save error began “Could not save
SpeechFailure.md.” or “无法保存 SaveFailure.md” and included the filesystem
permission detail. The conflict caption began “Keep your edits or reload from
disk?” or “保留你的修改，还是从磁盘重新载入？” and explained that the file
changed outside Markdown2. The assistive technology settings stayed unchanged
across app locales; some role descriptions followed the system language.

`Scripts/functional_test.sh --gui` passed. The default invocation reported
1,086 passing Swift Testing tests and 46 passing XCTest cases (the default lane
excluded 289 GUI/fixture cases). The four isolated timing gates and 43 Python
workflow tests passed. The GUI lane reported 335 XCTest cases: 334 passed,
zero failed, and one allowlisted skip for the optional user-supplied PDF fixture.
The real Pinyin regression and all three Pandoc integration cases ran.
The development app's bundle metadata and strict code signature verified.

The [findings](FINDINGS.md) distinguish fixed defects, a rejected focus attempt,
and the separate baseline hard-link failure. The code and relevant evidence
were reviewed by a non-author.
