import os
import subprocess

# 配置代理
os.environ['http_proxy'] = 'http://127.0.0.1:7890'
os.environ['https_proxy'] = 'http://127.0.0.1:7890'

cache_dir = os.path.expanduser("~/.cache/zig/p")

extra_deps = [
    ("https://github.com/ivanstepanovftw/zigimg/archive/d7b7ab0ba0899643831ef042bd73289510b39906.tar.gz", "zigimg-0.1.0-8_eo2vHnEwCIVW34Q14Ec-xUlzIoVg86-7FU2ypPtxms"),
    ("https://github.com/jacobsandlund/uucode/archive/5f05f8f83a75caea201f12cc8ea32a2d82ea9732.tar.gz", "uucode-0.1.0-ZZjBPj96QADXyt5sqwBJUnhaDYs_qBeeKijZvlRa0eqM")
]

def download_and_extract(url, hash_val):
    target_path = os.path.join(cache_dir, hash_val)
    if os.path.exists(target_path):
        print(f"Skipping {hash_val}, already exists.")
        return

    print(f"Downloading {url}...")
    temp_file = f"{hash_val}.tar.gz"
    
    subprocess.run(["curl", "-x", "http://127.0.0.1:7890", "-L", url, "-o", temp_file], check=True)
    os.makedirs(target_path, exist_ok=True)
    
    print(f"Extracting to {target_path}...")
    # --strip-components=1 很有必要，因为 github 压缩包包含一层顶级文件夹
    subprocess.run(["tar", "-xf", temp_file, "-C", target_path, "--strip-components=1"], check=True)
    os.remove(temp_file)

if __name__ == "__main__":
    for url, hash_val in extra_deps:
        try:
            download_and_extract(url, hash_val)
        except Exception as e:
            print(f"Failed to process {url}: {e}")
