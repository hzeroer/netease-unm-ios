# UNMiOS — 网易云音乐 iOS 解灰插件（巨魔注入版）

作者：**hzeroer**　·　iPhone 15 Pro / iOS 16.6 / 网易云 8.9.20 实测可用

把变灰的歌换掉音源。**不需要外部服务器、不需要 CA 证书、不需要代理、不需要抓包。**

因为插件是用 **TrollStore / TrollFools** 注入进网易云自己的进程里的，它没有中间人这一步。

> 仅供学习研究使用。本项目不含任何音频内容，只做「换一个能播的地址」这件事。
> 用着还行就点个 ⭐，比什么都有用。

---

## 它和别的方案有什么不同

市面上常见的解灰方案有三类：

| 方案 | 原理 | 代价 |
|---|---|---|
| 代理 + 服务器（UnblockNeteaseMusic 等） | 客户端流量走代理，服务端改写响应 | 需要一台常开的服务器、需要装 CA 证书、离开那个网络就失效 |
| 越狱插件 | hook 网络层 | 需要越狱 |
| **本项目** | **在 App 进程内接管它自己的模型对象** | **无服务器、无证书；但依赖 App 的内部类名** |

目标很明确：**装在手机里，随时随地能听。**

---

## 兼容性

### 实测环境

| 项 | 值 |
|---|---|
| 设备 | iPhone 15 Pro（`iPhone15,3`，A16） |
| 系统 | **iOS 16.6（20G75）** |
| 客户端 | **网易云音乐 8.9.20（build 3440）** |
| 注入方式 | TrollFools（未越狱，巨魔） |
| 架构 | `arm64` |

### 依赖什么

- **未越狱**：TrollStore + TrollFools（能注入 dylib 就行）
- **已越狱**：直接装 `.deb`
- **不需要**：服务器、CA 证书、代理、抓包

### 版本敏感（重要）

插件的核心是接管客户端的 `NMSongPrivilege` / `NMSong` / `NMSongUrlInfo` 三个类。
**网易云大版本更新后，类名或字段名可能变化**，表现为两种症状：

- 完全没反应（类名变了）
- 灰是脱了，但播不了（字段名变了，或 `url` 取值器不再是投放点）

**自查方法**：面板 → 工具 → **导出 App 类结构**，里面会列出:
- 所有持有 `privilege` / `fee` / `playable` 等字段的自带类（按命中数排序）
- 关键模型的完整属性、变量类型和实例方法表

把这份输出贴到 issue 里，通常只需要改几个字符串常量就能适配。

### 没验证过的

- 其他机型和 iOS 版本（只要系统能跑 TrollStore，大概率可用，但未实测）
- 其他网易云版本（8.9.x 之外的未测）
- `arm64e`（当前产物只发 `arm64`）

---

## 它是怎么工作的

### 一句话

不去改网络响应，而是**直接改客户端自己的"这首歌能不能播"的判断**，然后把一个能播的地址交给它。

### 为什么不能改响应

这是本项目最重要的一条结论，也是最花时间验证的：

**这个版本的 iOS 客户端，播放地址不是通过任何可见的请求拿到的。**

抓包和 hook 的观测结果：

```
会话层看到的 43 个网易请求里：
  /eapi/middle/clientcfg/config/v2/full/delivery
  /eapi/rncache/reslist/v3
  /api/clientlog/encrypt/upload
  /eapi/playmode/song/vector/get
  …
里面没有一个 /song/enhance/player/url
```

而时间线显示，音频是在**播放那一刻**才开始从 CDN 拉的：

```
04:13:04  interface3.music.163.com/eapi/playmode/song/vector/get
04:13:04  m801.music.126.net/20261017043804/…/xxx.flac   ← 0 秒后开始拉音频
04:13:06  m801.music.126.net/20261017043806/…/xxx.flac   ← 换歌，地址里的时间戳跟着变
```

URL 路径里的 `20261017043804` 是服务器时间戳，和请求时刻**逐一对应**（恒定的设备时钟偏移），
说明地址是**播放那一刻由服务器生成的**，但取地址这一步走的是客户端自有的网络栈
（客户端里有 `caesar`、`NIMSDK` 等非系统库），完全不经过 `NSURLSession`。

**所以响应改写这条路在这个客户端上是无效的。**

### 实际的三层接管

