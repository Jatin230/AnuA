import re

def extract_dart_strings(path):
    string_pattern = re.compile(b'[ -~]{6,}')
    
    try:
        with open(path, 'rb') as f:
            content = f.read()
            
        strings = string_pattern.findall(content)
        for s in strings:
            try:
                s_str = s.decode('utf-8')
                if 'direct' in s_str.lower() or 'ip' in s_str.lower() or re.match(r'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}', s_str):
                    print(s_str)
            except:
                pass
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    extract_dart_strings('temp_apk/lib/arm64-v8a/libapp.so')
