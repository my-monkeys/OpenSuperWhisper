# OpenSuperWhisper for Claude Code

When Claude Code finishes a task, OpenSuperWhisper shows its last message in a small panel in the top-right corner. Dictate or type your answer there and Claude carries on, without going back to the terminal. Click "Let it stop" and the agent waits in its terminal as usual.

Requires OpenSuperWhisper running on the same Mac. When it isn't, the plugin does nothing.

## Install

```bash
claude plugin marketplace add my-monkeys/OpenSuperWhisper
claude plugin install opensuperwhisper@opensuperwhisper
```

Restart Claude Code afterwards. From a local checkout, `claude plugin marketplace add /path/to/OpenSuperWhisper` works too.

## How it works

The plugin registers a `Stop` hook. The hook hands the agent's last message to the app and waits, up to ten minutes, for your answer. Your answer goes back as the hook's output, which tells Claude to keep going with it. Nothing leaves your Mac.

Turn it off without uninstalling in OpenSuperWhisper's settings, or by quitting the app.
