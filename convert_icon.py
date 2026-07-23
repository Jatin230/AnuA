from PIL import Image
import os

source = r"C:\Users\jatin\Downloads\WhatsApp Image 2026-07-21 at 2.50.34 PM.jpeg"
res_dir = r"C:\Users\jatin\Downloads\rustdesk\flutter\android\app\src\main\res"

sizes = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

img = Image.open(source)
# center crop to square
size = min(img.size)
left = (img.width - size) // 2
top = (img.height - size) // 2
img = img.crop((left, top, left + size, top + size))

for folder, px in sizes.items():
    resized = img.resize((px, px), Image.LANCZOS)
    for name in ["ic_launcher.png", "ic_launcher_round.png", "ic_launcher_foreground.png"]:
        path = os.path.join(res_dir, folder, name)
        if os.path.exists(path):
            resized.save(path)
            print(f"Updated {path} ({px}x{px})")

print("Done!")
