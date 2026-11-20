# Project Launcher

A menu-bar app. One click opens a project's files, its Brave window and its Claude chat, laid out how you left them. Click again to close just those windows.

## Menu

- **Project names**: click to open (tick appears) or close. Shows the deadline countdown, plus time today while the project is open.
- **Save Window Layout of Open Projects**: remembers where each open project's windows are, for the screens you have connected right now.
- **New Project from Open Windows**: makes a project from the documents and named Brave window you have open, with their current layout.
- **Edit Projects...**: files, Claude link, Brave window, deadline, layouts and time spent.
- **Update Project Launcher...**: pulls the latest version from GitHub, rebuilds and reinstalls.

## Install or update

From this folder in Terminal:

```bash
./update.command
```

This builds the app, puts it in Applications and opens it. Needs Apple's Command Line Tools (`xcode-select --install`).

## Permissions (first run)

- **Accessibility** (to find, move and close specific windows): System Settings > Privacy & Security > Accessibility > enable Project Launcher.
- **Automation** (Brave, Word, Excel): click Allow when asked.

### Keep permissions between updates (optional, 2 minutes, once)

Each rebuild gets a new ad-hoc signature, so macOS can forget the permissions. Signing with your own certificate fixes that:

1. Open **Keychain Access** > menu **Keychain Access > Certificate Assistant > Create a Certificate...**
2. Name: `Project Launcher Local`. Identity Type: **Self Signed Root**. Certificate Type: **Code Signing**. Click Create.
3. Run `./update.command` again, then re-enable Project Launcher in Accessibility one last time.

`build.sh` uses that certificate automatically if it exists.

## Notes

- Closing a project presses each document window's close button, so Word and Excel still ask before discarding unsaved changes.
- Time is counted while a project is ticked, and pauses while the Mac sleeps.
- Layouts are stored per screen setup, so the laptop-only and external-monitor arrangements don't overwrite each other.
- Projects are saved in `~/Library/Application Support/ProjectLauncher/projects.json`.
- Start at login: System Settings > General > Login Items > + > Project Launcher.

## If the build fails

Copy the error from Terminal and paste it to Claude. Lines saying `warning:` are fine; only `error:` lines stop the build.
