# App cleaner

The App cleaner uninstalls an app together with the files it leaves behind in your Library folders: caches, settings, saved state, logs, containers and background services. You review every item first, and everything goes to the Trash. Frog never deletes anything permanently and never empties the Trash.

## Turn it on

Open **Features** and switch on **App cleaner**. It is off by default. While it is off, Frog reads nothing for it and the page is not in the sidebar. Turning it off while a scan or the confirmation is open closes them without moving anything.

## Uninstall an app

The page lists the apps in `/Applications` and `~/Applications`, with their version and size. Apple's apps and Frog itself are not listed. Search by name or bundle ID, sort by name or size, then click an app or press Return. You can also drop an app from Finder onto the page.

Frog then looks for the app's files and groups them by how sure it is that they belong to the app:

- **App:** the app itself.
- **Sure matches:** named after the app's bundle ID, one of its parts or one of its app groups, or a background service that starts a program inside the app or names it as its own. The reason under each item says which, for example "Named after the bundle ID com.example.app." or "Its label is Example's bundle ID."
- **Likely matches:** named exactly after the app, when that name is distinctive enough ("Folder named Example.", "Folder Example inside Vendor.", "Crash report of Example.").
- **Possible matches:** only resemble the app ("Name contains example.", "Folder of the developer, Vendor.", "Starts with the developer's team ID.", "Label shares Example's developer prefix."). They appear only when **Show possible matches** is on in the page's settings.
- **Used by other apps:** another installed app claims the same name or ID.

Only sure and likely matches start ticked. Possible matches, items used by other apps and group containers are never ticked by Frog; tick them yourself when you know they can go. Each row shows its size and a **Reveal in Finder** button. The header says how much the ticked items take; "at least" means some sizes are not known yet or could not be read completely.

Notices above the list say when the app is running (Frog quits it first), when it comes with its own uninstaller (**Open Uninstaller** opens it; it can remove parts Frog cannot see), when it has a system extension, and when some items need Full Disk Access.

## From the command bar

Type uninstall or remove and the app's name, for example `uninstall slack`. Frog opens the review; nothing moves until you confirm. The command bar offers up to three apps, the same ones the page lists: never Apple's apps, Finder or Frog itself. Typing the words starts no scan; the scan starts when you choose the row.

<!-- slot: cleaner-leftovers -->
<!-- slot: cleaner-junk -->
<!-- slot: cleaner-assist -->
<!-- slot: cleaner-disk -->
<!-- slot: cleaner-startup -->

## What Frog never touches

Whatever found an item, Frog refuses to offer or move:

- Apple's own files: anything with `com.apple.` in its name (team-prefixed groups included), Shortcuts' data, the folders macOS keeps in your Library, and `/System`, `/usr`, `/bin`, `/sbin`, `/private` and `/Library/Apple`.
- iCloud Drive and synced folders (`Mobile Documents`, `CloudStorage`).
- Mail, Messages, Safari, Photos libraries and keychains, and `Daemon Containers`.
- A whole Library folder, or one of the folders it looks in.
- Items already in the Trash, and Frog's own app, data and settings.
- Items macOS protects (System Integrity Protection), and paths that pass through a link, where Frog cannot be sure where they point.
- Anything outside the Applications and Library folders it cleans.

## Moving to the Trash

**Move to Trash…** opens a confirmation that lists every item with its path and size, says what Frog quits or stops first, and names what macOS will ask. Nothing moves until you choose **Move to Trash** there; Return alone does not confirm it.

- Your own files move with the Mac's normal Move to Trash.
- Apps, containers and items that belong to the system move through Finder in one request. macOS asks once whether Frog may control Finder. For items that belong to the system, Finder asks for your administrator password; Frog never sees it.
- Background services whose files move are stopped first. System services stop after you restart your Mac.
- If an app does not quit, Frog asks before it force quits it; unsaved changes may be lost.

The space is freed only when you empty the Trash. Until then, you can put items back.

## Putting items back

**Recently moved** (the clock button at the top of the page) lists what Frog moved to the Trash in the last 30 days, newest first, with the number of items, their size and how many are already back. Open a removal to see each item and where it is: "In the Trash", "Put back", or "Use Put Back in Finder". The outcome of a removal offers **Put Back** as well.

- **Put Back** moves your own items from the Trash to their original places. An item fails alone when something else now sits at its place, or when it is no longer in the Trash.
- **Put Back in Finder** opens the Trash for items Frog cannot put back itself: items that belong to the system (moving them back needs the administrator password) and items Finder did not say where it put. Select them there and choose Put Back.
- **Remove from this list** forgets the record only; the items stay where they are.

Frog can put items back only while they are in the Trash. After you empty it, they are gone.

## Permissions

- **Full Disk Access** (optional): lets Frog measure and move app containers and other protected folders. Without it, those items show "Needs Full Disk Access" and Frog does not read them. A notice on the page opens the setting; **Not now** hides it on this Mac.
- **Automation for Finder:** macOS asks once, the first time Finder moves something for Frog. If it was denied, the outcome offers **Open Automation Settings**.
- **Administrator password:** asked by Finder, only for items that belong to the system.
- **App Management:** not expected; Finder moves app bundles, not Frog.
<!-- slot: cleaner-leftovers -->
<!-- slot: cleaner-junk -->
<!-- slot: cleaner-assist -->
<!-- slot: cleaner-disk -->
<!-- slot: cleaner-startup -->

## Settings

The page's **Cleaner settings** button holds the cleaner's switches. In `~/.config/frog/config`:

- `feature.cleaner`: turns the App cleaner on. Default `false`.
- `cleaner.possible-matches`: also list possible matches. Default `false`.
<!-- slot: cleaner-leftovers -->
<!-- slot: cleaner-junk -->
<!-- slot: cleaner-assist -->
<!-- slot: cleaner-disk -->
<!-- slot: cleaner-startup -->

Dismissed notices and the list of what was moved stay on each Mac in `~/Library/Application Support/Frog/Cleaner/` and are not exported. See [configuration](configuration.md#app-cleaner) and [privacy](privacy.md).
