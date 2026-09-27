#!/usr/bin/env python3
"""
Generate standard macOS AppIcon (.icns) for Echo Voice using the modern vector-styled master icon.
"""

import os
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFilter

def generate_icon(master_image_path: str, output_icns_path: str, project_root: str):
    im = Image.open(master_image_path).convert('RGBA')
    # Crop squircle bounds (centered at 512, 512, width/height ~ 772)
    crop = im.crop((126, 126, 898, 898))

    # Standard Apple macOS app icon: 824x824 centered in 1024x1024 canvas
    squircle_size = 824
    resized_squircle = crop.resize((squircle_size, squircle_size), Image.Resampling.LANCZOS)

    # 4x supersampled mask for ultra-smooth antialiased corners
    scale = 4
    mask_large = Image.new('L', (squircle_size * scale, squircle_size * scale), 0)
    draw_mask = ImageDraw.Draw(mask_large)
    radius = int(185 * scale)
    draw_mask.rounded_rectangle([0, 0, squircle_size * scale, squircle_size * scale], radius=radius, fill=255)
    mask = mask_large.resize((squircle_size, squircle_size), Image.Resampling.LANCZOS)

    masked_squircle = Image.new('RGBA', (squircle_size, squircle_size), (0, 0, 0, 0))
    masked_squircle.paste(resized_squircle, (0, 0), mask)

    # 1024x1024 Canvas with Apple HIG drop shadow
    canvas = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    shadow = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    shadow_mask = Image.new('L', (squircle_size, squircle_size), 0)
    shadow_draw = ImageDraw.Draw(shadow_mask)
    shadow_draw.rounded_rectangle([0, 0, squircle_size, squircle_size], radius=185, fill=100)
    shadow_color = Image.new('RGBA', (squircle_size, squircle_size), (0, 0, 0, 120))
    shadow_squircle = Image.new('RGBA', (squircle_size, squircle_size), (0, 0, 0, 0))
    shadow_squircle.paste(shadow_color, (0, 0), shadow_mask)

    shadow.paste(shadow_squircle, (100, 114))
    shadow = shadow.filter(ImageFilter.GaussianBlur(16))

    canvas.paste(shadow, (0, 0), shadow)
    canvas.paste(masked_squircle, (100, 100), masked_squircle)

    iconset_dir = os.path.join(project_root, 'tmp', 'EchoVoice.iconset')
    os.makedirs(iconset_dir, exist_ok=True)

    sizes = [
        ('icon_16x16.png', 16),
        ('icon_16x16@2x.png', 32),
        ('icon_32x32.png', 32),
        ('icon_32x32@2x.png', 64),
        ('icon_128x128.png', 128),
        ('icon_128x128@2x.png', 256),
        ('icon_256x256.png', 256),
        ('icon_256x256@2x.png', 512),
        ('icon_512x512.png', 512),
        ('icon_512x512@2x.png', 1024),
    ]

    for filename, sz in sizes:
        resized = canvas.resize((sz, sz), Image.Resampling.LANCZOS)
        resized.save(os.path.join(iconset_dir, filename))

    subprocess.run(['iconutil', '-c', 'icns', iconset_dir, '-o', output_icns_path], check=True)
    print(f"Compiled icns successfully to {output_icns_path}")

if __name__ == '__main__':
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    master = os.path.join(root, 'tmp', 'icon_master.jpg')
    if len(sys.argv) > 1:
        master = sys.argv[1]
    out = os.path.join(root, 'Resources', 'EchoVoice.icns')
    if len(sys.argv) > 2:
        out = sys.argv[2]
    generate_icon(master, out, root)
