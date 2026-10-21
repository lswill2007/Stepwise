#!/usr/bin/env python3
"""把 KaTeX 打包成 Swift 源文件 Sources/App/KatexAssets.swift。

用法：
  1. 下载并解压 npm 包：curl -L https://registry.npmjs.org/katex/-/katex-0.16.9.tgz | tar -xz
  2. python3 Tools/embed_katex.py <解压出的 package 目录> 0.16.9

内嵌到源码而不是作为包资源，是为了在 Swift Playgrounds 里也一定能找到这些文件。
"""
import base64, os, re, sys

pkg, version = sys.argv[1], sys.argv[2]
dist = os.path.join(pkg, "dist")
read = lambda p: open(os.path.join(dist, p), encoding="utf-8").read()

js = read("katex.min.js")
mhchem = read("contrib/mhchem.min.js")
# 只保留 woff2 字体（WebKit 都支持），去掉 woff/ttf 备选，避免请求不存在的文件
css = re.sub(r',url\(fonts/[^)]+\.(?:woff|ttf)\) format\("[a-z]+"\)', "", read("katex.min.css"))
fonts = sorted(f for f in os.listdir(os.path.join(dist, "fonts")) if f.endswith(".woff2"))
license_text = open(os.path.join(pkg, "LICENSE"), encoding="utf-8").read().strip()

delim = "#####"
for name, text in [("js", js), ("mhchem", mhchem), ("css", css)]:
    assert '"""' + delim not in text and "\\" + delim not in text, name

def raw(text):
    return delim + '"""\n' + text + '\n"""' + delim

out = [
    "// 由 Tools/embed_katex.py 自动生成，请勿手动编辑。",
    "// KaTeX %s — https://katex.org" % version,
    "//",
] + ["// " + line if line else "//" for line in license_text.splitlines()] + [
    "",
    "enum KatexAssets {",
    '    static let version = "%s"' % version,
    "",
    "    static let js = " + raw(js),
    "",
    "    static let mhchem = " + raw(mhchem),
    "",
    "    static let css = " + raw(css),
    "",
    "    /// 字体文件（base64）",
    "    static let fonts: [(name: String, base64: String)] = [",
]
for f in fonts:
    data = base64.b64encode(open(os.path.join(dist, "fonts", f), "rb").read()).decode()
    out.append('        ("%s", "%s"),' % (f, data))
out += ["    ]", "}", ""]

target = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "App", "KatexAssets.swift")
open(target, "w", encoding="utf-8").write("\n".join(out))
print("wrote", os.path.normpath(target), "fonts:", len(fonts), "css font refs:", css.count("url(fonts/"))
