# Project Launcher

A menu-bar app. One click opens a project's files, its Brave window and its Claude chat, laid out how you left them. Click again to close just those windows.

## Menu

- **Project names**: click to open (tick appears) or close. Opening a project closes the others first, so each starts fresh (hold **Option** to keep them open; anything both use stays open). Shows when it's due. Settings > **Menu order** lists them as in Edit Projects, most recently used first, or due soonest first.
- **Archive**: right-click a finished project (or use its Archived switch) to hide it from the menu and Raycast. Its time still counts towards its group.
- **Groups**: put projects in a named group (e.g. Radiation, holding Assignment 1 and Assignment 2). A group shows as a submenu with its projects (and their due dates) inside. Select a group in Edit Projects to see its total time. Groups are just a name: files, links and deadlines belong to the projects.
- **Checks**: 5 seconds after opening or closing a project, Project Launcher checks everything opened or closed. If not, the menu-bar icon turns into a warning and the menu shows what's wrong, with **Try Again**, **Quit Word/Excel** (for documents that wouldn't close), **Show Log** and **Dismiss**. Windows asking to save don't count as problems.
- **Save Window Positions**: remembers where each open project's windows are, for the screens you have connected right now. Closing a project does this too (windows that are minimised or gone keep their saved place); turn it off in Settings.
- **New Project from Open Windows**: makes a project from the documents, apps (e.g. Terminal, MATLAB), named Brave window and Claude chat you have open, with their current layout. You tick which apps belong first; everyday apps like Messages and Spotify start unticked. Captured apps **minimise** the project's window when the project closes (other windows of the app are left alone); in Edit Projects each app can instead **Quit** or **Hide** (all its windows). Claude minimises its window by default too (or Hide, Quit, Leave it), and Brave windows always minimise.
- **Add Open Windows to [project]**: adds documents and apps you've opened since (e.g. another PDF in Preview, or Terminal) to an open project, plus the front Brave window if it isn't in the project yet, and the Claude chat if it has none, and saves the window layout. Shows what it'll add first. Also in Edit Projects as **Add Open Windows…**.
- **Edit Projects…**: icon and colour (click the project's icon), files, Claude link, Brave windows (as many as you like), deadline, layouts and time spent. In the sidebar: drag projects to reorder them, right-click a project to open/close it, move it to a group or delete it, and right-click a group to add a project to it, reorder groups or delete it. **+** adds a project, the folder button adds a group, **−** or the Delete key deletes (it asks first). Right-click > **Duplicate** copies a project's setup. Drag files from Finder onto a project to add them. Backup pages, layouts and resetting time are under **Advanced**.
- **Install Update…**: appears when GitHub has a new version (checked every 4 hours, or by hand in Settings > Updates). Pulls it, rebuilds and reinstalls.

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
- Closing a project asks each app to close the project's documents (pressing the window's close button for apps that can't be asked), so apps still ask before discarding unsaved changes. MATLAB can't close a single file, so MATLAB files quit, hide or minimise MATLAB instead.
- Time is counted while a project is ticked, and pauses while the Mac sleeps or you're away (no keyboard or mouse for 10 minutes by default, back-dated to when you were last active; change it in Settings).
- An app's saved position belongs to one of its windows (matched by title, and for Terminal by its session), so with several Terminal windows open the project's own one is un-minimised and moved, not whichever is in front.
- Layouts are stored per screen setup (the screens connected), and the right one is used automatically when you open a project, so laptop-only and desk arrangements don't overwrite each other. You're asked to name a setup (e.g. Laptop, Desk) the first time you save for it; rename them in Settings > Screen setups.
- Closing a project minimises Claude straight away, and reopening the project brings it back on the same chat. If you open Claude yourself in between (Dock, Spotlight, Raycast), it switches to a new chat and fills the screen. Turn off in Settings.
- Projects are saved in `~/Library/Application Support/ProjectLauncher/projects.json`.
- Backups: your projects, groups and time are backed up once a day to iCloud Drive > Project Launcher Backups (or Application Support if iCloud Drive is off), keeping the last 30. Edit Projects > gear icon > Backups has **Back Up Now**, **Show Backups** and **Restore…** (which backs up the current list first).
- Open projects stay ticked (and keep counting time) if Project Launcher restarts, e.g. after an update, but not after the Mac restarts.
- Start at login: Edit Projects > gear icon > **Open Project Launcher at login**.
- A missing file (moved or renamed) shows **Find...** in Edit Projects: it looks for a file with the same name, or lets you pick it, keeping its settings and layout.

## If the build fails

Copy the error from Terminal and paste it to Claude. Lines saying `warning:` are fine; only `error:` lines stop the build.
