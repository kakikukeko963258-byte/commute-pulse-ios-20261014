"""Generate our own code-native icon; no third-party railway logos or artwork."""
from pathlib import Path
import json
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024


def color(x, y):
    # A train-front pictogram with two rails, drawn from original simple shapes.
    if 255 <= x < 770 and 220 <= y < 785:
        if 300 <= x < 724 and 288 <= y < 485:
            return (22, 70, 63)
        if 298 <= x < 370 and 570 <= y < 642 or 654 <= x < 726 and 570 <= y < 642:
            return (250, 210, 78)
        if 300 <= x < 724 and 690 <= y < 722:
            return (70, 123, 70)
        return (248, 251, 239)
    if 310 <= x < 360 and 785 <= y < 900 or 664 <= x < 714 and 785 <= y < 900:
        return (248, 251, 239)
    return (23, 123, 81)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


folder = ROOT / "Sources/CommuteApp/Assets.xcassets/AppIcon.appiconset"
folder.mkdir(parents=True, exist_ok=True)
raw = bytearray()
for y in range(SIZE):
    raw.append(0)
    for x in range(SIZE):
        raw.extend(color(x, y))
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
(folder / "AppIcon.png").write_bytes(png)
(folder / "Contents.json").write_text(json.dumps({
    "images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
    "info": {"author": "CommutePulse", "version": 1}
}, indent=2) + "\n", encoding="utf-8")
(folder.parent / "Contents.json").write_text('{"info":{"author":"CommutePulse","version":1}}\n', encoding="utf-8")
print("Generated original opaque 1024px app icon")
