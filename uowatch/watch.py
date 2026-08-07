#!/usr/bin/env python3
# uowatch — release watcher for ModernUO.
# WHY this exists: the Ultima Online shard runs a LOCALLY BUILT image (upstream
# ships none), and diun can only watch images in a registry — so without this,
# UO would be the one server with no update alerts. This closes that gap the
# same way paperwatch does for Minecraft: poll the upstream release feed and
# post to the same Mattermost channel, with a ready-to-paste rebuild command.
import json, os, time, urllib.request

HOOK = os.environ["WEBHOOK_URL"]
REPO = os.environ.get("REPO", "modernuo/ModernUO")
PINNED = os.environ.get("PINNED_VERSION", "")
POLL = int(os.environ.get("POLL_SECONDS", "86400"))          # daily
STATE = "/state/last_seen"
UA = "uowatch (v@valdemar.ai)"


def latest_release():
    req = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}/releases/latest",
        headers={"User-Agent": UA, "Accept": "application/vnd.github+json"})
    return json.loads(urllib.request.urlopen(req, timeout=20).read())["tag_name"]


def post(title, text, color="#00A9CA"):
    payload = {"username": "Game Servers", "icon_emoji": ":crossed_swords:",
               "attachments": [{"color": color, "title": title, "text": text}]}
    req = urllib.request.Request(HOOK, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json", "User-Agent": UA})
    try:
        urllib.request.urlopen(req, timeout=15).read()
    except Exception as e:
        print("mattermost post failed:", e, flush=True)


def seen():
    try:
        return open(STATE).read().strip()
    except Exception:
        return PINNED


def remember(tag):
    os.makedirs("/state", exist_ok=True)
    open(STATE, "w").write(tag)


print(f"uowatch up — watching {REPO}, running {PINNED}", flush=True)
while True:
    try:
        tag = latest_release()
        if tag and tag != seen():
            post(
                f":crossed_swords: New ModernUO release: {tag}",
                f"The Ultima Online shard runs **{PINNED}**.\n"
                f"Changelog: https://github.com/{REPO}/releases/tag/{tag}\n\n"
                ":wrench: To upgrade, rebuild with the new tag:\n"
                f"`MODERNUO_REF={tag} docker compose up -d --build`\n\n"
                f"Then set PINNED_VERSION={tag} here, so this stops reporting a "
                "gap that no longer exists.")
            remember(tag)
    except Exception as e:
        print("check failed:", e, flush=True)
    # Heartbeat for the healthcheck: a crash is caught by restart policy,
    # but a HUNG loop looks perfectly alive from the outside — and this is
    # a watcher, so its silence is indistinguishable from "nothing wrong".
    open("/tmp/HEARTBEAT", "w").write(str(time.time()))
    time.sleep(POLL)
