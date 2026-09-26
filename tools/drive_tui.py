r"""Drive run_launch in a Windows pseudo-console and render its screen, for smoke tests.

Requires:  py -m pip install --user pywinpty pyte

usage: py tools\drive_tui.py <seconds_before_keys> <steps...>
  steps: literal text to type, or ENTER / TAB / ESC / CTRLC / F2 / UP / DOWN / PGUP / PGDN /
         SLEEP:<s> / SNAP
  SNAP prints the current rendered screen.

environment:
  DRV_CMD   executable (default zig-out\\bin\\runlaunch.exe relative to the repo root)
  DRV_ARGS  arguments  (default "data\\launch.yml Print")
  DRV_COLS, DRV_ROWS  terminal size (default 140x40)

example: py tools\drive_tui.py 4 TAB TAB TAB SNAP / "merge m1 ~3 ~4" ENTER ESC TAB SNAP / q ENTER
"""
import os
import sys
import time

import pyte
import winpty

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CMD = os.environ.get("DRV_CMD", os.path.join(REPO, "zig-out", "bin", "runlaunch.exe"))
ARGS = os.environ.get("DRV_ARGS", r"data\launch.yml Print")
COLS, ROWS = int(os.environ.get("DRV_COLS", 140)), int(os.environ.get("DRV_ROWS", 40))

SPECIAL = {
    "ENTER": "\r",
    "TAB": "\t",
    "ESC": "\x1b",
    "CTRLC": "\x03",
    "F2": "\x1bOQ",
    "UP": "\x1b[A",
    "DOWN": "\x1b[B",
    "PGUP": "\x1b[5~",
    "PGDN": "\x1b[6~",
    "SLASH": "/",
}


class Screen(pyte.Screen):
    """Answer the terminal queries vaxis sends, like a real terminal would."""

    pty = None
    replies = 0

    def report_device_status(self, mode=0, **kwargs):
        if self.pty is None:
            return
        if mode == 5:
            self.pty.write("\x1b[0n")
        elif mode == 6:
            self.pty.write(f"\x1b[{self.cursor.y + 1};{self.cursor.x + 1}R")
        self.replies += 1

    def report_device_attributes(self, *args, **kwargs):
        if self.pty is not None:
            self.pty.write("\x1b[?62;22c")
            self.replies += 1


def main():
    wait_s = float(sys.argv[1])
    steps = sys.argv[2:]

    screen = Screen(COLS, ROWS)
    raw_stream = pyte.ByteStream(screen)

    class SafeStream:
        errors = 0

        def feed(self, b):
            try:
                raw_stream.feed(b)
            except Exception as e:  # noqa: BLE001
                self.errors += 1
                if self.errors <= 3:
                    print(f"[pyte error ignored: {e!r}]")

    stream = SafeStream()

    pty = winpty.PTY(COLS, ROWS)
    pty.spawn(CMD, cmdline=ARGS, cwd=REPO)
    screen.pty = pty

    total = 0

    def pump(seconds):
        nonlocal total
        end = time.time() + seconds
        while time.time() < end:
            try:
                data = pty.read(blocking=False)
            except Exception:
                data = None
            if data:
                b = data.encode("utf-8", "replace") if isinstance(data, str) else data
                total += len(b)
                stream.feed(b)
            else:
                if not pty.isalive():
                    break
                time.sleep(0.05)

    def snap(label):
        print(f"===== screen: {label} (alive={pty.isalive()}) =====")
        for line in screen.display:
            s = line.rstrip()
            if s:
                print(s)
        print("===== end =====")

    pump(wait_s)
    snap("after initial wait")

    for step in steps:
        if step.startswith("SLEEP:"):
            pump(float(step[6:]))
        elif step == "SNAP":
            snap("step")
        else:
            pty.write(SPECIAL.get(step, step))
            pump(0.4)

    pump(2.0)
    exited = not pty.isalive()
    try:
        status = pty.get_exitstatus()
    except Exception as e:  # noqa: BLE001
        status = f"? ({e})"
    print(f"exited={exited} exit_status={status} total_bytes={total} query_replies={screen.replies}")
    if not exited:
        snap("final (still alive)")
        sys.exit(1)


if __name__ == "__main__":
    main()
