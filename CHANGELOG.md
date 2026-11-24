# Changelog

## 1.1.1 — 2026-11-24

- Read Claude's 5-hour and weekly limits straight from Anthropic's usage endpoint with Claude Code's saved login. The widget no longer starts the Claude CLI or types `/usage`, so it can never send a prompt or use tokens (a broken `~/.claude/settings.json` had made the old probe send thousands of "fix my settings" prompts).
- Ask the endpoint at most about once a minute, wait 10 minutes after a rate limit, and keep the last reading (also across restarts, for up to a day) when the login has expired or the service is unreachable.

## 1.1.0 — 2026-10-30

- Rename the app from Codex Usage to **AI Usage**; settings, position and the login item identity carry over.
- Show Claude plan usage (5-hour session and weekly) read from the signed-in Claude Code CLI's `/usage` screen.
- Switch automatically between Codex and Claude when either app is the frontmost app; add a Show setting (Auto, Always Codex, Always Claude).
- Make Tiny the largest size and add four smaller sizes: Mini, Micro, Nano and Pico. Older saved sizes open as Tiny.
- Show the service name and Claude reset credits in the header, with expiry dates on hover. Claude's count comes from Anthropic's usage endpoint using Claude Code's saved login (read-only, cached for 30 minutes). Show a sign-in hint when the Claude CLI isn't signed in.
- Display available reset credits with their provided expiry dates on hover.
- Use relative reset countdowns for both usage windows; omit minutes above six hours.
- Native clear Liquid Glass background on macOS 26, a new app icon and a monochrome menu bar icon.

## 1.0.1 — 2026-09-26

- Fix hosted universal release builds and keep the published tag buildable from source.

## 1.0.0 — 2026-09-26

- Floating, transparent widget for weekly and five-hour remaining Codex quota.
- Color-coded progress bars, quota reset labels, and saved widget position.
- Hover controls and a menu bar menu for refresh, settings, and quit.
- Five widget sizes, configurable refresh intervals, and an Open at login option.
- Universal macOS app archive for Apple silicon and Intel.
