#!/bin/zsh
# 编译「放映」，自测通过后装到 /Applications 并打开。
# 只打包不安装：FANGYING_STAGE_ONLY=1 ./重新构建.command（产物在 .build/放映.app；正式安装后这份会删掉）
# 跳过自测：FANGYING_SKIP_TEST=1
# 设成所有视频的默认播放器：FANGYING_SET_DEFAULT=1；在桌面放一个替身：FANGYING_DESKTOP_ALIAS=1（放过之后每次构建自动刷新）
set -euo pipefail
project_dir="${0:A:h}"
build_dir="$project_dir/.build"
staged_app="$build_dir/放映.app"
installed_app="/Applications/放映.app"
contents="$staged_app/Contents"
brew=/opt/homebrew
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ ! -f "$brew/include/mpv/client.h" ]]; then
    print -r -- "缺 mpv：先运行 brew install mpv"
    exit 1
fi

mkdir -p "$build_dir"
rm -rf "$staged_app" "$build_dir/Fangying.iconset"
mkdir -p "$build_dir/Fangying.iconset" "$contents/MacOS" "$contents/Resources" "$contents/Frameworks"

print -r -- "正在编译放映……"
/usr/bin/clang -c -O2 -mmacosx-version-min=27.0 -I"$brew/include" "$project_dir/Support/thumb.c" -o "$build_dir/thumb.o"
if ! /usr/bin/xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx27.0 \
        -import-objc-header "$project_dir/Support/Bridge.h" -Xcc -I"$brew/include" \
        -L"$brew/lib" -lmpv -lavformat -lavcodec -lavutil -lswscale \
        -framework AppKit -framework OpenGL -framework MediaPlayer -framework IOKit -framework CoreImage \
        "$project_dir"/Sources/*.swift "$build_dir/thumb.o" -o "$build_dir/Fangying" > "$build_dir/编译.log" 2>&1; then
    grep -E "error" "$build_dir/编译.log" || cat "$build_dir/编译.log"
    exit 1
fi

if [[ -z "${FANGYING_SKIP_TEST:-}" ]]; then
    "$build_dir/Fangying" --self-test
fi

cp "$build_dir/Fangying" "$contents/MacOS/Fangying"
cp "$project_dir/Info.plist" "$contents/Info.plist"
"$build_dir/Fangying" --make-icon "$build_dir/icon-1024.png"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$build_dir/icon-1024.png" --out "$build_dir/Fangying.iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$(( size * 2 ))
    /usr/bin/sips -z "$doubled" "$doubled" "$build_dir/icon-1024.png" --out "$build_dir/Fangying.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$build_dir/Fangying.iconset" -o "$contents/Resources/Fangying.icns"

# mpv、FFmpeg 和它们依赖的库拷进包里，改成包内路径
/usr/bin/python3 -I "$project_dir/Support/bundle_libs.py" "$contents"

/usr/bin/plutil -lint "$contents/Info.plist" >/dev/null
for f in "$contents/Frameworks/"*.dylib; do
    /usr/bin/codesign --force --sign - --timestamp=none "$f" 2>/dev/null
done
/usr/bin/codesign --force --sign - --timestamp=none --requirements '=designated => identifier "local.fangying"' "$staged_app"
/usr/bin/codesign --verify --strict -R '=identifier "local.fangying"' "$staged_app"
# 改过库路径之后跑一下包里的程序，确认库都能从包里加载
"$contents/MacOS/Fangying" --self-test bundle

if [[ -n "${FANGYING_STAGE_ONLY:-}${SOFTWARE_SYNC_STAGE_ONLY:-}" ]]; then
    print -r -- "已打包：$staged_app"
    exit 0
fi

/usr/bin/osascript -e 'tell application id "local.fangying" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$installed_app"
/usr/bin/ditto --norsrc --noextattr "$staged_app" "$installed_app"
/usr/bin/codesign --verify --strict -R '=identifier "local.fangying"' "$installed_app"
# 只让系统认 /Applications 里这一份：~/Applications 下的 app 系统会自动登记，留着打包产物「打开方式」里会出现两个放映
"$lsregister" -u "$staged_app" >/dev/null 2>&1 || true
rm -rf "$staged_app"
"$lsregister" -f "$installed_app"
if [[ -n "${FANGYING_SET_DEFAULT:-}" ]]; then
    "$installed_app/Contents/MacOS/Fangying" --set-default
fi
if [[ -n "${FANGYING_DESKTOP_ALIAS:-}" || -e "$HOME/Desktop/放映" ]]; then
    "$installed_app/Contents/MacOS/Fangying" --desktop-alias
fi
/usr/bin/open "$installed_app"
print -r -- "已安装并打开：$installed_app"