| 类 | 接管什么 | 作用 |
|---|---|---|
| `NMSongPrivilege` | `status` / `fee` / `payed` / `playMaxbr` / `canShare` … | 让列表**不再是灰的** |
| `NMSong` | `canPlayMusic` / `canPlayOnline` / `isUnavailableMusic` … | 让播放器**愿意开始播** |
| `NMSongUrlInfo` | `url` / `type` / `expireTime` / `isFlac` … | **投放替代地址**，并让容器声明与地址一致 |
| `NMSongCacheUrlInfo` / `NMSongFile` | 所有返回对象的 url 取值器 | 播放器可能从这几个类读地址 |

`NMSongPrivilege` 原为 `nil` 的歌会**现场合成一个**——nil 是没法被"改成可播"的。

## 音源

当前只支持 **咪咕（MiGu）**。

```
搜索  https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do?text=<关键词>&…
取链  https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/sub/listen.do
        ?contentId=<contentId>&copyrightId=<copyrightId>&toneFlag=SQ|HQ|PQ&…
```

**两个 id 都必须给**：`contentId` 定位曲目，`copyrightId` 定位授权。
缺 `copyrightId` 会返回 `参数校验失败 copyrightId:must not be blank`。

**匿名可用**，不需要 cookie。按 SQ（无损）→ HQ（320k）→ PQ（128k）依次降级。

### 为什么只留这一个

开发过程中接过多家，实测结果：

| 音源 | 结果 |
|---|---|
| **波点** | ✅ **主用。**酷我镜像；付费曲也能取，见下一节 |
| **咪咕** | ✅ **备用。**有录音室版（周杰伦《稻香》8.5MB mp3 / 24.9MB flac），匿名可取链 |
| 酷我 | ❌ 部分歌只给「当前仅在酷我手机端播放」；还测到**两首不同的歌返回同一个文件** |
| 酷狗 | ❌ 付费曲返回 `The Resource Needs to be Paid` |
| 第三方 ID 直取（`pyncmd`，走 GD Studio 的 API） | ⚠️ 从网易取，网易没有的歌（如周杰伦原版，实测 7 首全空）它也没有；另有 50 次 / 5 分钟调用上限 |
| QQ 音乐 | ⚠️ `purl` 为空即无权限，付费曲需要**会员账号**的 cookie；没有可用账号验证 |

### 波点为什么能放付费曲

`bd-api.kuwo.cn` 判断「这首歌有没有解锁」**是按设备号（`devid`）存在服务端的**，不是按签名、也不是按账号。

同一个 URL、同一个签名、同一台机器，相隔几分钟：

```
devid: 88637305104   -> code 200   拿到地址
devid: 随机生成       -> code 20018 没有解锁付费歌曲
```

那个设备号曾经看过一次解锁广告，服务端就永久记住了它。所以插件里写死了一个已解锁的 `devid`（配置项 `bodianDevid`），失效时换一个即可。

顺带排掉的几个错误方向，免得有人重走：

- **广告解锁接口** `/api/service/advert/watch` 一直是 `439 sign invalid`——UNM 自己发也是 439，**它根本不靠这个接口**，取链照样成功。
- **签名算法**是对的：`md5("kuwotest" + 查询串去符号后按字符排序 + 路径)`，用抓包得到的输入能复现 UNM 的 `sign`。
- **请求头**（`accept` / `accept-language` / `devid` / `plat` …）不是门槛。
- **码率**不影响：15 档全试，付费曲一律 20018。

以上除波点、咪咕外**代码已全部删除**。

### 想加回别的源

`UNMProvider` 协议很小：

```objc
+ (NSString *)providerKey;
- (NSArray<UNMCandidate *> *)search:(NSString *)keyword timeout:(NSTimeInterval)timeout;
- (NSString *)resolveURL:(UNMCandidate *)candidate timeout:(NSTimeInterval)timeout;
```

实现后 `UNMRegisterProvider()` 注册即可（在 `UNMiOS.m` 里）。

⚠️ **交付地址前一定要验证它真的出音频。** 酷我那种"返回一段文字"的假直链会让播放器报一句
莫名其妙的话，而真正的原因完全看不见。本项目有 `UNMValidate`：用 Range 请求探测，
状态码 ≥400、`Content-Type` 是 text/json/html、或响应体里出现「手机端 / 仅在 / 试听」
就判定不可播，换下一档。

---

## 几个值得记录的坑

### 1. `NMSongPrivilege.status` 不是 API 的 `st`

