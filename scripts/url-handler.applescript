-- Source of the "Start Airship bridge" bundle, which owns airship-bridge:// links.
-- scripts/install-url-handler.sh fills in the folder below and compiles this with
-- osacompile.
--
-- Two things rest on it. The bridge's own page, found with the server down, can start
-- it — no page may spawn a process, but any page may follow a link. And the background
-- service works from Downloads, Desktop or Documents, which launchd cannot read on its
-- own: macOS grants file access to an app it can name, not to /bin/bash.
--
-- Opened from the Dock or Spotlight it also opens the page; reached through the link it
-- does not, because whoever followed the link is already looking at it.

on run
	start_bridge("--open")
end run

on open location this_URL
	if this_URL contains "background" then
		start_bridge("--agent")
	else
		start_bridge("")
	end if
end open location

on start_bridge(flags)
	set bridgeRoot to "__ROOT__"
	set launcher to quoted form of (bridgeRoot & "/scripts/start-detached.sh")
	do shell script "/usr/bin/nohup /bin/bash " & launcher & " " & flags & " >/dev/null 2>&1 &"
end start_bridge
