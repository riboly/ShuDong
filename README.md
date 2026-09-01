# ShuDong 增强插件

给 iOS 应用 **树洞**（bundle id `co.whou.pick`）的增强插件，编译产物为 `ShuDong.dylib`，
由 GitHub Actions 在 macOS runner 上用 iphoneos SDK 编译（arm64 + arm64e，ldid 临时签名）。

## 功能

| 功能 | 说明 |
| --- | --- |
| 移除"重要提示" | 首页对话列表顶部那条置顶的"重要提示"（保留 id `-1` 的伪好友）不再显示 |
| 好友个人信息显示完整 id | 好友列表不再显示 ID；进入好友个人信息页可查看完整“用户ID”，点击 ID 即复制 |
| 设置页显示本账号聊天 ID | 账号下面新增“聊天ID”，点击 ID 即复制；其他账号可用此 ID 通过“添加聊天”发起私聊 |
| 添加聊天 | 设置页新增“添加聊天”，输入好友真实 ID 和消息后直接发送一条私聊 |

## 实现原理

树洞是 React Native 应用，界面全部由 JavaScript 绘制（未经 Hermes 编译的普通 Metro 打包），
所以 hook UIKit 没有意义。

**关键点：树洞自带热更新。** 只要 `Documents/dbundle/__hvdown__` 存在，app 运行的就是这份下载
下来的 JS，而不是 app 包里的 `main.jsbundle`（本机上 `__hvdown__` 是 2025-12-24 的，包内那份还是
2024-03-22 的）。所以只改包内 bundle 完全没有效果——这正是上一版明明加载、打补丁、装 hook 都成功
却看不到任何变化的原因。

插件同时处理两个来源：

1. **热更新 bundle（`Documents/dbundle/__hvdown__`、`__hvdown_old__`）** 在 app 自己的沙盒里、
   可写，所以在 dylib constructor 里（即 RN 打开它之前）**直接原地打补丁**。这样不管 RN 用
   `NSData`、`NSFileHandle` 还是 C 层 `fopen`/`mmap` 读取都一样生效。原文件会先备份成
   `<名字>.sdorig`，写完再把 mtime/权限恢复原样。
2. **app 包内 `main.jsbundle`** 在只读的 `.app` 里，所以补丁副本写到
   `Library/Caches/ShuDongTweak/main.patched.jsbundle`，再用 Objective-C runtime swizzling 把
   RN 查找/读取 bundle 的 API 重定向过去：
   `-[NSBundle URLForResource:withExtension:(subdirectory:)]`、
   `-[NSBundle pathForResource:ofType:(inDirectory:)]`、
   `+[NSData dataWithContentsOfFile:(options:error:)]`、`+[NSData dataWithContentsOfURL:(options:error:)]`、
   `+[NSFileHandle fileHandleForReadingFromURL:error:]`、`+[NSFileHandle fileHandleForReadingAtPath:]`、
   `+[NSString stringWithContentsOfFile:encoding:error:]`。

JS 文本替换（8 个内容锚点，均为最小改动并复用 app 自己的机制）：

- 列表数据源 `cloneWithRows(...)` 外面套一层 `.filter(row => row.friendId !== "-1")`；
- 列表行移除旧版本可能写入的 `NameText appends` 好友 ID 后缀，首页仅显示昵称。
- 好友资料页显示完整 ID 并增加复制按钮；设置页显示本账号聊天 ID；
- 设置页增加“添加聊天”入口，并沿用 app 的 `sendShareReply` 管线发送文本。

要点：

- **不修改 app 包内任何文件**；热更新 bundle 会原地改写，但保留 `.sdorig` 备份，
  卸载（`postrm`）时自动还原；
- **不依赖 CydiaSubstrate / ElleKit**，纯 `method_setImplementation`，因此既能用 TrollFools 注入，
  也能打包成普通 `.deb` 插件；
- 原地打补丁是**按内容判断幂等**的（补丁串已存在就跳过），app 再次热更新后下次启动自动重打；
  只读来源的补丁副本按「补丁版本 + 原 bundle 大小 + mtime」缓存（`*.stamp`）；
- 路径全部走 `NSHomeDirectory()` / `NSSearchPathForDirectoriesInDomains()`，所以 Crane 之类的
  容器切换插件换过容器也能命中当前容器；
- 只在 `bundleIdentifier == co.whou.pick` 时生效，其它进程直接返回；
- 任何一条锚点都匹配不上时（app 更新导致 JS 变化）放弃该文件、不改动，app 以原始状态运行；
- 全过程写日志到 `Library/Caches/ShuDongTweak/patch.log`，包括每个 hook 第一次真正生效的记录。

## 编译

推送到 `main` / `master`，或在 Actions 页面手动 `workflow_dispatch`，产物在 artifact
**ShuDong-dylib** 里：

| 文件 | 用途 |
| --- | --- |
| `ShuDong.dylib` | 裸 dylib（TrollFools 注入用，需要已脱壳的 app） |
| `ShuDong_1.0.4_iphoneos-arm64e.deb` | **roothide Dopamine**（推荐） |
| `ShuDong_1.0.4_iphoneos-arm64.deb` | rootless Dopamine / ElleKit（`/var/jb`） |

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
dpkg -i ShuDong_1.0.4_iphoneos-arm64e.deb
# rootless
dpkg -i ShuDong_1.0.4_iphoneos-arm64.deb
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
--- v5 launch, home=/var/mobile/Containers/Data/Application/<uuid>
__hvdown__: patch hide-important-tip -> 1 replacement(s)
__hvdown__: patch remove-friend-id -> 1 replacement(s)
__hvdown__: original backed up to __hvdown__.sdorig
__hvdown__: patched in place (2050096 -> 2050182 chars)
main.jsbundle: patched copy written to .../main.patched.jsbundle (... -> ... chars)
ready: 2 source(s) patched, 1 redirect(s)
```

热更新 bundle 只要出现 `patched in place`（或下次启动的 `already patched on disk`）就说明 app
真正跑的那份 JS 已经改了。只读来源的重定向是否真的被用到，看有没有 `hook: ...` 行。

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

针对树洞 2.2.965 验证；仅供个人学习与自用。当前补丁版本为 8，deb 版本为 1.0.4。
