#!/usr/bin/env python3
"""mksprites.py OUT -- !Modula2's !Sprites, drawn here: the application's
icon (a window, "M2" in white on green) and the file types': &A7B, a
program or implementation module (a page with a green band and "M2") and
&A7C, a definition module (the band teal).  From zfb2026's box/app/mksprites.py.
34 x 34 pixels, 32 bpp (&00BBGGRR) with a 1 bpp mask, as rosgd's
ports/rospdf/tools/mksprites.py makes !PDF's."""
import struct
import sys

W = H = 34
MODE = 6 << 27 | 90 << 14 | 90 << 1 | 1     # 32 bpp, 90 x 90 dpi
GLYPHS = {
    "M": ["101", "111", "111", "101", "101"],
    "2": ["110", "001", "010", "100", "111"],
}
BLUE = (0x00, 0x80, 0x30)
TEAL = (0x00, 0x70, 0x80)
NAVY = (0x00, 0x00, 0x60)
YELLOW = (0xFF, 0xFF, 0xFF)
WHITE = (0xFF, 0xFF, 0xFF)
GREY = (0x60, 0x60, 0x60)
LIGHT = (0xC0, 0xC0, 0xC0)


def letters(px, x, y, scale, colour):
    for i, ch in enumerate("M2"):
        for gy, row in enumerate(GLYPHS[ch]):
            for gx, bit in enumerate(row):
                if bit == "1":
                    for dy in range(scale):
                        for dx in range(scale):
                            px[x + (i * 4 + gx) * scale + dx, y + gy * scale + dy] = colour


def app():
    px = {}
    for y in range(3, 31):
        for x in range(2, 32):
            px[x, y] = GREY if x in (2, 31) or y in (3, 30) else BLUE
    for y in range(4, 8):                       # the title bar
        for x in range(3, 31):
            px[x, y] = LIGHT
    letters(px, 6, 12, 3, YELLOW)
    return px


def page(band=None):
    band = band or BLUE
    px = {}
    for y in range(1, 33):
        for x in range(6, 28):
            px[x, y] = GREY if x in (6, 27) or y in (1, 32) else WHITE
    for y in range(11, 23):
        for x in range(7, 27):
            px[x, y] = band
    letters(px, 9, 12, 2, YELLOW)
    return px


def sprite(name, px):
    img = bytearray()
    for y in range(H):
        for x in range(W):
            r, g, b = px.get((x, y), (0, 0, 0))
            img += bytes((r, g, b, 0))
    mask_words = (W + 31) // 32
    mask = bytearray()
    for y in range(H):
        bits = 0
        for x in range(W):
            if (x, y) in px:
                bits |= 1 << x
        mask += bits.to_bytes(mask_words * 4, "little")
    head = 44
    size = head + len(img) + len(mask)
    nm = name.encode("latin-1")[:12].ljust(12, b"\0")
    return struct.pack("<I", size) + nm + struct.pack(
        "<IIIIIII", W - 1, H - 1, 0, 31, head, head + len(img), MODE) + img + mask


def main():
    sprites = [sprite("!modula2", app()), sprite("file_a7b", page()), sprite("file_a7c", page(TEAL))]
    body = b"".join(sprites)
    data = struct.pack("<III", len(sprites), 16, 16 + len(body)) + body
    with open(sys.argv[1], "wb") as fh:
        fh.write(data)


if __name__ == "__main__":
    main()
