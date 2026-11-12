# AI Usage

A small, transparent macOS widget that floats above your desktop and shows how much of your **Codex** and **Claude** plan limits you have left, for the five-hour and weekly windows. It switches on its own: bring the Claude app to the front and it shows Claude, bring Codex to the front and it shows Codex.

Made by [Mounir Toumi](https://toumi.us). AI Usage is an independent community project and is not affiliated with or endorsed by OpenAI or Anthropic. It was called **Codex Usage** before version 1.1.0.

![AI Usage widget with illustrative sample values](docs/assets/widget.png)

*The screenshot uses illustrative sample values; it does not show a real account.*

## What's new in 1.1.0

- **Claude support.** Shows your Claude plan's current session (5-hour) and weekly limits next to Codex, read from the Claude Code CLI you already have.
- **Follows the app you're using.** In Auto mode the widget shows Claude when the Claude app is in front and Codex when the Codex app is. Any other app keeps the last one shown. You can also pin it to Always Codex or Always Claude in Settings.
- **Smaller sizes.** Tiny is now the largest size, followed by Mini, Micro, Nano and Pico, so the widget can sit in a corner almost unnoticed.
- **Reset counts for both services.** The header shows which service you're looking at and its reset credits, such as `Codex · 2 resets` or `Claude · 2 resets`. Hover for expiry dates.
- **Clear sign-in hints.** If the Claude CLI isn't signed in, the header says so instead of showing empty bars.
- Plus everything since 1.0.1: Liquid Glass background, relative reset countdowns, a new app icon and a menu bar icon.

## Download

Download the latest **AI-Usage-…-macos-universal.zip** from [GitHub Releases](../../releases/latest), unzip it, and move **AI Usage.app** to Applications. The universal app supports both Apple silicon and Intel Macs running macOS 13 or later. If you used Codex Usage before, quit it and delete **Codex Usage.app**; your position and settings carry over.

This release is ad-hoc signed and is not notarized by Apple. On first launch, macOS may block it because it was downloaded outside the App Store. In Finder, Control-click **AI Usage.app**, choose **Open**, and confirm **Open** in the dialog. You should only need to do this once.

## Set up

- **Codex:** install the Codex CLI (or the ChatGPT/Codex app that bundles it) and sign in.
- **Claude:** install [Claude Code](https://docs.claude.com/en/docs/claude-code), then run `claude` once in Terminal and sign in with your Claude subscription. Signing in to the Claude desktop app alone is not enough, because the widget reads the CLI.

## Use the widget

- Drag the top area to place the widget; its position is remembered for the next launch.
- Each row shows remaining quota, a color-coded bar, and the reset time. Green means more than 50% remains, amber means 21–50%, and red means 20% or less.
- Reset times are countdowns in days and hours. Minutes appear only when six hours or less remain.
- The header shows the service and its available reset credits. `Resets —` means this information is unavailable; it does not mean zero. The widget only reads reset-credit information and never redeems credits.
- Hover over the widget to reveal refresh, settings, and quit controls. The hand icon marks the draggable area.
- The menu bar icon provides **Show Widget**, **Refresh Usage**, **Settings**, and **Quit**.
- Settings includes the service (Auto, Always Codex, Always Claude), five sizes from Tiny down to Pico, a Liquid Glass background that appears on hover or stays visible, refresh intervals from 30 seconds to 5 minutes, and an **Open at login** option. macOS 13–15 use a translucent material fallback. The widget also refreshes when it becomes active if the displayed reading is older than the selected interval.

## Usage data and privacy

No analytics or telemetry are added by this app, and it never writes or stores credentials for either service.

- **Codex:** the app asks the locally installed Codex CLI app-server for account rate limits. The CLI uses its existing sign-in and handles its own connection.
- **Claude:** the app runs the locally installed Claude Code CLI (`claude`) in a hidden terminal inside its own empty folder, opens `/usage`, reads the 5-hour and weekly percentages and reset times, then closes it. No prompt is sent to the model, and no tools, hooks or MCP servers are enabled. If a future CLI version changes the `/usage` screen, the Claude bars may show as unavailable until the app is updated.
- **Claude reset credits:** the CLI doesn't show these, so the app reads Claude Code's saved login from the macOS Keychain (read-only; macOS asks you once to allow it) and asks Anthropic's usage endpoint for the count, at most every 10 minutes. The login is only sent to `api.anthropic.com`. This endpoint isn't publicly documented; if it fails, the header shows `Resets —`.

Availability and reset times depend on the data returned for the signed-in account; a window may be unavailable for some plans.

## Build from source

Requirements: macOS 13 or later and Swift 5.9 or later (an SDK with Liquid Glass support for the macOS 26 background), plus a signed-in Codex CLI and/or Claude Code CLI.

```sh
swift test
bash ./scripts/build-app.sh
open "build/AI Usage.app"
```

To make a local universal release archive:

```sh
bash ./scripts/release-macos.sh 1.1.0
```

The archive and SHA-256 checksum are written to `build/release/`. GitHub Actions runs the same release script and attaches these files when a GitHub Release is published for a `v*` tag.

## Author

Built by Mounir Toumi. More at [toumi.us](https://toumi.us).

## License

Released under the MIT License. See [`LICENSE`](LICENSE).
