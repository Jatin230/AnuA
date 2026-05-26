import os
import re

def find_ips(directory):
    ip_pattern = re.compile(b'\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b')
    ip_pattern2 = re.compile(rb'(?:[0-9]{1,3}\.){3}[0-9]{1,3}')
    
    found_ips = set()
    
    for root, _, files in os.walk(directory):
        for file in files:
            path = os.path.join(root, file)
            try:
                with open(path, 'rb') as f:
                    content = f.read()
                    for match in ip_pattern2.findall(content):
                        ip = match.decode('utf-8', errors='ignore')
                        # filter valid ips
                        parts = ip.split('.')
                        if len(parts) == 4 and all(0 <= int(p) <= 255 for p in parts):
                            found_ips.add(ip)
            except Exception as e:
                pass
                
    for ip in sorted(list(found_ips)):
        if ip not in ['0.0.0.0', '127.0.0.1', '1.1.1.1', '8.8.8.8', '8.8.4.4', '255.255.255.255', '224.0.0.251', '239.255.255.250']:
            print(ip)

if __name__ == "__main__":
    find_ips('temp_apk')