| 来源 | 字段 | 值 |
|---|---|---|
| `/api/song/detail` | `status` | 0 |
| `NMSongPrivilege.status` | `status` | **200 = 正常** |

一开始我把 200 强制改成 0，等于**把一首健康的歌改成"状态异常"**，
直接引发了「歌曲不存在」弹窗和分享面板异常。

### 2. 搜索关键词：只用歌名

实测同一首歌、只换关键词：

```
关键词「稻香」        → 1.《稻香》/周杰伦/魔杰座   ← 录音室版，第一条
关键词「稻香 周杰伦」  → 1.《稻香 (Remix摇滚版)》   ← 录音室版彻底消失
```

咪咕会把"歌名+歌手"退化成模糊文本匹配。所以**先用歌名搜，搜不到才加歌手**。

### 3. 变体识别：中文不算"英文字母"

`Remix摇滚版` 这种连写在中文标题里极常见。用
`NSCharacterSet.letterCharacterSet` 做词边界判断时，**中文也被当成字母**，
于是 `Remix` 后面跟着「摇」→ 判定"不是独立单词"→ 家族判成录音室版 → **remix 顶替了原版**。

改成只把 ASCII 字母数字算作"词内"，问题消失。

### 4. 版本家族必须一致，不能只打低分

打分打折不够用：只要正确版本缺席，打折后的 remix 依然会被选中。现在是**硬过滤**：

```
候选家族 == 目标家族      → 允许
候选是纯录音室版          → 允许
否则                     → 直接跳过，不参与评分
```

家族：`录音室 / Live / Remix / 伴奏 / 翻唱 / 不插电`。
目标本身是 Live 时，再用**专辑名相似度**决定是哪一场——因为 live 版的标题和原版完全一样。

### 5. 主线程绝对不能等

播放器是在**主线程同步读** `NMSongUrlInfo.url` 的。早期我在这里做了 1.2 秒的同步查询，
结果就是**播放页卡死、悬浮球失效**（主线程一直被占着）。

现在的规则：

- 主线程读取**只查缓存**，绝不发网络请求
- 未命中就立即返回空，同时把这首歌**插队**到后台查询队列
- 列表构建期间批量预热前若干首（不阻塞、限速）

代价是**第一次点某首歌可能要再点一次**——这是刻意的取舍，换的是不卡。

### 6. 缓存键要对上

写过一版"热缓存"判断，查的是 `matchForID:`，而那个字典里存的是
`provider / mediaId / title / artist`——**根本没有 `url` 字段**。
于是热路径永远不命中，每次读取都掉进会超时的阻塞查询，
一首有 5 个可用链接的歌被报成"无法播放"。

### 7. 不要在 `__interpose` 上冒险

试过用 Mach-O `__interpose` 段拦 `connect` / `getaddrinfo` 去观测"非 HTTP 外连"。
**结果是闪退**：interpose 对整个进程生效，包括系统库在启动极早期建立的连接，
而钩子里又会去读配置、写文件——典型的自举期递归。

已彻底移除，构建脚本现在会检查 `__interpose` 段数量必须为 0。

---

## 构建

需要 macOS 或 WSL + clang，以及一份 iOS SDK。本项目不使用 Theos/cctools，
直接用 clang + `ld64.lld` 产出 Mach-O，再用 `ldid` 签名。

```bash
export IOS_SDK=/path/to/iPhoneOS16.5.sdk
export ARCHS="arm64"
./tools/build-dylib.sh      # 产出 dist/UNMiOS.dylib
./tools/pack.sh             # ldid 签名 + 打包 deb
```

构建脚本有两条**硬闸**，会直接失败而不是放行：

1. 出现任何 `flat-namespace` 绑定（= 未定义符号）→ 构建失败
2. 产物内嵌的 `UNMiOS_VERSION=` 与 `control` 的 `Version` 不一致 → 打包失败
   （防止编译失败后拿旧二进制打出假版本号）

### 安装

- **巨魔用户**：把 `dist/UNMiOS.dylib` 用 **TrollFools** 注入到
  `com.netease.cloudmusic` 即可，重启 App 生效
- **越狱用户**：安装 `dist/UNMiOS.deb`

> ⚠️ **只注入一份 dylib。** 两份同时生效会互相 hook，导致无限递归闪退。

---

## 已知限制

