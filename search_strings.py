import os
import re

def search_strings(directory):
    # Regex for printable ascii strings of length >= 6
    string_pattern = re.compile(b'[ -~]{6,}')
    
    for root, _, files in os.walk(directory):
        for file in files:
            path = os.path.join(root, file)
            try:
                with open(path, 'rb') as f:
                    content = f.read()
                    
                strings = string_pattern.findall(content)
                for s in strings:
                    try:
                        s_str = s.decode('utf-8')
                        if '186.186.49.189' in s_str or '192.168.' in s_str or '101.3.4.1' in s_str or 'direct' in s_str.lower() or 'ip' in s_str.lower():
                            if '186.186.49.189' in s_str or '192.168.' in s_str:
                                print(f"Found IP in {file}: {s_str}")
                            if 'direct' in s_str.lower() and ('tcp' in s_str.lower() or 'connection' in s_str.lower() or 'ip' in s_str.lower()):
                                # print(f"Found 'direct' in {file}: {s_str}")
                                pass
                    except:
                        pass
            except Exception as e:
                pass

if __name__ == "__main__":
    search_strings('temp_apk')
