# -*- coding: utf-8 -*-
"""程序化贴图：地面整图 / 5 种建筑立面 / 8 张餐馆招牌（与网页版同一套视觉设计）"""
import random
from PIL import Image, ImageDraw, ImageFont
random.seed(42)
A = "/home/hatch/workspace/delivery-sim-godot/assets/"
FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"

# ---------- 地面 2000x1400（对应 3000x2100 px 空间，K=2/3） ----------
W, H, K = 2000, 1400, 2000/3000.0
g = Image.new("RGB", (W, H), (63, 72, 84))
d = ImageDraw.Draw(g, "RGBA")
for _ in range(5200):
    x, y = random.random()*W, random.random()*H
    d.rectangle([x, y, x+2.4, y+2.4], fill=(255,255,255,12) if random.random()<0.5 else (0,0,0,16))
for i in range(10):  # 车道磨损
    cx = (i*300+32)*K
    d.rectangle([cx-17*K, 0, cx-10*K, H], fill=(0,0,0,26)); d.rectangle([cx+10*K, 0, cx+17*K, H], fill=(0,0,0,26))
for j in range(7):
    cy = (j*300+32)*K
    d.rectangle([0, cy-17*K, W, cy-10*K], fill=(0,0,0,26)); d.rectangle([0, cy+10*K, W, cy+17*K], fill=(0,0,0,26))
for bx in range(10):
    for by in range(7):
        x, y, sz = (bx*300+64)*K, (by*300+64)*K, 236*K
        d.rectangle([x, y, x+sz, y+sz], fill=(152,161,171))
        d.rectangle([x, y, x+sz, y+3], fill=(255,255,255,26))
        hue_v = 40 + ((bx+by) % 5)
        base = (94+hue_v//2, 128, 66) if (bx*3+by) % 3 else (88, 122, 60)
        d.rectangle([x+7.3, y+7.3, x+sz-7.3, y+sz-7.3], fill=base)
        for _ in range(26):
            sx, sy = x+9+random.random()*(sz-24), y+9+random.random()*(sz-24)
            d.rectangle([sx, sy, sx+3, sy+2], fill=(0,0,0,14))
for i in range(10):  # 斑马线
    for j in range(7):
        cx, cy = (i*300+32)*K, (j*300+32)*K
        for s in range(-2, 3):
            d.rectangle([cx-19+s*11, cy-35, cx-12.5+s*11, cy-21], fill=(240,244,248,190))
            d.rectangle([cx-19+s*11, cy+23, cx-12.5+s*11, cy+36], fill=(240,244,248,190))
            d.rectangle([cx-35, cy-19+s*11, cx-21, cy-12.5+s*11], fill=(240,244,248,190))
            d.rectangle([cx+23, cy-19+s*11, cx+36, cy-12.5+s*11], fill=(240,244,248,190))
for i in range(10):  # 车道虚线
    cx = (i*300+32)*K
    for y in range(0, H, 32): d.rectangle([cx-1.3, y, cx+1.3, y+17], fill=(255,255,255,150))
for j in range(7):
    cy = (j*300+32)*K
    for x in range(0, W, 32): d.rectangle([x, cy-1.3, x+17, cy+1.3], fill=(255,255,255,150))
g.save(A+"ground.png")

# ---------- 立面 256x512 ----------
def facade(kind, bases, glass=False):
    im = Image.new("RGB", (256, 512))
    dr = ImageDraw.Draw(im)
    top, bot = bases
    for y in range(512):
        t = y/512.0
        dr.line([(0, y), (256, y)], fill=tuple(int(top[c]+(bot[c]-top[c])*t) for c in range(3)))
    cols = 7 if kind == "tower" else 6
    rows = 13
    cw, rh = 256/cols, 432/rows
    for r in range(rows):
        for c in range(cols):
            x, y, w, h = c*cw+cw*0.18, 16+r*rh+3, cw*0.64, rh*0.58
            if kind == "home" and r % 2 == 0:
                dr.rectangle([c*cw, 16+r*rh+rh-5, (c+1)*cw, 16+r*rh+rh-2], fill=(0,0,0,46))
            dr.rectangle([x-2, y-2, x+w+2, y+h+2], fill=(235,238,242))
            lit = random.random()
            if glass:
                col = (255,217,138) if lit < 0.16 else (int(150+lit*60), int(180+lit*40), int(210+lit*30))
            else:
                col = (255,217,138) if lit < 0.2 else ((255,240,189) if lit < 0.34 else ((84,112,140) if lit < 0.5 else (44,62,82)))
            dr.rectangle([x, y, x+w, y+h], fill=col)
            if kind == "brick" and random.random() < 0.16:
                dr.rectangle([x, y+h+3, x+12, y+h+9], fill=(207,212,217))
    dr.rectangle([0, 452, 256, 512], fill=(15,20,30))
    for sx in (8, 96, 184):
        dr.rectangle([sx, 464, sx+64, 500], fill=(70,84,102))
    if random.random() < 0.75:
        dr.rectangle([0, 444, 256, 454], fill=random.choice([(226,87,76),(240,161,58),(63,157,99),(74,127,201)]))
    im.save(A+f"facade_{kind}.png")

facade("glass",  ((127,168,201),(85,119,158)), glass=True)
facade("tower",  ((77,96,118),(57,72,92)), glass=True)
facade("brick",  ((154,106,88),(125,83,67)))
facade("home",   ((176,154,125),(143,121,94)))
facade("office", ((141,153,166),(110,122,136)))

# ---------- 招牌 ----------
shops = ["南炉烤肉饭","桂雨茶饮","长街米粉","槐花饺子馆","夜市烧烤摊","学府食堂","白领便当","河畔咖啡"]
font = ImageFont.truetype(FONT, 34)
for i, name in enumerate(shops):
    im = Image.new("RGB", (256, 64), (32,48,63))
    dr = ImageDraw.Draw(im)
    dr.rectangle([0, 56, 256, 64], fill=(255,211,77))
    bb = dr.textbbox((0, 0), name, font=font)
    dr.text(((256-(bb[2]-bb[0]))/2, (52-(bb[3]-bb[1]))/2-4), name, font=font, fill=(255,255,255))
    im.save(A+f"sign_{i}.png")
print("textures done")
