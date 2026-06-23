import os

vendor_dir = 'libs/vendor'
for root, dirs, files in os.walk(vendor_dir):
    if root == vendor_dir:
        for d in dirs:
            checksum_path = os.path.join(root, d, '.cargo-checksum.json')
            with open(checksum_path, 'w') as f:
                f.write('{"files":{}}')
        break # Only top-level directories in libs/vendor
