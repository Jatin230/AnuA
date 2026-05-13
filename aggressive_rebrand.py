import os
import re

def replace_in_file(filepath, replacements):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception:
        return False
    
    new_content = content
    for old, new in replacements.items():
        new_content = new_content.replace(old, new)
    
    if new_content != content:
        try:
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(new_content)
            return True
        except Exception:
            return False
    return False

def walk_and_replace(directory, includes, replacements):
    count = 0
    if not os.path.exists(directory):
        return 0
    for root, dirs, files in os.walk(directory):
        for file in files:
            if any(file.endswith(ext) for ext in includes):
                if replace_in_file(os.path.join(root, file), replacements):
                    count += 1
    return count

replacements = {
    "RustDesk": "Anuvadini",
    "rustdesk": "anuvadini",
}

dirs_to_rebrand = [
    'flutter/lib',
    'src',
    'libs/hbb_common',
    'flutter/windows/runner',
    'flutter/android/app',
    'flutter/ios/Runner',
]

total_updated = 0
for d in dirs_to_rebrand:
    c = walk_and_replace(d, ['.dart', '.rs', '.cpp', '.h', '.rc', '.xml', '.plist'], replacements)
    print(f"Updated {c} files in {d}")
    total_updated += c

print(f"Total files updated: {total_updated}")
