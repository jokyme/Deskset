"""Build the styled image and reject incomplete copies before it is compressed."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys

from dmgbuild import build_dmg

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("guide", type=Path)
parser.add_argument("background", type=Path)
parser.add_argument("volume_name")
parser.add_argument("output", type=Path)
args = parser.parse_args()
mount_point: str | None = None


def check_image(event):
    global mount_point
    if event["type"] == "command::finished":
        if event.get("command") == "hdiutil::attach":
            for entity in event["output"].get("system-entities", []):
                if entity.get("mount-point"):
                    mount_point = entity["mount-point"]
        elif event.get("command") == "hdiutil::detach" and event.get("ret") == 0:
            mount_point = None
        return
    if event["type"] != "operation::finished":
        return
    if event.get("operation") == "file::add":
        # dmgbuild does not check ditto's exit status; reject an incomplete guide.
        copied = Path(event["file"])
        if copied.name != args.app.name and copied.read_bytes() != args.guide.read_bytes():
            raise RuntimeError("The installation guide was not copied completely")
    elif event.get("operation") == "dmg::create":
        # Check after Finder metadata is written, since changes to the app's
        # extended attributes can invalidate an otherwise intact signature.
        if mount_point is None:
            raise RuntimeError("The disk image mount point was not reported")
        copied_app = Path(mount_point) / args.app.name
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(copied_app)], check=True)


def terminate(signum, _frame):
    raise SystemExit(128 + signum)


previous_sigterm = signal.signal(signal.SIGTERM, terminate)
try:
    build_dmg(
        str(args.output),
        args.volume_name,
        settings_file=str(Path(__file__).with_name("settings.py")),
        defines={"app": str(args.app), "guide": str(args.guide), "background": str(args.background)},
        callback=check_image,
    )
finally:
    try:
        # dmgbuild does not clean up KeyboardInterrupt, SIGTERM, or failures after
        # its copy phase. Use the still-mounted path, never a reusable disk number.
        if mount_point is not None and os.path.ismount(mount_point):
            try:
                subprocess.run(["/usr/bin/hdiutil", "detach", "-force", mount_point], check=False)
            except OSError as error:
                print(f"Could not detach {mount_point}: {error}", file=sys.stderr)
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)
