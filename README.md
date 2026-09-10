# Airship Web SDK Inspector — USB bridge

Internal Airship tool. Plug an Android phone into your computer with its cable, and this reads the
Airship Web SDK state of the page open on the phone — channel ID, tags, attributes, opt-in status —
on the computer's screen. **Nothing is installed on the phone**, and nothing is written to it: only
reads.

## Install it

Two double-clicks on **macOS**. Nothing to install first — no Node.js, no Homebrew, no `adb`, no
account.

1. Green **Code** button above → **Download ZIP**. Unzip it, then move the folder somewhere you will
   keep it, such as `Documents`.
2. Double-click **`Start USB bridge.command`**.

A terminal window opens and reports what it is doing. The first start asks one or two questions —
press **Return** to accept — and takes a minute; later starts take a few seconds and ask nothing.
Your browser then opens on **http://localhost:8770**.

Keep that terminal window open while you use the bridge: it *is* the bridge. Closing it, or pressing
`Ctrl+C` in it, stops it.

<details>
<summary>If macOS refuses to open the launcher</summary>

The dialog reads *"Apple could not verify that … is free of malware"*, or on older versions *"… cannot
be opened because it is from an unidentified developer"*. Every script downloaded by a browser gets
this treatment; it says nothing about what this file contains.

**Do not click "Move to Trash".** Click **Done**, then:

1. Open **System Settings → Privacy & Security**.
2. Scroll to the **Security** section at the bottom. A line names the blocked file and offers
   **Open Anyway** — click it and confirm with Touch ID or your password.
3. Double-click the launcher again, then click **Open**.

That line only shows up shortly after a blocked attempt: if you do not see it, double-click the
launcher once more and go straight back to Privacy & Security.

You do this once, for one file. On older macOS versions the shorter route still works: **right-click**
the file → **Open** → **Open**.

</details>

<details>
<summary>What the first start installs, and where</summary>

Both of these land **inside the bridge folder**, ask for no administrator password, change nothing
else on your machine, and disappear when you delete the folder.

- **Node.js**, in `.node/` — only if you do not already have version 22 or later. About 50 MB from
  nodejs.org, checksum-verified.
- **Android platform-tools** (`adb`), in `.adb/` — only if `adb` is not already on your machine or in
  an Android Studio install. About 16 MB from Google, checksum-verified against their published SDK
  manifest.

Each is offered with a question you can decline. Declining `adb` still opens the page, but no phone
can be read.

</details>

## Use it

On the phone, once: **Settings → About phone → tap Build number seven times** to get Developer
options, then **Developer options → USB debugging**.

Then, every time:

1. Plug the phone in, unlock it, and accept the *Allow USB debugging?* prompt.
2. Open **Chrome on the phone** on the page you want to read.
3. On the computer's page: **Scan**, pick the phone, pick the tab, **Read**.

The header has an **Install as an app** button. Use it once and the bridge gets its own icon and
window, rather than being a tab among twenty.

## It keeps itself up to date

Every start checks for a newer version and applies it before the bridge comes up. It never touches a
folder someone is working in, and if the network is down it simply keeps the version you have.

Without closing anything, the page also has an **Update and restart** button. The bridge steps aside,
the launcher fetches whatever is newer and starts it again in the same window, and the page reloads
itself once it answers — a few seconds, and none of it asks you to find the terminal window again.

To pin a folder to the version it has, create an empty file called `.no-auto-update` next to the
launcher.

## Running it from a terminal

Node.js 22 or later and `adb` on your `PATH`:

```bash
npm start
```

`PORT=8771 npm start` moves it off the default port. On Linux, `bash scripts/start.sh` works the same
way as the double-click.