| 限制 | 说明 |
|---|---|
| 第一次点某首歌可能要再点一次 | 播放器主线程同步取地址，而我们不能让主线程等 |
| 依赖 App 内部类名 | 网易云大版本更新后可能需要重新适配，见上文「版本敏感」 |
| 只在 iOS 16.6 / 网易云 8.9.20 / arm64 上实测过 | 其他组合未验证 |
| 只有咪咕一个源 | 咪咕没有的曲目就没有替代源 |
| 无法给分享面板加「同步微信状态」 | 该选项只在客户端整体离线时出现，插件伪造不了系统级断网 |

---

## 致谢

- **[UnblockNeteaseMusic/server](https://github.com/UnblockNeteaseMusic/server)**
  —— 整个思路的起点。它拦截哪些接口、各家 provider 长什么样、
  `fee` / `st` / `pl` / `dl` 这些字段怎么解释，都是从它的源码里读出来的。
  本项目早期版本几乎是它的 iOS 内嵌移植，后来才转向模型层接管。
- **[TrollStore](https://github.com/opa334/TrollStore) / TrollFools**
  —— 让未签名 dylib 能在非越狱设备上注入。
- **ldid / ld64.lld / iPhoneOS SDK** —— 签名与链接。
- Apple 的 `libobjc` 运行时 —— 全部 hook 都建立在自己的 swizzler 上
  （`UNMHook`），不依赖 substrate / libhooker / Orion。

也感谢那些在论坛和 issue 里公开讨论网易云接口字段含义的人。

—— 音源最终定为波点主用、咪咕备用，其余实测后已移除，原因见上一节。

---

## 结构

```
src/
  UNMiOS.m           入口：安装顺序、崩溃守卫、版本
  UNMHook.h/.m       自写的 libobjc swizzler（带 (class,selector)→原始 IMP 注册表）
  UNMModelHook.h/.m  模型层接管：脱灰 + 投放地址（核心）
  UNMStore.h/.m      元数据 / 匹配 / 地址缓存
  UNMMatcher.h/.m    打分与版本家族判定
  UNMProvider*.m     音源（bodian 主用，migu 备用）
  UNMValidate.h/.m   候选链接探测（拒绝"假直链"）
  UNMURLProtocol.m   拦截层（当前主要用于观测；本客户端用不上响应改写）
  UNMMenu.h/.m       悬浮球 / 摇一摇 / 面板 / 诊断
  UNMRuntimeDump.m   运行时导出 App 自有类结构（适配新版本时用）
  UNMCrashGuard.m    连续闪退自动进安全模式
```

---

## 许可与声明

本项目采用**非商业使用许可**：可自由下载、自用、学习、修改、非商业分享；
**禁止任何商业用途**（售卖、收费下载、捆绑进付费产品、广告变现、有偿代装、
并入闭源商业产品等），且必须保留作者署名。完整条款见 [LICENSE](LICENSE)。

> 这是一份自定义的非商业许可，不属于 OSI 认可的开源许可证，GitHub 会把它标为
> `custom license`。这是刻意的选择：本项目定位就是个人自用工具，不是商品。

**关于参考项目。** 致谢里提到的
[UnblockNeteaseMusic/server](https://github.com/UnblockNeteaseMusic/server) 采用
**LGPL-3.0**（最早的 [nondanee/UnblockNeteaseMusic](https://github.com/nondanee/UnblockNeteaseMusic) 为 MIT）。
本项目**不包含该项目的任何代码** —— 它是 Node.js，这里是 Objective-C。
参考的只是「拦截哪些接口」「各家 provider 的请求长什么样」「`fee` / `st` / `pl` / `dl`
分别是什么意思」这类事实性信息，实现全部重写。若认为存在应当标注的代码相似之处，
请开 issue，我会修正。

---

## 版本

```
dist/UNMiOS.dylib    589,536 bytes  arm64  Mach-O dylib v2.8.3
dist/UNMiOS.deb      150,468 bytes
sha256  bde58b84bb7419caaba212c876efe7f68a8725864c6a0c6d267c35ab3018c8f0
作者：hzeroer      包名：com.hzeroer.unmios
只链接系统库：Foundation / UIKit / CoreGraphics / CoreFoundation / libobjc / libSystem
substrate 引用数：0    未定义符号：0    -Wall 警告数：0    __interpose 段：0
```

> 署名同时出现在：面板「状态 → 版本」行、启动日志
> （`UNMiOS 2.8.3 by hzeroer loaded into com.netease.cloudmusic`）、`control` 的
> `Author` / `Maintainer` 字段（装包时在 Sileo/Zebra 里可见）、以及 `LICENSE` 的版权行。
