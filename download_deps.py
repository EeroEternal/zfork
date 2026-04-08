import os
import subprocess
import tarfile
import urllib.request
import shutil

# 配置代理
# os.environ['http_proxy'] = 'http://127.0.0.1:7890'
# os.environ['https_proxy'] = 'http://127.0.0.1:7890'

deps = [
    ("https://deps.files.ghostty.org/libxev-34fa50878aec6e5fa8f532867001ab3c36fae23e.tar.gz", "libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs"),
    ("https://deps.files.ghostty.org/vaxis-7dbb9fd3122e4ffad262dd7c151d80d863b68558.tar.gz", "vaxis-0.5.1-BWNV_LosCQAGmCCNOLljCIw6j6-yt53tji6n6rwJ2BhS"),
    ("https://deps.files.ghostty.org/z2d-0.10.0-j5P_Hu-6FgBsZNgwphIqh17jDnj8_yPtD8yzjO6PpHRQ.tar.gz", "z2d-0.10.0-j5P_Hu-6FgBsZNgwphIqh17jDnj8_yPtD8yzjO6PpHRQ"),
    ("https://deps.files.ghostty.org/zig_objc-f356ed02833f0f1b8e84d50bed9e807bf7cdc0ae.tar.gz", "zig_objc-0.0.0-Ir_Sp5gTAQCvxxR7oVIrPXxXwsfKgVP7_wqoOQrZjFeK"),
    ("https://deps.files.ghostty.org/zig_js-04db83c617da1956ac5adc1cb9ba1e434c1cb6fd.tar.gz", "zig_js-0.0.0-rjCAV-6GAADxFug7rDmPH-uM_XcnJ5NmuAMJCAscMjhi"),
    ("https://deps.files.ghostty.org/uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9.tar.gz", "uucode-0.2.0-ZZjBPqZVVABQepOqZHR7vV_NcaN-wats0IB6o-Exj6m9"),
    ("https://deps.files.ghostty.org/zig_wayland-1b5c038ec10da20ed3a15b0b2a6db1c21383e8ea.tar.gz", "wayland-0.5.0-dev-lQa1khrMAQDJDwYFKpdH3HizherB7sHo5dKMECfvxQHe"),
    ("https://deps.files.ghostty.org/zf-3c52637b7e937c5ae61fd679717da3e276765b23.tar.gz", "zf-0.10.3-OIRy8RuJAACKA3Lohoumrt85nRbHwbpMcUaLES8vxDnh"),
    ("https://deps.files.ghostty.org/wayland-9cb3d7aa9dc995ffafdbdef7ab86a949d0fb0e7d.tar.gz", "N-V-__8AAKrHGAAs2shYq8UkE6bGcR1QJtLTyOE_lcosMn6t"),
    ("https://gitlab.freedesktop.org/wayland/wayland-protocols/-/archive/1.47/wayland-protocols-1.47.tar.gz", "N-V-__8AAFdWDwA0ktbNUi9pFBHCRN4weXIgIfCrVjfGxqgA"),
    ("https://deps.files.ghostty.org/plasma_wayland_protocols-12207e0851c12acdeee0991e893e0132fc87bb763969a585dc16ecca33e88334c566.tar.gz", "N-V-__8AAKYZBAB-CFHBKs3u4JkeiT4BMvyHu3Y5aaWF3Bbs"),
    ("https://deps.files.ghostty.org/JetBrainsMono-2.304.tar.gz", "N-V-__8AAIC5lwAVPJJzxnCAahSvZTIlG-HhtOvnM1uh-66x"),
    ("https://deps.files.ghostty.org/NerdFontsSymbolsOnly-3.4.0.tar.gz", "N-V-__8AAMVLTABmYkLqhZPLXnMl-KyN38R8UVYqGrxqO26s"),
    ("https://deps.files.ghostty.org/ghostty-themes-release-20260323-152405-a2c7b60.tgz", "N-V-__8AAL6FAwBDPampKgDjoxlJYDIn2jv0VaINS4W6CXJN")
]

# 注意：gobject 是 .tar.zst，处理稍微不同
# 我们先处理 .tar.gz

cache_dir = os.path.expanduser("~/.cache/zig/p")

def download_and_extract(url, hash_val):
    target_path = os.path.join(cache_dir, hash_val)
    if os.path.exists(target_path):
        print(f"Skipping {hash_val}, already exists.")
        return

    print(f"Downloading {url}...")
    temp_file = f"{hash_val}.tar.gz"
    
    # 使用 curl 下载以利用代理
    subprocess.run(["curl", "-x", "http://127.0.0.1:7890", "-L", url, "-o", temp_file], check=True)

    os.makedirs(target_path, exist_ok=True)
    
    print(f"Extracting to {target_path}...")
    # 不同的压缩格式处理
    if url.endswith(".tar.zst"):
        subprocess.run(["tar", "--use-compress-program=zstd", "-xf", temp_file, "-C", target_path, "--strip-components=1"], check=True)
    else:
        # 尝试 strip-components=1 因为 zig 期望目录内容直接在 hash 目录下
        subprocess.run(["tar", "-xf", temp_file, "-C", target_path, "--strip-components=1"], check=True)

    os.remove(temp_file)

if __name__ == "__main__":
    if not os.path.exists(cache_dir):
        os.makedirs(cache_dir)
    
    for url, hash_val in deps:
        try:
            download_and_extract(url, hash_val)
        except Exception as e:
            print(f"Failed to process {url}: {e}")

    # 特殊处理 gobject
    download_and_extract("https://deps.files.ghostty.org/gobject-2025-11-08-23-1.tar.zst", "gobject-0.3.0-Skun7ANLnwDvEfIpVmohcppXgOvg_I6YOJFmPIsKfXk-")
