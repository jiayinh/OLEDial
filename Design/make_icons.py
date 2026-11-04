#!/usr/bin/env python3
"""Regenerates OLEDial's icons from scratch.
Requires: rsvg-convert (librsvg) and Pillow.  Usage: python3 Design/make_icons.py
Outputs: Design/*.svg, Resources/AppIcon.icns, Resources/MenuBarIcon*.png
"""
import math, os, subprocess, tempfile
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DESIGN, RES = os.path.join(ROOT, "Design"), os.path.join(ROOT, "Resources")

def pt(cx, cy, r, deg):
    a = math.radians(deg); return cx + r * math.cos(a), cy + r * math.sin(a)

def arc(cx, cy, r, a0, a1):
    (x0, y0), (x1, y1) = pt(cx, cy, r, a0), pt(cx, cy, r, a1)
    large = 1 if a1 - a0 > 180 else 0
    return f"M{x0:.2f} {y0:.2f} A{r} {r} 0 {large} 1 {x1:.2f} {y1:.2f}"

START, SWEEP, VALUE = 135, 270, 0.72   # 270° dial, gap at the bottom, ~72% "turned up"

# ---- App icon: the "O" of OLEDial is a glowing dial around a small TV ----
def app_icon_svg():
    cx, cy, r, w = 512, 512, 250, 56
    av = START + VALUE * SWEEP
    kx, ky = pt(cx, cy, r, av)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2b2f3a"/><stop offset="1" stop-color="#090a0d"/></linearGradient>
  <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".20"/><stop offset=".45" stop-color="#fff" stop-opacity="0"/></linearGradient>
  <linearGradient id="dial" gradientUnits="userSpaceOnUse" x1="{cx-r}" y1="{cy+r}" x2="{cx+r}" y2="{cy-r}">
    <stop offset="0" stop-color="#ff2e7e"/><stop offset=".55" stop-color="#ff8a3d"/><stop offset="1" stop-color="#ffd84a"/></linearGradient>
  <filter id="sh" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#000" flood-opacity=".35"/></filter>
  <filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="16"/></filter>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)" filter="url(#sh)"/>
<rect x="101.5" y="101.5" width="821" height="821" rx="183.5" fill="none" stroke="url(#sheen)" stroke-width="3"/>
<path d="{arc(cx,cy,r,START,START+SWEEP)}" fill="none" stroke="#262a33" stroke-width="{w}" stroke-linecap="round"/>
<path d="{arc(cx,cy,r,START,av)}" fill="none" stroke="url(#dial)" stroke-width="{w}" stroke-linecap="round" filter="url(#glow)" opacity=".75"/>
<path d="{arc(cx,cy,r,START,av)}" fill="none" stroke="url(#dial)" stroke-width="{w}" stroke-linecap="round"/>
<circle cx="{kx:.2f}" cy="{ky:.2f}" r="{w*0.62:.1f}" fill="#fff"/>
<rect x="398" y="448" width="228" height="128" rx="18" fill="#000" stroke="#e9ecf3" stroke-width="14"/>
<path d="M424 588 L416 610 M600 588 L608 610" stroke="#e9ecf3" stroke-width="14" stroke-linecap="round"/>
</svg>'''

# ---- Menu bar template glyph (black on transparent; macOS tints it) ----
def menubar_svg(connected=True):
    cx, cy, r, w = 32, 32, 25, 5.5
    av = START + VALUE * SWEEP
    kx, ky = pt(cx, cy, r, av)
    track_op = ".3" if connected else ".55"
    value = (f'<path d="{arc(cx,cy,r,START,av)}" fill="none" stroke="#000" stroke-width="{w}" stroke-linecap="round"/>'
             f'<circle cx="{kx:.2f}" cy="{ky:.2f}" r="5" fill="#000"/>') if connected else ""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
<path d="{arc(cx,cy,r,START,START+SWEEP)}" fill="none" stroke="#000" stroke-opacity="{track_op}" stroke-width="{w}" stroke-linecap="round"/>
{value}
<rect x="20" y="25" width="24" height="14" rx="2.5" fill="none" stroke="#000" stroke-width="3.6"/>
<path d="M23 42 L22 45 M41 42 L42 45" stroke="#000" stroke-width="3.2" stroke-linecap="round"/>
</svg>'''

def render(svg_path, size, out):
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), svg_path, "-o", out], check=True)

def main():
    os.makedirs(RES, exist_ok=True)
    files = {"AppIcon.svg": app_icon_svg(), "MenuBarIcon.svg": menubar_svg(True),
             "MenuBarIconOff.svg": menubar_svg(False)}
    for name, svg in files.items():
        open(os.path.join(DESIGN, name), "w").write(svg)

    with tempfile.TemporaryDirectory() as tmp:
        sizes = [1024, 512, 256, 128, 64, 32, 16]
        imgs = []
        for s in sizes:
            p = os.path.join(tmp, f"{s}.png"); render(os.path.join(DESIGN, "AppIcon.svg"), s, p)
            imgs.append(Image.open(p).convert("RGBA"))
        imgs[0].save(os.path.join(RES, "AppIcon.icns"), append_images=imgs[1:])
        imgs[0].save(os.path.join(DESIGN, "AppIcon-1024.png"))

    for base in ("MenuBarIcon", "MenuBarIconOff"):
        render(os.path.join(DESIGN, f"{base}.svg"), 18, os.path.join(RES, f"{base}.png"))
        render(os.path.join(DESIGN, f"{base}.svg"), 36, os.path.join(RES, f"{base}@2x.png"))
    print("Icons written to", RES)

if __name__ == "__main__":
    main()
