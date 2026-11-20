# Project Launcher

A menu-bar app. One click opens a project's files, its Brave window and its Claude chat, laid out how you left them. Click again to close just those windows.

## Menu

- **Project names**: click to open (tick appears) or close. Opening a project closes the others first, so each starts fresh (hold **Option** to keep them open; anything both use stays open). Shows the deadline, plus time today while the project is open.
- **Archive**: right-click a finished project (or use its Archived switch) to hide it from the menu and Raycast. Its time still counts towards its group.
- **Groups**: put projects in a named group (e.g. Radiation, holding Assignment 1 and Assignment 2). A group shows as a submenu, with how many are open, time today and the next deadline. Select a group in Edit Projects to see its total time. Groups are just a name: files, links and deadlines belong to the projects.
- **Checks**: 5 seconds after opening or closing a project, Project Launcher checks everything opened or closed. If not, the menu-bar icon turns into a warning and the menu shows what's wrong, with **Try Again**, **Quit Word/Excel** (for documents that wouldn't close), **Show Log** and **Dismiss**. Windows asking to save don't count as problems.
- **Save Window Layout of Open Projects**: remembers where each open project's windows are, for the screens you have connected right now.
- **New Project from Open Windows**: makes a project from the documents and named Brave window you have open, with their current layout.
- **Update Project from Open Windows**: adds documents you've opened since (e.g. another PDF in Preview) to an open project, plus the front Brave window if it isn't in the project yet, and the Claude chat if it has none, and saves the window layout. Shows what it'll add first. Also in Edit Projects as **Add Open Windows...**.
- **Edit Projects...**: icon and colour (click the project's icon), files, Claude link, Brave windows (as many as you like), deadline, layouts and time spent. In the sidebar: drag projects to reorder them, right-click a project to open/close it, move it to a group or delete it, and right-click a group to add a project to it, reorder groups or delete it. **+** adds a project, the folder button adds a group, **−** or the Delete key deletes (it asks first).
- **Update Project Launcher...**: pulls the latest version from GitHub, rebuilds and reinstalls.

## Raycast

Project Launcher keeps a Raycast command for each project, so you can search for a project in Raycast and press Enter to open or close it (plus **Close All Projects**). One-time setup:

1. Edit Projects > gear icon > Raycast > **Copy Folder Path**.
2. In Raycast: Settings > Extensions > **+** > **Add Script Directory**, press Cmd-Shift-G, paste, and choose the folder.

The commands update themselves as you add, rename, archive or delete projects. They use `projectlauncher://` links, e.g. `open "projectlauncher://toggle?name=interim report"` (also `open`, `close` and `closeall`).

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

- Word, Excel and PowerPoint files can be set (in Edit Projects) to **Quit Word/Excel** when the project closes, instead of just closing the file. It's skipped if another open project uses the same app, and the app still asks about any other unsaved documents.
- Closing a project asks each app to close the project's documents (pressing the window's close button for apps that can't be asked), so apps still ask before discarding unsaved changes. MATLAB can't close a single file, so MATLAB files quit or hide MATLAB instead.
- Time is counted while a project is ticked, and pauses while the Mac sleeps.
- Layouts are stored per screen setup, so the laptop-only and external-monitor arrangements don't overwrite each other.
- Projects are saved in `~/Library/Application Support/ProjectLauncher/projects.json`.
- Start at login: Edit Projects > gear icon > **Open Project Launcher at login**.
- A missing file (moved or renamed) shows **Find...** in Edit Projects: it looks for a file with the same name, or lets you pick it, keeping its settings and layout.

## If the build fails

Copy the error from Terminal and paste it to Claude. Lines saying `warning:` are fine; only `error:` lines stop the build.
