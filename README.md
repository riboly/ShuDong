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
**ShuDong-dylib** 里（`ShuDong.dylib` 与 `ShuDong.zip`）。打 `v*` tag 会同时发一个 Release。

本地（需 macOS + Xcode）：

```bash
brew install ldid
bash build.sh          # 输出 build/ShuDong.dylib
```

## 安装

### TrollFools（推荐，无需越狱环境依赖）

1. 下载 artifact 里的 `ShuDong.dylib`；
2. 传到手机（AirDrop / 文件 app 均可）；
3. TrollFools → 选择「树洞」→ 注入 → 选中 `ShuDong.dylib`；
4. 重新打开树洞。

### 越狱环境（rootless / roothide）

把 dylib 放到 `/var/jb/usr/lib/TweakInject/ShuDong.dylib`，
并配套一个同名 plist：

```xml
<dict>
  <key>Filter</key>
  <dict>
    <key>Bundles</key>
    <array><string>co.whou.pick</string></array>
  </dict>
</dict>
```

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
src/ShuDongPatch.m        插件本体（补丁表 + swizzling）
build.sh                  编译脚本（clang + lipo + ldid）
.github/workflows/build.yml  GitHub Actions 编译流程
```

针对树洞 2.2.965 验证；仅供个人学习与自用。
