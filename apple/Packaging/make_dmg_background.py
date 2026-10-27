#!/usr/bin/env python3
"""生成 DMG 安装窗口背景（1x + 2x 合成 TIFF）。

窗口 720×460 点，图标中心与 build.sh 中 create_dmg 的坐标一致：
App (190, 210)，「应用程序」(530, 210)，图标 128 点。
用法：python3 apple/Packaging/make_dmg_background.py（需要 Pillow），输出 dmg-background.tiff。
"""

import os
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 720, 460
APP_X, APPS_X, ICON_Y = 190, 530, 210
FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
BOLD_FONT = "/System/Library/Fonts/STHeiti Medium.ttc"
HERE = os.path.dirname(os.path.abspath(__file__))

TOP = (250, 251, 254)
BOTTOM = (236, 240, 248)
TITLE = (29, 29, 31)
BODY = (72, 76, 88)
MUTED = (120, 126, 140)
ACCENT = (52, 120, 246)


def font(size, scale, bold=False):
    return ImageFont.truetype(BOLD_FONT if bold else FONT, size * scale)


def centered(draw, y, text, fnt, fill, scale):
    width = draw.textlength(text, font=fnt)
    draw.text(((WIDTH * scale - width) / 2, y * scale), text, font=fnt, fill=fill)


def render(scale):
    image = Image.new("RGB", (WIDTH * scale, HEIGHT * scale))
    draw = ImageDraw.Draw(image)
    for y in range(HEIGHT * scale):
        t = y / (HEIGHT * scale - 1)
        color = tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
        draw.line([(0, y), (WIDTH * scale, y)], fill=color)

    centered(draw, 34, "安装 Billumi", font(26, scale, bold=True), TITLE, scale)
    centered(draw, 74, "把左边的 Billumi 拖到右边的「应用程序」文件夹", font(15, scale), BODY, scale)

    # 两个图标之间的箭头。
    start, end, y = (APP_X + 92) * scale, (APPS_X - 92) * scale, ICON_Y * scale
    thickness = 6 * scale
    draw.line([(start, y), (end - 14 * scale, y)], fill=ACCENT, width=thickness)
    draw.ellipse([start - thickness / 2, y - thickness / 2, start + thickness / 2, y + thickness / 2], fill=ACCENT)
    head = 18 * scale
    draw.polygon([(end, y), (end - head * 1.3, y - head), (end - head * 1.3, y + head)], fill=ACCENT)

    # 图标下方 Finder 会显示名称，说明放在其下。
    steps = [
        "① 拷贝完成后，从「应用程序」文件夹或 Spotlight 打开 Billumi",
        "② 安装完成后可推出此磁盘，并删除下载的 DMG 文件",
    ]
    for index, text in enumerate(steps):
        centered(draw, 350 + index * 28, text, font(13, scale), MUTED, scale)
    return image


def main():
    with tempfile.TemporaryDirectory() as tmp:
        one = os.path.join(tmp, "background.png")
        two = os.path.join(tmp, "background@2x.png")
        render(1).save(one, dpi=(72, 72))
        render(2).save(two, dpi=(144, 144))
        out = os.path.join(HERE, "dmg-background.tiff")
        subprocess.run(["tiffutil", "-cathidpicheck", one, two, "-out", out], check=True)
        print(out)


if __name__ == "__main__":
    main()
