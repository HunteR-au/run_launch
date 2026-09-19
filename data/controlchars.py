"""Exercise run_launch's handling of control characters and escape sequences.

Prints, in a loop, the kinds of output that used to corrupt the display: ANSI colours,
a `\\r`-driven progress bar, a backspace spinner, tabs, bells, cursor movement within a
line, an OSC title, invalid UTF-8 and wide characters. In the terminal view every block
should read cleanly (colours applied, progress bar showing its final state); `render raw`
shows the same bytes with every control byte visible (`^[`, `^M`, `^G`, `\\xFF`).

Only the standard library is used. Output is written as bytes so nothing is re-encoded.
"""
import sys
import time

out = sys.stdout.buffer

ESC = b"\x1b"
CSI = ESC + b"["
RESET = CSI + b"0m"


def emit(data):
    out.write(data)
    out.flush()


def line(data=b""):
    emit(data + b"\n")


def colours(counter):
    line(b"--- %d: SGR colours ---" % counter)
    line(CSI + b"31m" + b"red " + CSI + b"32m" + b"green " + CSI + b"34m" + b"blue" + RESET + b" default")
    line(CSI + b"1;33m" + b"bold yellow" + RESET + b" " + CSI + b"4m" + b"underlined" + RESET + b" " + CSI + b"7m" + b"reverse" + RESET)
    line(CSI + b"38;5;208m" + b"256-colour orange" + RESET + b" " + CSI + b"38;2;255;0;255m" + b"truecolor magenta" + RESET)
    line(CSI + b"48;5;19m" + b"background" + RESET + b" text with " + CSI + b"91m" + b"ERROR" + RESET + b" inside")
    # colour that spans lines without being reset until later
    line(CSI + b"36m" + b"cyan starts here")
    line(b"and continues on this line")
    line(b"until it is reset" + RESET + b" here")


def progress(counter):
    line(b"--- %d: carriage-return progress bar ---" % counter)
    width = 30
    for step in range(width + 1):
        bar = b"#" * step + b"-" * (width - step)
        emit(b"\r" + b"[" + bar + b"] %3d%%" % (step * 100 // width))
        time.sleep(0.02)
    line()
    # overwrite with a shorter string: a terminal erases the rest with CSI K
    emit(b"downloading 100% complete")
    emit(b"\r" + CSI + b"K" + b"done")
    line()
    # the same idiom without the erase leaves the tail behind, as a terminal would
    emit(b"long first message")
    emit(b"\rshort")
    line()


def spinner(counter):
    line(b"--- %d: backspace spinner ---" % counter)
    emit(b"working ")
    for ch in b"|/-\\|/-\\|/-\\":
        emit(bytes([ch]) + b"\x08")
        time.sleep(0.02)
    line(b"ok")


def tabs_and_controls(counter):
    line(b"--- %d: tabs, bell and other controls ---" % counter)
    line(b"name\tvalue\tunit")
    line(b"a\t1\tms")
    line(b"longer name\t22\ts")
    line(b"bell follows this text\x07")
    line(b"\x07bell before, then form feed\x0c, vertical tab\x0b and NUL\x00 in the middle")
    line(b"DEL\x7f here and SO\x0e SI\x0f there")


def cursor_moves(counter):
    line(b"--- %d: cursor movement within a line ---" % counter)
    # CHA (column absolute), CUF (forward), CUB (back), EL (erase to end)
    emit(b"col1" + CSI + b"11G" + b"col11" + CSI + b"3C" + b"gap" + CSI + b"2D" + b"XX")
    line()
    emit(b"abcdef" + CSI + b"3G" + CSI + b"K" + b"|erased from col 3")
    line()
    # sequences that are dropped: clear screen, hide cursor, OSC title, charset
    emit(CSI + b"2J" + CSI + b"?25l" + ESC + b"]0;window title\x07" + ESC + b"(B")
    line(b"this line follows dropped sequences (clear screen, hide cursor, OSC title, charset)")
    emit(CSI + b"?25h")


def unicode_edges(counter):
    line(b"--- %d: UTF-8 edge cases ---" % counter)
    line("wide: 漢字 テスト 한글".encode("utf-8"))
    line("combining: é ä ñ, emoji: \U0001F600 \U0001F1EF\U0001F1F5".encode("utf-8"))
    line("zero-width: a​b‌c‍d﻿e".encode("utf-8"))
    line(b"invalid bytes: \xff \xfe \xc3 lone lead, \xe6\xbc truncated, \x80 stray continuation")
    # `x` lands on the first half of the wide 漢, whose other half becomes a blank; 字 survives
    line(b"wide overwritten by narrow (next line should read 'x', a blank, then the second glyph):")
    line("漢字\rx".encode("utf-8"))
    line(("C1 controls: a" + "" + "b" + "" + "c").encode("utf-8"))


def main():
    counter = 0
    blocks = [colours, progress, spinner, tabs_and_controls, cursor_moves, unicode_edges]
    while True:
        for block in blocks:
            block(counter)
            line()
            time.sleep(1)
        counter += 1


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, OSError):
        # the reader went away (BrokenPipeError, or EINVAL on Windows)
        pass
