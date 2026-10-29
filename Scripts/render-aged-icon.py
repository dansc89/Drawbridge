#!/usr/bin/env python3
"""Deterministically build Drawbridge's aged-metal icon from editable vector art.

Run from the repository root with:
    uv run --with cairosvg --with pillow --with numpy python Scripts/render-aged-icon.py
Assets/Drawbridge-base.svg is the vector source; the generated SVG embeds its
organic oxidation layer so the GitHub SVG and packaged PNG look identical.
"""
from __future__ import annotations

import base64
import io
from pathlib import Path

import cairosvg
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Assets"
SIZE = 1024
SEED = 1957
rng = np.random.default_rng(SEED)


def cloud(scale: int) -> np.ndarray:
    """Smooth, seeded multi-scale color variation without repeating tiles."""
    field = (rng.random((scale, scale)) * 255).astype(np.uint8)
    im = Image.fromarray(field, mode="L").resize((SIZE, SIZE), Image.Resampling.BICUBIC)
    return np.asarray(im, dtype=np.float32) / 255.0


# Broad uneven oxidation, small pits and a brushed-metal micrograin.
coarse = cloud(12) * .38 + cloud(30) * .32 + cloud(72) * .20 + cloud(180) * .10
fine = cloud(115) * .60 + cloud(310) * .40
small = rng.random((SIZE, SIZE)).astype(np.float32)
y, x = np.ogrid[:SIZE, :SIZE]
edge = np.minimum.reduce(np.broadcast_arrays(x, y, SIZE - 1 - x, SIZE - 1 - y)).astype(np.float32)
edge_wear = np.clip((245 - edge) / 245, 0, 1) ** 1.35
# A few irregular colonies favor the lower corners and rim, not the emblem.
oxidation = np.clip((coarse - .495) * 5.3 + (fine - .5) * .55, 0, 1)
oxide_alpha = np.clip((oxidation ** 1.45) * (31 + 95 * edge_wear), 0, 100).astype(np.uint8)
# Fine bronze/gold mottling and tiny pits read as metal rather than a flat orange tile.
worn = np.clip((.49 - coarse) * 4.8 + (fine - .51) * .35, 0, 1)
gold_alpha = np.clip(worn ** 1.65 * (14 + 40 * edge_wear), 0, 54).astype(np.uint8)
pepper = np.clip((fine - .53) * 1.4 + (small - .50) * .27, 0, 1)
oxide_alpha = np.clip(oxide_alpha.astype(np.float32) + pepper * (4 + 15 * edge_wear), 0, 110).astype(np.uint8)

rust = np.empty((SIZE, SIZE, 4), dtype=np.uint8)
rust[:, :, :3] = (93, 49, 36)
rust[:, :, 3] = oxide_alpha
layer = Image.fromarray(rust, "RGBA")
gold = np.empty_like(rust)
gold[:, :, :3] = (252, 216, 137)
gold[:, :, 3] = gold_alpha
layer = Image.alpha_composite(layer, Image.fromarray(gold, "RGBA"))

# A restrained mineral tint at the rim suggests oxidized copper without turning the icon green.
mineral = np.clip((cloud(28) - .64) * 5, 0, 1) * edge_wear
verdigris = np.empty_like(rust)
verdigris[:, :, :3] = (82, 110, 96)
verdigris[:, :, 3] = np.clip(mineral * 78, 0, 55).astype(np.uint8)
layer = Image.alpha_composite(layer, Image.fromarray(verdigris, "RGBA"))

# Realistic local abrasions: tiny dark pits and hairline worn-gold scuffs.
pitting = Image.new("RGBA", (SIZE, SIZE))
draw = ImageDraw.Draw(pitting)
for _ in range(3000):
    px = float(rng.uniform(28, 996))
    py = float(rng.uniform(28, 996))
    distance = min(px, py, 1024 - px, 1024 - py)
    if distance > 200 and rng.random() < .68:
        continue
    radius = float(rng.uniform(.35, 1.65))
    draw.ellipse((px - radius, py - radius, px + radius, py + radius), fill=(68, 41, 31, int(rng.integers(21, 83))))
for _ in range(155):
    px = float(rng.uniform(35, 990))
    py = float(rng.uniform(35, 990))
    distance = min(px, py, 1024 - px, 1024 - py)
    if distance > 225 and rng.random() < .62:
        continue
    length = float(rng.uniform(3, 16))
    draw.line((px, py, px + length, py + float(rng.uniform(-1.5, 1.5))), fill=(255, 227, 153, int(rng.integers(22, 60))), width=1)
layer = Image.alpha_composite(layer, pitting)
# Suppress tiny features outside the tile via the SVG's rounded clipping path.
buffer = io.BytesIO()
layer.save(buffer, format="PNG", optimize=True)
encoded = base64.b64encode(buffer.getvalue()).decode("ascii")
svg_template = (ASSETS / "Drawbridge-base.svg").read_text()
marker = "<!-- AGED_METAL_TEXTURE -->"
assert svg_template.count(marker) == 1, "base SVG must have one texture marker"
image = f'<image x="23" y="23" width="978" height="978" preserveAspectRatio="none" href="data:image/png;base64,{encoded}"/>'
svg = svg_template.replace(marker, image)
(ASSETS / "Drawbridge.svg").write_text(svg)
# Oversampling keeps the emblem and rounded perimeter crisp at Dock sizes.
png = cairosvg.svg2png(bytestring=svg.encode(), output_width=2048, output_height=2048)
master = Image.open(io.BytesIO(png)).convert("RGBA").resize((SIZE, SIZE), Image.Resampling.LANCZOS)
master.save(ASSETS / "db.png", optimize=True)
iconset = ASSETS / "AppIcon.iconset"
iconset.mkdir(exist_ok=True)
for sz in (16, 32, 64, 128, 256, 512, 1024):
    result = master if sz == SIZE else master.resize((sz, sz), Image.Resampling.LANCZOS)
    result.save(iconset / f"icon_{sz}x{sz}.png", optimize=True)
for sz in (16, 32, 128, 256, 512):
    doubled = sz * 2
    (iconset / f"icon_{sz}x{sz}@2x.png").write_bytes((iconset / f"icon_{doubled}x{doubled}.png").read_bytes())
print(f"Built SVG, 1024px PNG, and {len(list(iconset.glob('*.png')))} iconset images")
