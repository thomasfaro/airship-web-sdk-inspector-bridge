# Airship Web SDK Inspector — USB bridge

Internal Airship tool. Reads tabs on a phone over USB and shows the Airship Web SDK state on the computer. Nothing is installed on the phone.

Clone this repo. A `git clone` is not quarantined by macOS, so `Start USB bridge.command` opens with a double-click. A zip from Drive or “Download ZIP” does not.

## Prerequisites

- [Node.js](https://nodejs.org)
- `adb`: `brew install android-platform-tools`
- On the phone: Developer options → **USB debugging**, cable plugged in, prompt accepted, phone unlocked

## Run

```bash
git clone https://github.com/thomasfaro/airship-web-sdk-inspector-bridge.git
cd airship-web-sdk-inspector-bridge
```

Double-click **Start USB bridge.command**, or:

```bash
npm start
```

The bridge opens at http://localhost:8770. The first time, use **Install as an app** in the header if you want a Launchpad icon. The terminal window *is* the server — closing it stops the bridge.

## Update

```bash
cd airship-web-sdk-inspector-bridge
git pull
```

Restart the bridge (`Start USB bridge.command` / `npm start`).
