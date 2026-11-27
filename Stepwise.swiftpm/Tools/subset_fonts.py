"""把 Noto Serif SC / HK 裁成常用字，生成 App 里内置的正文字体。
用法：python3 subset_fonts.py <下载的 otf 所在目录> <输出目录>
"""
import sys, os
from fontTools import subset
from fontTools.ttLib import TTFont

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)

def decode_range(codec, lead, trail):
    chars = set()
    for a in lead:
        for b in trail:
            try:
                c = bytes([a, b]).decode(codec)
            except UnicodeDecodeError:
                continue
            if len(c) == 1 and ord(c) >= 0x3400:
                chars.add(ord(c))
    return chars

# GB2312 一、二级汉字（6763 个）
gb = decode_range("gb2312", range(0xB0, 0xF8), range(0xA1, 0xFF))
# Big5 常用字（5401 个）
big5 = decode_range("big5", range(0xA4, 0xC7), list(range(0x40, 0x7F)) + list(range(0xA1, 0xFF)))
hanzi = gb | big5
symbols = set()
for lo, hi in [(0x00B7, 0x00B7), (0x2010, 0x2027), (0x2030, 0x203B), (0x2103, 0x2103), (0x2109, 0x2109),
               (0x2160, 0x217F), (0x2190, 0x2199), (0x2460, 0x249B), (0x25A0, 0x25CF), (0x2605, 0x2606),
               (0x3000, 0x303F), (0x3105, 0x312F), (0xFE30, 0xFE4F), (0xFF01, 0xFF5E), (0xFFE0, 0xFFE5)]:
    symbols.update(range(lo, hi + 1))
unicodes = sorted(hanzi | symbols)
print("hanzi", len(hanzi), "gb", len(gb), "big5", len(big5), "total", len(unicodes))

for region in ["SC", "HK"]:
    for weight in ["Regular", "Bold"]:
        opts = subset.Options()
        opts.layout_features = ["ccmp", "locl", "kern", "liga"]
        opts.hinting = False
        opts.desubroutinize = False
        opts.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
        opts.name_languages = [0x409]
        opts.notdef_outline = True
        opts.drop_tables += ["VORG", "vhea", "vmtx", "BASE"]
        font = TTFont(os.path.join(src, f"NotoSerif{region}-{weight}.otf"))
        cmap = font.getBestCmap()
        missing = [u for u in unicodes if u not in cmap]
        sub = subset.Subsetter(opts)
        sub.populate(unicodes=[u for u in unicodes if u in cmap])
        sub.subset(font)
        path = os.path.join(out, f"ExamSong-{region}-{weight}.otf")
        font.save(path)
        print(region, weight, os.path.getsize(path), "glyphs", len(font.getGlyphOrder()), "missing", len(missing),
              "".join(chr(u) for u in missing[:30]))
