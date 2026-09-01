# ShuDong 增强插件

给 iOS 应用 **树洞**（bundle id `co.whou.pick`）的增强插件，编译产物为 `ShuDong.dylib`，
由 GitHub Actions 在 macOS runner 上用 iphoneos SDK 编译（arm64 + arm64e，ldid 临时签名）。

## 功能

| 功能 | 说明 |
| --- | --- |
| 移除"重要提示" | 首页对话列表顶部那条置顶的"重要提示"（保留 id `-1` 的伪好友）不再显示 |
| 显示好友真实 id | 对话列表每一行的昵称后面追加 ` [真实friendId]` |

## 实现原理

树洞是 React Native 应用，界面全部由 `main.jsbundle`（未经 Hermes 编译的普通 Metro 打包）里的
JavaScript 绘制，所以 hook UIKit 没有意义。插件的做法是：

1. 启动时（`__attribute__((constructor))`）读取 app 包内原始 `main.jsbundle`；
2. 对压缩后的 JS 做两处最小化文本替换：
   - 列表数据源 `cloneWithRows(...)` 外面套一层 `.filter(row => row.friendId !== "-1")`；
   - 列表行的 `NameText` 补上它自己已支持的 `appends` 属性，值为 `" [" + friendId + "]"`；
3. 把补丁结果写到 app 自己的 Caches 目录 `Library/Caches/ShuDongTweak/main.patched.jsbundle`；
4. 用 Objective-C runtime swizzling 把 RN 启动时查找/读取 bundle 的 API 重定向到补丁副本：
   `-[NSBundle URLForResource:withExtension:]`、`-[NSBundle pathForResource:ofType:]`、
   `+[NSData dataWithContentsOfFile:(options:error:)]`、`+[NSData dataWithContentsOfURL:(options:error:)]`、
   `+[NSFileHandle fileHandleForReadingFromURL:error:]`。

要点：

- **不修改 app 包内任何文件**，只在 Caches 里放补丁副本，卸载插件即恢复原状；
- **不依赖 CydiaSubstrate / ElleKit**，纯 `method_setImplementation`，因此既能用 TrollFools 注入，
  也能打包成普通 `.deb` 插件；
- 补丁结果按「补丁版本 + 原 bundle 大小 + mtime」做缓存（`main.patched.stamp`），app 升级后自动重打；
- 只在 `bundleIdentifier == co.whou.pick` 时生效，其它进程直接返回；
- 任何一条锚点都匹配不上时（app 更新导致 JS 变化）放弃打补丁、不安装 hook，app 以原始状态运行。

## 编译

推送到 `main` / `master`，或在 Actions 页面手动 `workflow_dispatch`，产物在 artifact
**ShuDong-dylib** 里：

| 文件 | 用途 |
| --- | --- |
| `ShuDong.dylib` | 裸 dylib（TrollFools 注入用，需要已脱壳的 app） |
| `ShuDong_1.0.0_iphoneos-arm64e.deb` | **roothide Dopamine**（推荐） |
| `ShuDong_1.0.0_iphoneos-arm64.deb` | rootless Dopamine / ElleKit（`/var/jb`） |

打 `v*` tag 会同时发一个 Release。

本地（需 macOS + Xcode）：

```bash
brew install ldid dpkg
bash build.sh          # 输出 build/ 下的 dylib 与两个 deb
```

## 安装

### 越狱环境（推荐，deb）

树洞是 App Store 下载的正版包，主二进制 `whou` 带 FairPlay 加密。ElleKit/Substrate 这类
越狱注入走的是 `DYLD_INSERT_LIBRARIES`，**完全不需要改动 app 二进制**，所以加密无所谓：

```bash
# roothide Dopamine
dpkg -i ShuDong_1.0.0_iphoneos-arm64e.deb
# rootless
dpkg -i ShuDong_1.0.0_iphoneos-arm64.deb
```

也可以直接用 Sileo/Zebra「从文件安装」。装完 postinst 会清掉旧缓存并 `killall -9 whou`，
重开树洞即生效。卸载：`dpkg -r com.riboly.shudong`。

deb 里的内容（路径相对 jbroot，dpkg 自己会加前缀）：

```
usr/lib/TweakInject/ShuDong.dylib
usr/lib/TweakInject/ShuDong.plist   # Filter -> Bundles -> co.whou.pick
```

### TrollFools（需要先脱壳）

TrollFools 是往 app 的 Mach-O 里写一条 `LC_LOAD_DYLIB`，因此**必须能改写主二进制**。
对 FairPlay 加密的 App Store 包它会直接拒绝：

```
ERROR: No unencrypted target Mach-O is available.
```

这条报错说的是树洞自己的二进制，跟本 dylib 无关（同一份报告里 dylib 已被正常解析：
`[arm64, arm64e] installName=@rpath/ShuDong.dylib minOS=14.0.0 platform=iOS`）。要走
TrollFools 就得先在越狱环境里用脱壳工具（如 `trollfools` 自带的 dump、`iGameGod`、
`flexdecrypt`、`bagbak` 等）导出脱壳 IPA 重签安装，再对脱壳后的 app 注入。

**越狱机上直接装 deb 更省事，不需要脱壳。**

## 排查

插件会把每一步写进日志：

```
<树洞数据目录>/Library/Caches/ShuDongTweak/patch.log
```

正常内容形如：

```
patch hide-important-tip: 1 replacement(s)
patch show-friend-id: 1 replacement(s)
patched bundle written: .../main.patched.jsbundle (... -> ... chars)
hooks installed, serving .../main.patched.jsbundle
```

同时所有日志都会用 `[ShuDong]` 前缀走 `NSLog`，可以用 `idevicesyslog` / Console.app 实时看。

如果日志里出现 `no patch matched`，说明树洞更新后 JS 变了，需要重新定位锚点并更新
`src/ShuDongPatch.m` 里的 `kPatches` 表（同时把 `kPatchVersion` 加一以让缓存失效）。

## 目录

```
src/ShuDongPatch.m           插件本体（补丁表 + swizzling）
layout/DEBIAN/               deb 控制文件（control / postinst / postrm）
layout/usr/lib/TweakInject/  ShuDong.plist（Bundle 过滤器）
build.sh                     编译脚本（clang + lipo + ldid + dpkg-deb）
.github/workflows/build.yml  GitHub Actions 编译流程
```

针对树洞 2.2.965 验证；仅供个人学习与自用。
