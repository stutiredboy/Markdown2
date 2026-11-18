# Contributing to Markdown2

## Set up a checkout

Use macOS 15 or later and a selected Xcode toolchain with Swift 6 or later and
the macOS 15 SDK or later. Put Python 3.9 or later and Node.js on `PATH` for
verification. The workflow tests use the Python standard library, and the
math engine probe runs the bundled KaTeX directly with Node.js.

Record the toolchain versions alongside test results.

```sh
sw_vers
xcodebuild -version
swift --version
python3 --version
node --version
```

## Build and verify locally

From the checkout root, run the [build-only packaging script](Scripts/package_app.sh)
to create an ad-hoc signed `dist/Markdown2.app`.

```sh
bash Scripts/package_app.sh
```

For a smoke test, launch the development bundle with `open dist/Markdown2.app`
and use disposable documents. The development bundle ID
`dev.codex.md2.development` keeps its preferences and recovery separate from
the release app. The commands here build in the checkout. App installation
and default-handler selection are explicit options in the
[source build instructions](README.md#run-from-source).

Run the [local verification script](Scripts/functional_test.sh) before opening
a pull request. It runs the default Swift tests, the isolated scaling and main
actor responsiveness checks, the Python workflow tests, and development bundle
packaging and verification.

```sh
bash Scripts/functional_test.sh
```

For changes affecting windows, rendered output, or native input, run the same
gate with GUI tests enabled. Use an unlocked, idle desktop, close the smoke-test
instance, enable **System Settings → Keyboard → Keyboard navigation**, and
grant Accessibility access to the terminal or runner hosting the tests.

```sh
bash Scripts/functional_test.sh --gui
```

The GUI gate checks skips against the [expected skip list](.github/gui-expected-skips.txt).
Install [Pandoc](https://pandoc.org/installing.html) to run the DOCX and EPUB
archive checks locally. CI invokes the export menu both before and after installing
Pandoc and requires the archive checks to run. Report skips separately from
passes. For manual keyboard, Chinese
Pinyin, and VoiceOver verification, use the [native input acceptance plan](Docs/Plans/native-input-acceptance/PLAN.md).

## Open a pull request

Describe the behavior change and include a reproduction and regression check
for fixes. Record the commands, results, and relevant manual observations in
the PR. Check that the [PR workflow](.github/workflows/pr-verify.yml) passes,
including native GUI tests and both artifact handoff checks. See
[Release verification](Docs/ReleaseVerification.md) for the DMG checks and
the shared PR and tag workflow.

When changing bundled dependencies, update the
[third-party inventory and notices](Docs/ThirdParty.md) with the resources.
Summarize user-facing changes under **Unreleased** in the [changelog](CHANGELOG.md).
Keep raw test output with the PR verification evidence.
