import re

with open('Cargo.lock', 'r') as f:
    content = f.read()

# Remove all checksum = "..." lines
new_content = re.sub(r'checksum = ".*"\n', '', content)

with open('Cargo.lock', 'w') as f:
    f.write(new_content)
