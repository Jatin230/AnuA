import os
import re

def replace_in_file(filepath, replacement_rules):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception:
        return False
    
    new_content = content
    for pattern, replacement in replacement_rules:
        new_content = pattern.sub(replacement, new_content)
    
    if new_content != content:
        try:
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(new_content)
            return True
        except Exception:
            return False
    return False

def walk_and_replace(directory, includes, replacement_rules):
    count = 0
    if not os.path.exists(directory):
        return 0
    for root, dirs, files in os.walk(directory):
        for file in files:
            if any(file.endswith(ext) for ext in includes):
                if replace_in_file(os.path.join(root, file), replacement_rules):
                    count += 1
    return count

# Case-insensitive replacement rules to catch RustDesk/rustdesk/RUSTDESK and mixed-case misses.
replacement_rules = [
    (re.compile(r'RUSTDESK'), 'ANUVADINI'),
    (re.compile(r'rustdesk'), 'anuvadini'),
    (re.compile(r'RustDesk'), 'Anuvadini'),
    (re.compile(r'com\.rustdesk', re.IGNORECASE), 'com.anuvadini'),
    (re.compile(r'org\.rustdesk', re.IGNORECASE), 'org.anuvadini'),
    (re.compile(r'rustdesk', re.IGNORECASE), 'anuvadini'),
]

# Directories to scan
scan_dirs = ['src', 'flutter/lib', 'flutter/windows', 'libs/hbb_common/src']
# Extensions to scan
extensions = ['.rs', '.dart', '.cpp', '.h', '.cc', '.rc', '.tis', '.js', '.html', '.txt', '.yaml', '.toml']

total_updated = 0
for d in scan_dirs:
    count = walk_and_replace(d, extensions, replacement_rules)
    print(f"Updated {count} files in {d}")
    total_updated += count

print(f"Total files updated: {total_updated}")
