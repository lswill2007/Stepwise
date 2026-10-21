#!/usr/bin/env python3
"""生成 Stepwise 的 App 图标（1024×1024，不透明 PNG）。

用法：python3 Tools/make_icon.py <输出文件>
图案：靛蓝渐变背景上三级白色台阶逐级升高，最高一级上方是一个对勾，寓意“一步一步走到答案”。
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SCALE = 4                      # 先放大绘制再缩小，边缘更平滑
W = S * SCALE

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# 背景：左上偏亮、右下偏深的对角渐变
top_left, bottom_right = (124, 108, 255), (64, 46, 200)
bg = Image.new("RGB", (W, W))
px = bg.load()
small = Image.new("RGB", (256, 256))
sp = small.load()
for y in range(256):
    for x in range(256):
        sp[x, y] = lerp(top_left, bottom_right, (x + y) / 510)
bg = small.resize((W, W), Image.BICUBIC)

# 三级台阶连成一个整体（底边对齐），只给外侧的凸角做圆角
steps = [
    # (左, 上, 右, 下, 圆角: 左上, 右上, 右下, 左下)
    (200, 640, 410, 812, (True, False, False, True)),
    (410, 488, 620, 812, (True, False, False, False)),
    (620, 336, 830, 812, (True, True, True, False)),
]

def u(v):
    return int(v * SCALE)

radius = u(44)

def draw_steps(d, dy, fill):
    for l, t, r, b, corners in steps:
        d.rounded_rectangle((u(l), u(t) + dy, u(r), u(b) + dy), radius=radius, fill=fill, corners=corners)

# 柔和阴影
shadow = Image.new("L", (W, W), 0)
draw_steps(ImageDraw.Draw(shadow), u(20), 120)
shadow = shadow.filter(ImageFilter.GaussianBlur(u(24)))
bg.paste((28, 14, 110), (0, 0), shadow)

draw = ImageDraw.Draw(bg)
draw_steps(draw, 0, (255, 255, 255))

# 对勾：在最高一级上方
check = [(u(618), u(214)), (u(690), u(282)), (u(834), u(140))]
draw.line(check, fill=(255, 255, 255), width=u(50), joint="curve")
for x, y in (check[0], check[-1]):
    r = u(25)
    draw.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255))

icon = bg.resize((S, S), Image.LANCZOS)
icon.save(sys.argv[1], "PNG")
print("saved", sys.argv[1], icon.size, icon.mode)
