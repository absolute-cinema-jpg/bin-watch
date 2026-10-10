# Bin Watch

A small menu-bar app that tells you when an Avid bin someone else has open becomes free. It checks for the bin's `.lck` file, and when that file is gone you get an alert.

## Build & install

```bash
./build.sh install     # builds and copies "Bin Watch.app" into /Applications
./build.sh             # just builds into ./build
./Tests/run.sh         # tests the lock detection logic against a fake project
```

The build only needs Apple's Command Line Tools. Xcode isn't required.

## Using it

1. Open Bin Watch from the Dock or Applications. Like Spotify, closing the window doesn't quit the app; it keeps monitoring. Click the Dock icon to bring the window back, and quit with ⌘Q.
2. **Monitored folder:** choose one folder. It can be a single Avid project or a whole "Avid Projects" folder. To change it later, use **Change…** in the bottom of the sidebar or in Settings. Watched bins that are still inside the new folder stay watched.
3. **Browse Bins:** works like Finder.
   - **Views:** switch between Icons, List and Columns (⌘1 / ⌘2 / ⌘3). In Columns view, clicking a bin shows a preview with a big Watch button.
   - **Moving around:** click a folder to open it. Use the back and forward buttons (⌘[ and ⌘]) or ⌘↑ to go up a level, and click any part of the path bar to jump there.
   - **Type or paste a path:** click the empty part of the path bar, or press ⌘L or ⌘⇧G. Finder paths, paths from Terminal, `file://` links and Windows-style paths all work. A path that points at a bin selects that bin.
   - **Search:** looks in the current folder and everything inside it.
   - **Selecting bins:** click a bin to select it, ⌘-click to add or remove one, ⇧-click to select a range, and ⌘A to select every bin in the folder. ↑/↓ move the selection and Esc clears it.
   - **Return:** toggles watching for the selection. If every selected bin is already watched, Return stops watching them; otherwise it watches them all. Folders still open with a single click.
4. Click **Watch** on the bins you're waiting for. The **Watching** page shows their live status and has a **Clear All** button, which asks for confirmation first.

When a watched bin goes from locked to free:

- A compact alert slides in at the top right and plays your chosen sound.
- Click **Got it** to dismiss the alert and stop watching that bin. This is the default; you can change it in Settings.
- Several alerts stack neatly, with the newest on top. Click the stack or **Show all** to expand it into a list (it never grows past 60% of the screen), and **Clear all** dismisses them all.
- Alerts appear above everything, on every Space and in full-screen apps. They respond to the first click and never take keyboard focus from Media Composer.
- The Dock icon bounces once and shows a badge with the number of alerts waiting. The chime can repeat every minute until you respond.

**Custom sounds:** go to Settings, then **Add Sound**. Any audio file works. Bin Watch keeps its own copy, in its private sandbox folder, so your original file isn't touched. You can also set the volume there.

## Asking for a bin

When a bin you need is locked, you can ask whoever has it open to close it. This works without Wi-Fi or any network setup: Bin Watch passes messages as small files in a shared **mailbox folder** on the same storage as your projects. It works over NEXIS, file servers and synced storage like Salon SyncBox, where it also reaches other sites.

1. **Set up (once per person):** open Settings, then **Bin Requests**, then **Choose…**, and pick the same folder as everyone else. Create a new empty folder for this, outside your Avid projects; Bin Watch refuses folders inside a project. Check **Your name**.
2. **Ask:** click **Ask…** next to any locked bin. It appears in Browse Bins, on the Watching page, in the right-click menu, and in Columns view's preview. Choose a person, or **Everyone using Bin Watch** if you're not sure who has it, and add an optional note. Asking also watches the bin.
3. **Their side:** they get a purple request alert with **I'll close it** and **Not now** (or **Not me**, when you asked everyone). You see their answer as an alert, and on the Watching page ("Seen by Sam", "Sam is closing it").
4. **When the bin frees up:** you get the usual alert, and the request disappears from everyone's screen by itself.

Requests expire after 12 hours. Each person's Bin Watch only ever writes its own message files, and tidies up its own old ones.

## Read-only, guaranteed by macOS

- **The monitored folder is read-only.** Bin Watch runs in the macOS App Sandbox and opens your monitored folder through a read-only bookmark, so macOS refuses any attempt to create, change, move or delete anything there. macOS's folder picker briefly grants write access to whatever you pick, so Bin Watch restarts itself right after you choose the folder. That way it never keeps that access.
- **The code only lists folders.** All project access is in [Sources/ReadOnlyFS.swift](Sources/ReadOnlyFS.swift), and it only lists directory contents. It doesn't even open the `.lck` files. It only checks whether their names exist.
- **Writes only go to two places:**
  - **The request mailbox** ([Sources/Mailbox.swift](Sources/Mailbox.swift)). It can't be your monitored folder, contain it, or sit inside an Avid project. Every write goes through one guarded function that only accepts the mailbox's own subfolders.
  - **Bin Watch's private sound library** inside its sandbox container.
- **It avoids false alarms.** A bin has to look free on two checks in a row before you're alerted. A workspace dropping offline never counts as "unlocked".

To check the entitlements yourself:

```bash
codesign -d --entitlements - "/Applications/Bin Watch.app"
```

## Notes

- After a rebuild, the monitored folder may show an orange dot (meaning it can't be reached). If it does, click **Change…** and pick the same folder again. Its saved permission is tied to the app's signature.
- **Open Bin Watch when I log in** works best when the app is in /Applications.
