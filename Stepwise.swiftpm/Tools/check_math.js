#!/usr/bin/env node
// 检查公式排版：把 Tools/math_cases.txt 里的每一种写法交给 App 自己的排版代码
// （RichText.swift 里的 markdownJS + KatexAssets.swift 里的 KaTeX），有一条排不出来就报错。
//
// 用法：node Tools/check_math.js            检查全部写法
//       node Tools/check_math.js '$25\,^\circ\mathrm{C}$'   看某一段文字排成什么
//
// 改了 markdownJS、换了 KaTeX 版本之后跑一遍；遇到新的排不出来的写法，修好后加进 math_cases.txt。
const fs = require("fs"), path = require("path");
const app = path.join(__dirname, "..", "Sources", "App");
const assets = fs.readFileSync(path.join(app, "KatexAssets.swift"), "utf8");
const rich = fs.readFileSync(path.join(app, "Views", "RichText.swift"), "utf8");

// Swift 的 #"""…"""# 里 \# 是转义的开头，会把页面里的脚本弄坏（整页公式都不显示）
if (/\\#/.test(rawStringCheck())) { console.log("✗ markdownJS 里有 \\#，Swift 会当成转义：把反斜杠和 # 分开写"); process.exit(1); }
function rawStringCheck() { return rawString(rich, "markdownJS"); }

function rawString(src, name) {
  const m = src.match(new RegExp("static let " + name + ' = (#+)"""\\n'));
  if (!m) throw new Error("找不到 " + name);
  const start = m.index + m[0].length;
  return src.slice(start, src.indexOf('\n"""' + m[1], start) < 0 ? src.indexOf('"""' + m[1], start) : src.indexOf('\n"""' + m[1], start));
}

const katexModule = { exports: {} };
new Function("module", "exports", rawString(assets, "js"))(katexModule, katexModule.exports);
const katex = katexModule.exports;
new Function("self", rawString(assets, "mhchem"))({ katex });
const warn = console.warn; console.warn = () => {};
const page = new Function("katex", "window", "READY",
  rawString(rich, "markdownJS") + "\nreturn { md: md, fails: function () { return MATH_FAILS; } };")(katex, { katex }, true);

// 排出来算不算好：没有退回原文、没有 KaTeX 的报错红字
function check(text) {
  const before = page.fails();
  const html = page.md(text);
  if (page.fails() > before) return "排不出来，显示了原文";
  if (/katex-error|#cc0000/.test(html)) return "有报错的红字";
  if (!/class="katex/.test(html)) return "没有当成公式";
  return null;
}

if (process.argv[2]) {
  console.log(page.md(process.argv[2]));
  console.log(check(process.argv[2]) || "OK");
  process.exit(0);
}

let bad = 0, total = 0, section = "";
for (const line of fs.readFileSync(path.join(__dirname, "math_cases.txt"), "utf8").split("\n")) {
  if (!line.trim()) continue;
  if (line.startsWith("## ")) { section = line.slice(3); continue; }
  total++;
  // 一行是一个公式；整行写了 $ 的是一段文字
  const text = line.includes("$") && !line.includes("\\$") ? line : "$" + line + "$";
  const problem = check(text);
  if (problem) { bad++; console.log("✗ [" + section + "] " + line + "\n    " + problem); }
}

// 排出来的内容也要对（不只是不报错）
const expects = [
  ["$50%$ 的概率", "%"],                       // 百分号后面的不能被当成注释丢掉
  ["$25\\,^\\circ\\mathrm{C}$", "∘"],
  ["$\\\\frac{1}{2}$", "mfrac"],               // 反斜杠全写成两个
  ["$\u000crac{1}{2}$", "mfrac"],              // JSON 转义弄坏的 \frac
  ["$x=1\\tag{1}$", "katex-display"],          // 行内的 \tag 按独立公式排
  ["价格 \\$50 和 \\$60", "$50"],              // 金额不是公式
];
for (const [text, want] of expects) {
  total++;
  if (!page.md(text).includes(want)) { bad++; console.log("✗ [内容] " + JSON.stringify(text) + " 排出来应该有 " + want); }
}

console.log(bad ? bad + " / " + total + " 条有问题" : "全部 " + total + " 条正常");
process.exit(bad ? 1 : 0);
