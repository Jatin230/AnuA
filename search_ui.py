import os
import re

def search_ui(directory):
    string_pattern = re.compile(b'[ -~]{6,}')
    
    with open('ui_strings.txt', 'w', encoding='utf-8') as out:
        for root, _, files in os.walk(directory):
            for file in files:
                path = os.path.join(root, file)
                try:
                    with open(path, 'rb') as f:
                        content = f.read()
                        
                    strings = string_pattern.findall(content)
                    for s in strings:
                        s_str = s.decode('utf-8', errors='ignore')
                        if 'direct ' in s_str.lower() or ' ip ' in s_str.lower() or 'connection' in s_str.lower() or '192.168.' in s_str or '186.186' in s_str:
                            out.write(f"{file}: {s_str}\n")
                except Exception as e:
                    pass

if __name__ == "__main__":
    search_ui('temp_apk/lib/arm64-v8a')
