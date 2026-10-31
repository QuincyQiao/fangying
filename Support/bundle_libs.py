"""把可执行文件依赖的 Homebrew 动态库（mpv、FFmpeg 和它们再依赖的）拷进 app 包的 Frameworks，
并把引用改成包内相对路径，装好的 app 不再依赖 Homebrew。

用法：python3 -I bundle_libs.py <放映.app/Contents>
"""
import os
import shutil
import subprocess
import sys

contents = sys.argv[1]
exe = os.path.join(contents, "MacOS", "Fangying")
fw = os.path.join(contents, "Frameworks")
os.makedirs(fw, exist_ok=True)
SYSTEM = ("/System/", "/usr/lib/")


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def own_id(path):
    lines = run("otool", "-D", path).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def deps(path):
    me = own_id(path)
    out = []
    for line in run("otool", "-L", path).splitlines()[1:]:
        d = line.strip().split(" (")[0]
        if d and d != me:
            out.append(d)
    return out


def rpaths(path):
    lines = run("otool", "-l", path).splitlines()
    found = []
    for i, line in enumerate(lines):
        if "cmd LC_RPATH" in line:
            found.append(lines[i + 2].strip().split()[1])
    return found


def resolve(dep, origin):
    """origin 是引用它的那个文件在 Homebrew 里的真实路径。"""
    if dep.startswith(SYSTEM):
        return None
    if dep.startswith("/"):
        return os.path.realpath(dep)
    here = os.path.dirname(origin)
    if dep.startswith("@loader_path/"):
        return os.path.realpath(os.path.join(here, dep[len("@loader_path/"):]))
    if dep.startswith("@rpath/"):
        name = dep[len("@rpath/"):]
        for rp in rpaths(origin):
            cand = os.path.join(rp.replace("@loader_path", here), name)
            if os.path.exists(cand):
                return os.path.realpath(cand)
        cand = os.path.join("/opt/homebrew/lib", os.path.basename(name))
        if os.path.exists(cand):
            return os.path.realpath(cand)
    sys.exit(f"找不到 {dep}（被 {origin} 引用）")


copied = {}


def process(binary, origin, prefix):
    for dep in deps(binary):
        src = resolve(dep, origin)
        if src is None:
            continue
        name = os.path.basename(dep)
        if name not in copied:
            copied[name] = src
            dst = os.path.join(fw, name)
            shutil.copy2(src, dst)
            os.chmod(dst, 0o755)
            run("install_name_tool", "-id", f"@rpath/{name}", dst)
            process(dst, src, "@loader_path")
        run("install_name_tool", "-change", dep, f"{prefix}/{name}", binary)


process(exe, exe, "@executable_path/../Frameworks")

left = []
for f in [exe] + [os.path.join(fw, n) for n in copied]:
    for d in deps(f):
        if d.startswith(("/opt/homebrew", "/usr/local")):
            left.append(f"{os.path.basename(f)} → {d}")
if left:
    sys.exit("包里还有指向 Homebrew 的库：\n" + "\n".join(left))
size = sum(os.path.getsize(os.path.join(fw, n)) for n in copied)
print(f"拷进 {len(copied)} 个库，共 {size / 1e6:.0f} MB")
