# UI tests

This target is empty and is **not** in the `OpenSuperWhisper` scheme's test action, so
`xcodebuild test` doesn't try to launch it.

## Why

It held the three tests Xcode generates with a new target — `testExample`, `testLaunch`,
`testLaunchPerformance` — which launched the app and asserted nothing between them. They could
not fail on a regression, only on infrastructure, and that is exactly what they did: the runner
never finished bootstrapping, so a plain `xcodebuild test` came back red however healthy the
code was. A suite you cannot run clean is a suite people stop running.

## What actually blocks the runner

Not code signing, despite what #53 first supposed. The runner is signed
(`Apple Development: … `, identifier `fr.my-monkey.opensuperwhisperUITests.xctrunner`); the
failure is:

```
Failed to initialize for UI testing: Timed out while enabling automation mode.
```

macOS is refusing to let the runner drive another app. UI test automation needs Accessibility
permission for whatever launches it — Xcode when running from the IDE, the terminal app when
running `xcodebuild` — granted in System Settings → Privacy & Security → Accessibility. That is
a per-machine grant, so it can't be committed here; it has to be part of whatever setup notes
come with the first real UI test.

## Adding UI tests later

1. Grant Accessibility to Xcode (and to your terminal, if you run `xcodebuild` by hand).
2. Confirm the runner bootstraps: `xcodebuild test -only-testing:OpenSuperWhisperUITests`.
3. Re-add the testable to `OpenSuperWhisper.xcscheme`, and keep `parallelizable` off until the
   suite is known to tolerate it — UI tests drive one shared app instance.

Note that CI builds only (`.github/workflows/build.yml` runs `./run.sh build`), so UI tests will
not be exercised there without a workflow change, and a hosted runner has no one to click the
permission prompt.
