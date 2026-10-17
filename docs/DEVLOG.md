# UNMiOS — 网易云音乐 iOS 解灰插件（巨魔注入版）

把变灰的歌换掉音源。**不需要外部服务器、不需要 CA 证书、不需要代理、不需要抓包。**

因为插件是被 **TrollStore / TrollFools 注入进网易云自己的进程**里的，它看到的响应体
已经是 App 用自己 TLS 栈解密后的明文 —— 中间人这一步根本不存在，证书自然也不需要。
替代音源由插件直接请求酷我 / 波点 / 酷狗 / 咪咕的公开接口拿到，所以也没有任何中转。

实测产物（本仓库已构建）：

```
dist/UNMiOS.dylib    572,144 bytes  arm64  Mach-O dylib v1.8.0，ldid 已签名，直接丢给 TrollFools
dist/UNMiOS.deb      158,188 bytes  越狱机用（Sileo/Zebra）
sha256  9db03949f0c61d054be28631fafcc5c59a68b4469e7e75227663a48c89618a75
只链接系统库：Foundation / UIKit / CoreGraphics / CoreFoundation / libobjc / libSystem
substrate 引用数：0    未定义符号（flat-namespace 绑定）：0    -Wall 警告数：0
`__interpose` 段：已移除（v1.2.9 引入，导致闪退）
```

### v1.8.0：接入第三方音源 pyncmd（付费曲的关键）

参考实现音源清单里的 `pyncmd` 就是常说的「第三方音源」。它不是另一个平台的搜索，而是
**按 NetEase songId 直取**：

```
https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=<songId>&br=999|320
```

电脑上实测：

| songId | 歌曲 | 结果 |
|---|---|---|
| 1461142410 | 想说 / 颜人中 | FLAC 1721kbps **+** MP3 320，HTTP=206 |
| 1391891631 | 嗜好 / 颜人中 | FLAC 734 **+** MP3 320，HTTP=206 |
| 185918 | 麦芽糖 / 周杰伦 | 空（这首连它也没有） |

返回的是 `music.126.net` —— **网易自己的 CDN**，覆盖的正是酷我/酷狗锁掉的那部分，
客户端拿到的就是它会原生播放的地址。

**它被放在解析链第 0 步**：只需要 songId，不需要歌名/歌手/搜索/模糊匹配，
所以**没有匹配错误的可能**；一次 HTTP 取回两个码率（无损优先，失败退 320）；
失败才落到 kuwo → bodian → kugou → migu。

开关：面板 → 开关 → **第三方音源**（默认开）。

### v1.8.0 同版修掉的加载延迟

`_urlCache` 的每次读取原本都走 `dispatch_sync(_stateQueue)`，而同一个串行队列还要处理
JSON 解析、匹配和写盘 —— 主线程读地址时会排在它们后面，歌单越长积累越明显。
现在 URL 缓存有**独立的锁**，`cachedURLForID:` 不再经过状态队列；
投放热路径也不再调 `metaForID:`。

### v1.6.9：热缓存这条路从来没通过

用户的诊断页给出了具体那一首：

```
最近一首：185918
  地址读取 14 次，其中为空 14 次
  成功投放 0 次
  原始 privilege：status=0  fee=0
```

先在电脑上把这首完整跑了一遍，证明链路本身是通的：

```
185918 → "麦芽糖" / 周杰伦（music.163.com/api/song/detail，无需登录）
酷我搜索 → 5 个候选 rid
每个候选 → HTTP=206  CT='audio/mpeg'  first=ff fb 90 c4   ← 全部可播
```

**5 个可用链接，插件一个都没投出去。** 根因：

`substituteURLForUrlInfo:` 的"热缓存"查的是 `matchForID:`，而 `_match` 里存的键是
`provider / mediaId / title / artist / ts` —— **没有 `url` 字段**。于是热路径永远不可能命中，
每次读取都掉进那个 1.2 秒的阻塞查询；查询在预算内跑不完就返回 nil。

修正：`UNMStore` 新增 `cachedURLForID:`，直接读 `_urlCache`（那里才是解析结果），
`substituteURLForUrlInfo:` 与 `-playUrlInfo` 都改用它。`matchForID:` 保持原义
（记录"选中了哪个候选"），不再被当作取地址用。

### v1.6.8：「歌曲不存在」的定位工具

客户端只给一句话，所以把每一环的实际值钉下来。菜单「模型层接管状态」顶部新增：

```
最近一首：1461142410（0.8 秒前）
  地址读取 41 次，其中为空 41 次
  成功投放 19 次  → …kw-bj.kuwo.cn/xxx/588957081.mp3
  playUrlInfo 读取 12 次，其中为 nil 12 次
  原始 privilege：status=-200  fee=8（现在被强制成 0 / 0）
```

这四行分别排除四种可能：地址没找到 / 地址交出去了但客户端仍拒 / `playUrlInfo` 缺失 /
版权本身受限。**`status=-200` 会直接说明服务器把这首歌判成了无版权**，而不是付费。

同时恢复了 `-playUrlInfo` 的合成，但**只在地址已经热的情况下**合成 —— 返回 nil 正是客户端
报「歌曲不存在」的原因，而凭空造一个没有地址的对象只是把失败推后一步。

另外把容器声明对齐了：`isFlac`/`isMP3`/`isAAC`/`isAPE`/`isWAV`/`isLossLess`/`bitrate`
全部**按实际 URL 推导**。因为把 `playMaxbr` 提到 999000 会让客户端以为在播无损槽位，
而实际交付的是 mp3 —— 格式声明不一致会表现为"有地址却没声音"。

### v1.6.7：核心矛盾与解法

实测数据（用户设备的计数页）：

```
NMSongUrlInfo.url 读取次数    1031（其中原本为空 1020）
主线程读取（拒绝阻塞）         561
成功投放替代直链               3
其他模型类的 URL 取值器          0    ← 播放器只读这个字段，投放点是找对了
```

客户端**在主线程同步读取** `url`。于是形成矛盾：

- 等待查询 → 界面冻死（v1.6.5 之前，播放页卡住、悬浮球失效）
- 不等待 → 全部「歌曲不存在」（v1.6.5）

**解法：用"问了几次"区分场景。** 列表构建对每首歌只读 1–2 次；播放时同一首被反复读。
所以：

| 场景 | 行为 |
|---|---|
| 读取次数 < 3（列表构建） | 立即返回、绝不阻塞，只排队 |
| 主线程 + 次数 ≥ 3（播放） | 允许等待，上限 1.2 秒，且全局同时只允许一个 |
| 非主线程 + 次数 ≥ 3 | 允许等待，上限 `urlWaitMS` |

首次投放成功后地址进热缓存（TTL 90s），后续读取是瞬时的，所以"顿一下"只发生在每首歌的第一次。

已用真实数据验证过的两件事（在电脑上跑的）：

```
kuwo 链接     HTTP=206  CT='audio/mpeg'  first=ff fb 90 c4   ← MP3 帧头，验证器不会误杀
元数据接口    https://music.163.com/api/song/detail?ids=[id] → 200，无需登录
              1461142410 → "想说" / 颜人中
```

第二条意味着换源不需要依赖任何客户端请求：**songId → 网易元数据 → 酷我搜索 → 直链**，
整条链路在手机上自给自足，不需要服务器、不需要证书。

### v1.6.4：修「进歌单特别慢」（自己造成的性能问题）

现象：歌单歌越多越慢。原因有三个，都在我这边：

1. **每读一次 `NMSongPrivilege.status` 就预取一首歌。** 打开 500 首的歌单 = 500 次立即查询，
   而 v1.6.3 起每次查询 = 搜索 + 最多 6 档变体 + 每档一次验证探测。等于瞬间几百个请求。
2. **2.5 秒的"有界等待"也会落在列表行上。** 每一行读 `url` 都可能阻塞，歌越多越灾难。
3. `status` 每次都走 KVC 读 `songId`，在每行每次布局都会调用的热路径上。

修正：

| 改动 | 做法 |
|---|---|
| 预取改成**排队 + 批处理** | 列表构建只往队列塞一个字符串；后台每 0.8s 最多取 4 首批量查（队列上限 40） |
| 等待改成**按"问过几次"决定** | 列表每首只读 1 次 → 立即返回、绝不阻塞；播放器对同一首会反复读 → 第 2 次起才允许等待 |
| 等待**全局限流** | 同时最多 1 个阻塞查询，且两次之间至少间隔 0.8s |
| `songId` 首次读到后**关联缓存** | 之后是哈希查找，不再走 KVC |

判据来自实测：之前播放时同一首 `1461142410` 被读了约 20 次，而列表构建是每首一次 ——
这个差异正好可以用来分开两条路径。

### v1.6.3：候选链接必须验证

实测已经能播了，但部分歌报「**当前仅在酷我手机端播放**」。那句话是**酷我返回的响应体**，
不是客户端的错误 —— 说明我们交出去的链接只回一段文字，不是音频流。

根因是我自己的疏漏：**从不验证取到的链接是否真的出音频**，拿到第一个 URL 就交出去。

v1.6.3 的修正：

1. **六档酷我候选**，逐档验证，取第一个真正可播的：

   | 档位 | 说明 |
   |---|---|
   | `anti/convert_url` | 经典 anti-leech，响应体就是 URL |
   | `anti/convert_url3` × (320k / 128k / flac) | 逐码率单独试 —— 有的歌只在某一档被 App 限制 |
   | `www/convert_url3` | 网页前端的同一服务，走不同边缘节点，不带手机端限制 |
   | `nmobi/mobi.s` (base64 `q=`) | 传统移动 API，响应是 `url=` 形式的文本 |
   | `nmobi/mobi.s` (convert_url_with_sign) | 签名档 |

2. **每个候选都做一次 Range 探测**（`bytes=0-2047`）：状态码 ≥400、`Content-Type`
   是 text/json/html、或响应体里出现「手机端 / 仅在 / 无法 / 试听 / VIP」→ 判定不可播，换下一档。
   判不准时**倾向于接受**，宁可试错也不要白白丢一个音源。

3. 被拒的链接会写进日志，并出现在抓取报告的「被拒绝的候选链接」一节 —— 失败原因不再是黑箱。

4. `urlWaitMS` 从 1500ms 提到 **2500ms**，因为每档多了一次探测往返。
   代价：第一次播一首灰歌最多多等约 2.5 秒；之后命中缓存是瞬时的。

### v1.6.2：为什么"解灰了但播不了"

实测状态：**列表灰不灰已经解决**（模型层接管生效），**换源解析也正常**
（酷我 15 次尝试命中 14 次），但播放仍然失败。事件日志给出了确切原因：

```
04:34:41  1391891631 暂无直链（已排队）
04:34:42  1461142410 暂无直链（已排队）   × 约 20 次
```

**播放器来问地址的时候，我们的缓存还没热。** 之前为了实现"绝不在播放路径上阻塞"，
`NMSongUrlInfo.url` 只读热缓存、拿不到就返回 nil —— 结果用户一点播放，
后台查询还没回来，返回空，于是"无法播放"。

v1.6.2 改为**有界等待**：

- 地址为空时，同步等最多 `urlWaitMS`（默认 1500ms）去查源
- 这是播放路径，宁可慢一秒也不能播不出来
- 真正无源的歌记进本次会话的负缓存，不会每次读取都再等一遍
- 事件里会写明是否命中，以及等了多久（`投放直链(320ms) …`）

同时 v1.6.1 补了两处：**`NMSongCacheUrlInfo`** 和 **`NMSongFile`** 上的 URL 取值器
也一并接管（`_playUrlInfo` 的真实类型是前者，`_songFile`/`_lfile`/`_mfile`/`_hfile` 是后者），
以及 `NMSong.songFile` 为 nil 时合成一个。菜单「模型层接管状态」现在会列出**每个 hook 的调用次数**。

### v1.6.0：模型层解灰（当前的主方案）

响应改写已确认无用（播放地址不经过任何可观测请求），改为接管客户端自己的判定：

| 类 | 接管的成员 | 强制为 |
|---|---|---|
| `NMSongPrivilege` | `status`(API 的 `st`), `fee`, `payed`, `flag` | 0 / 0 / 1 / 0 |
| | `playMaxbr`, `downloadMaxbr`, `maxBitrate` | 999000 |
| | `isVipSong`, `isLimitFree`, `isExclusiveSong`, `isPlayOnlySong`, `isFakePrivilege`, `isNoOrNearlyNoCopyrightSong` | NO |
| `NMSong` | `canPlayMusic`, `canPlayOnline`, `canEnableMusic` | YES |
| | `isUnavailableMusic`, `isPlayOnlySong`, `isFeeSong`, `hasFeeIssue` | NO |
| | `privilege` / `playUrlInfo` | 原本为 nil 时**合成**一个对象 |
| `NMSongUrlInfo` | `url` | 原本为空时投放音源直链 |
| | `type` | 按实际 URL 推导（flac/mp3/aac/wav） |
| | `fee`, `payed`, `expireTime`, `isFreeTrialURL/Song`, `canUserFreeTrial` | 0 / 1 / +24h / NO |

两个设计要点：

- **`privilege` 为 nil 时合成一个** —— 灰歌经常完全没有 privilege 对象，而 nil 是无法被"改成可播"的
- **预取而非阻塞**：`NMSongPrivilege.status` 被调用时（列表构建阶段）排队后台查链，
  所以 `NMSongUrlInfo.url` 取值时命中的是热缓存，**绝不会在播放路径上等待网络**
- 故意**不**接管 `canPlayLocally`：那会让客户端去找一个不存在的本地文件

开关：面板 → 开关 → **强制解灰**（默认开）。所有取值器都在配置上做闸门，
所以切换**不需要重启**。菜单新增「模型层接管状态」，逐个列出哪些成员已被接管。

### 找版权模型类：按**成员名**找，不按类名找

v1.4.0 用类名关键词（`Song`/`Player`/…）去扫，结果**70 条上限被外围的 Swift 模块塞满了**
（交友 `MusicDating`、直播 `NMLLiveTabModule`、送礼、可视化…），核心模型被截断在后面。
而且扫出来的全是 `_TtCs12_SwiftObject` —— 类名匹配根本不指向版权模型。

v1.4.1 改成按**属性/变量名**匹配。网易的版权字段名是固定的，哪个类里有这些成员，
那个类就是目标：

```
privilege, privileges, playable, playflag, payable, fee, copyright, copyrightid,
songid, trackid, vipflag, viptype, maxtype, maxbr, playmaxbr, freetrialprivilege,
freetrialinfo, subp, fl, cp, st, pl, dl, chargeinfo, norightsreason
```

按**命中数排序**，所以即使 `st`/`pl`/`dl` 这类两字母成员有噪声，真正持有版权判定的类
也会排在最前面。同一页还会附上**已加载的 App 自带库**列表（看框架布局）。

### 换了方向：从「改写响应」改为「改客户端自己的判断」

第二次时间线把通道问题钉死了：

```
04:18:05  clientlog3.music.163.com/api/clientlog/batch/fast
04:18:06  m801…/20261017044305/…b9fa1e2a…flac     ← token :05
04:18:07  m701…/20261017044307/…461829d2…flac     ← token :07（换歌）
04:18:16  m801…/20261017044316/…9ab4cf0f…flac     ← token :16（换歌）
```

三个地址的服务器时间戳与音频请求时刻**逐一对应**（恒定 +25 分钟，设备时钟慢 25 分钟），
**说明地址是在播放那一刻由服务器生成的**；而这 60 秒里会话层只有 4 个 clientlog 接口，
**没有任何请求携带它们**。唯一被记录结构的响应是日志回执 `{code,data,message}`。

**所以响应改写这条路走不通了。** 新的抓手是客户端自己那个「不可播」的判断
（privilege / fee / playable），它存在 App 的模型对象里。

v1.4.0 用**纯 ObjC 反射**把这些类挖出来（不 hook 任何系统函数）：

- 工具 → **导出 App 类结构**：列出 App 自带、类名含 `Song/Privilege/Track/Playable/Fee/Player`
  的类，以及它们的**属性名和变量名**（用 `class_getImageName` 限定只取 `neteasemusic.app`
  里的类，不会混进系统框架）
- 同样的内容也会附在抓取报告末尾，不用来回跑

拿到属性名之后才能写针对性的 hook（把灰色的判定改成可播）。

另外注意到一件对"投放"有用的东西：**音频请求 URL 里带着歌曲 ID**：

```
m801.music.126.net/<token>/…/jdymusic/obj/wo3DlMOGwrbDjj7DisKw/19685841320/…flac
                                                              ^^^^^^^^^^^ 歌曲 ID
```

所以即使看不到取链请求，我们仍然能在音频层知道"正在播哪首歌"，从而换成音源的流。

#### v1.2.9 → v1.3.0：一次自己埋的坑

v1.2.9 用 Mach-O `__interpose` 段拦 `connect` / `getaddrinfo`，想看到"不走 HTTP 的外连"。
**结果是闪退**，而且原因我事先就写下过风险：

- interpose 是对**整个进程**的 `connect` 生效 —— 包括 libSystem 自己早期建立 XPC/cfprefsd
  连接时的那次调用；
- 我们的钩子体里会去读配置（`[UNMConfig shared]`），那会触发 ObjC 消息、`dispatch_once`
  和**文件写入**，而这一切发生在进程启动极早期、且在 `connect` 内部 —— 典型的自举期递归；
- 另外 `dlsym(RTLD_NEXT, "connect")` 在 interposing 镜像里**有可能返回我们自己的实现**，
  直接无限递归。

v1.3.0 把整个 C 层探测删掉了。构建脚本现在会打印 `__interpose` 段的存在与否，
本次输出是「已移除」。

**留下的是没有风险的两项**（它们不替换任何系统函数）：

| 观测层 | 手段 |
|---|---|
| 请求时间线 | `NSURLProtocol` 收到每个请求时记 `(时间, 域名, 路径)`，含音频 CDN |
| 按路径放行 | 域名不在白名单但路径像网易接口也拦（应对客户端按裸 IP 直连 API） |

### 关键对照实验：先播一首「能播的歌」

这是判断「客户端的取链请求到底能不能被拦到」的唯一干净办法：

```
抓取 60 秒诊断 → ① 播一首正常能播的歌  ② 再播一首灰歌 → 看报告
```

- 报告里**有** `/song/enhance/player/url` → 客户端确实会请求，我们能拦到。
  灰歌之所以没有，是**客户端在本地就拒了它**，下一步要解决的是「让列表先变白」。
- 报告里**连正常歌也没有** → 客户端拿播放地址不经过 NSURLSession，
  需要去更底层（长连接 / socket）找拦截面。

另一种独立验证：把手机 WiFi 代理指向你部署的 UNM 服务器，**看服务器控制台打印了
哪些请求路径**。服务器是第三方观察者，它看到的就是客户端真正发出的请求。

### 抓取诊断怎么用（v1.2.7 起统计会先清零）

面板 → 工具 → **抓取 60 秒诊断** → 立刻去 **搜索**里播一首灰歌 → 60 秒后自动出报告。
报告里的每个数字只反映那 60 秒。

**不要直接点歌单里的灰歌** —— 客户端对灰歌直接在本地拒绝，根本不会向服务器发播放请求，
所以永远看不到 `/song/enhance/player/url`。正确顺序是：

1. 顶部搜索框 → 输入歌手名 → 进搜索结果列表（这一步强制联网）
2. 列表里的版权状态被我们改写后，那一行会变白
3. 这时点播放，客户端才会去取链接，我们才能换源

歌单/专辑页的数据往往来自本地缓存，所以从那里点没用。

### 和自己部署的 UNM 服务器配合

两条路，互斥，别同时开：

**A. 设备走服务器代理（成熟方案，需要 CA 证书）**

设置 → 无线局域网 → 当前网络 → 配置代理 → 手动 → 填服务器的 `IP:端口`，
然后装服务器生成的 CA 证书并在「关于本机 → 证书信任设置」里打开。
桌面客户端就是这么用的。**用这条路时请把本插件的「总开关」关掉**，否则两边都改写会打架。

**B. 本插件（不需要服务器、不需要证书）**

手机上直接跑，音源直连。识别到的接口覆盖了参考实现里拦截的那一整张表：
`player/url`、`download/url`、`song/enhance/privilege`、**`playlist/privilege`**、
`album/privilege`、`artist/privilege`、`song/detail`、`playlist/detail`、`v1/album`、
`album/play`、`v1/artist`、`artist/top/song`、`playmode/intelligence/list`、
`discovery/recommend/songs`、`v1/radio/get`、`search`、`batch` …

### 排查用：一键抓取

面板 → 工具 → **抓取 30 秒诊断** → 立刻去播一首灰色的歌 → 30 秒后自动弹出报告。

它会临时打开全部日志与发现模式，然后自动还原，报告里包含：

- 窗口内 `协议拦截 / 会话任务 / 改写 / 换源命中` 的增量
- **拦截器被咨询过的所有域名**（判断域名白名单有没有漏）
- **在会话层看到的网易接口路径**（判断拦到的是不是该改的接口）
- 每个音源的尝试/命中/未命中
- 一段自动结论，直接指出是哪一层断的

构建现在有两道闸，都会让构建/打包**失败**而不是放行：

1. 出现任何 `flat-namespace` 绑定（= 未定义符号）→ 构建失败并列出符号名；
2. 产物里内嵌的 `UNMiOS_VERSION=` 标记与 `control` 的 Version 不一致 → 打包失败
   （防止编译失败后拿旧二进制打出假版本号）。

**注入前先确认 TrollFools 里只有一份 UNMiOS。** 重复注入会让进程加载两份本插件，
两份互相 hook 就是递归 —— 程序会替你把多余的那份停掉并报错，但最好一开始就只留一份。

**装上后应该出现一个悬浮球。** 球在 = 插件已加载且在跑。如果球不在，日志里一定有一行
说明原因（见下面「菜单没出来」）。

### 如果闪退

v1.2.1 修掉了**递归 hook 导致的栈溢出**（详见下节），v1.2.2 修掉了**被安全模式禁用后
再也起不来**的死锁。安全模式保留：

- 连续两次启动后 8 秒内死掉 → **第三次启动自动禁用所有 hook**，App 一定进得去，
  悬浮球仍然会出现。
- **版本号变化会自动清除安全模式**，并**自动恢复总开关**，不需要手动处理。

崩溃原因会被记录（未捕获异常 + 致命信号，含 backtrace + ObjC 调用栈）：

```
<App 容器>/Library/Caches/unmios/crash.log     ← 面板「工具 → 崩溃报告」也能看
```

**最准的还是 iOS 自己的崩溃日志**：设置 → 隐私与安全性 → 分析与改进 → 分析数据 →
找 `NeteaseMusic-*.ips`。它会直接点名是哪个 dylib、什么异常、崩在哪一帧。

### 菜单没出来

日志里看这几行（`<App 容器>/Library/Caches/unmios/unmios.log`）：

| 日志 | 含义 |
|---|---|
| `菜单安装已排队（悬浮球=开 …）` | 安装已安排，正常 |
| `悬浮球：窗口模式已就绪（scene=… frame=…）` | 主路径成功，球应该可见 |
| `悬浮球：改用宿主窗口模式（UIWindow…）` | 拿不到 window scene，退化为挂在 App 自己窗口上 |
| `悬浮球：还没有 window scene 也没有宿主窗口，稍后重试` | 还没到能显示的时候，会继续重试到 20 秒 |
| `enabled=false：菜单已装，但解灰关闭` | 总开关是关的 —— 面板里打开「总开关」 |
| `检测到 enabled=false 不是用户关的…已自动恢复为 true` | 上次是安全模式关的，本次已恢复 |
| `进程里加载了多份 UNMiOS，已停用后面这几份` | 注入重复了，去 TrollFools 删掉多余的 |

#### 已经踩过的坑（真机复盘）

**① 递归 hook → 栈溢出（v1.2.0，已修）**
收到一份 `neteasemusic-*.ips`：`EXC_CRASH / SIGILL`，主线程死在 `CFPreferences` 解析 plist
（内存已被破坏），而另一个线程的栈上密密麻麻几千帧全是 `UNMHookedSetAdditionalHeaders`
—— 无限递归把线程栈撑爆的典型指纹。

根因：`method_setImplementation` 返回被替换掉的旧实现，而我对同一个 `(类, selector)`
挂了两次（先公开类，再取一个实例的运行时类，结果两者是同一个类）。第二次拿到的"旧实现"
**就是我自己的钩子** → 钩子调用自己。

**② `enabled=false` 把菜单一起挡掉了（v1.2.1，已修）**
上一版进安全模式时会把 `enabled=false` 写进配置；而构造函数在 `if (!cfg.enabled) return;`
里**提前返回**，菜单安装被放在这个判断之后 → 没有悬浮球、没有摇一摇、解灰也不工作，
而且**菜单是唯一能重新打开开关的地方**，形成死锁。

修法是两条独立的保险：菜单**无条件安装**（放在开关判断之前）；`enabled=false` 若不是
用户在面板里关的（靠 `enabledTouchedByUser` 标记区分），启动时**自动恢复**。
加上「多份 dylib 检测」，防止重复注入导致两份互相 hook。

**③ 未定义符号（v1.2.2，已修）**
又一份 `.ips`，这次是 `EXC_CRASH / SIGABRT`，栈顶非常直白：

```
dyld                 dyld4::APIs::_dyld_missing_symbol_abort()
UNMiOS (5).dylib     __UNMInstallInterceptor_block_invoke_2   ← 调用方
UNMiOS (5).dylib     UNMTryHook
UNMiOS (5).dylib     __UNMInstallInterceptor_block_invoke
libdispatch          _dispatch_once_callout
```

`_dyld_missing_symbol_abort` = dyld 在解析某个符号时找不到它。翻二进制找证据：

```
__DATA __la_symbol_ptr 0x402B0  flat-namespace  _UNMHookInstOnRuntimeClassIfOwned
```

`flat-namespace` 意味着这个符号**既不是本 dylib 定义的，也没有链接到任何提供它的库**。
而 `UNMHookInstOnRuntimeClassIfOwned` 与 `UNMHookClsOnRuntimeClassIfOwned`
在头文件里声明了、在 `.m` 里**根本没有定义** —— 我在重写 `UNMHook.m` 时把它们弄丢了，
正好就是安装器第一个 block 调用的前两个函数，与崩溃栈完全吻合。

它能"编过"的原因：链接时带了 `-undefined,dynamic_lookup`，链接器允许未定义符号通过。
这个选项是从 tweak 模板沿用的习惯（对需要引用 Substrate 运行时的 tweak 是必需的），
但**本项目只引用系统库，根本不需要它**。

三条修复，逐层加严：

| 措施 | 说明 |
|---|---|
| 补上定义 | `UNMHookInstOnRuntimeClassIfOwned` / `UNMHookClsOnRuntimeClassIfOwned` |
| **删掉 `-undefined,dynamic_lookup`** | 未定义符号现在在**编译期就是链接错误**，不可能再到设备上才炸 |
| **构建时硬检查** | `build-dylib.sh` 扫描 bind 与 lazy-bind 表，只要有一个 `flat-namespace` 绑定就**构建失败**并列出符号名 |

这次就是靠第三条抓出来的 —— 它把「设备上第一次调用才 abort」变成「构建直接不通过」。

---

## 0. 有 App 内菜单

三种进法（默认前两种开启）：

| 入口 | 默认 | 说明 |
|---|---|---|
| **悬浮球** | 开 | 屏幕右侧可拖动小球。红=还没拦到请求，绿=已经在工作。位置会记住 |
| **摇一摇** | 开 | 摇手机直接弹面板，完全不依赖 App 自己的 UI |
| **导航栏按钮** | 关 | 在导航栏加一个「UNM」按钮。可能和 App 自己的按钮打架，所以默认关 |

面板里有什么：

- **状态**：实时拦截 / 改写 / 换源命中计数、当前音源、配置来源、缓存量
- **自检**：一键把「晴天 周杰伦」跑过所有音源，逐个显示 ✅/❌、耗时、拿到的直链。
  **这个不依赖网易云、不用播放任何歌**，所以能立刻分清「插件坏了」还是「某个源挂了」
- **开关**：总开关、三个接口的重写开关、X-Real-IP、预取、发现模式、记录每个请求
- **音源**：四个源独立开关
- **参数**：匹配阈值、超时、X-Real-IP、咪咕/酷狗 cookie（点进去粘贴）
- **工具**：诊断（带自动结论）、查看日志、当前配置、重置统计、重启 App

面板是独立 window，所以不挑 App 版本，App 改版也不会失效。改完配置立刻热生效，
只有「入口」那几个开关需要重启。

---

## 1. 它怎么工作

```
网易云 App
   │ ① /song/enhance/privilege      → st<0 改成 st=0，列表里的灰歌变白
   │ ② /song/enhance/player/url     → url 为空/404/试听时换源
   │                                   ├ 用 songId 查本地元数据表（歌名/歌手/时长）
   │                                   ├ 缺元数据时请求网易自己的公开 detail 接口补齐
   │                                   ├ 按 providerOrder 依次搜 酷我 → 波点 → 酷狗 → 咪咕
   │                                   ├ 模糊匹配打分（标题 60% + 歌手 30% + 时长 10%）
   │                                   └ 命中后替换 url / code / fee / freeTrialInfo
   │ ③ /song/enhance/download/url   → 同样处理，下载也能用
   ▼
播放器直接播第三方 CDN 的音频流
```

| 关键点 | 做法 |
|---|---|
| 拦截方式 | **三层一起上**：① `[NSURLProtocol registerClass:]`；② hook `-[NSURLSessionConfiguration protocolClasses]` **getter 和 setter**；③ hook `+[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]` / `-initWithConfiguration:…`，在 session 还是可变配置的时候把我们的协议塞进去。只做第 ① 层是**不够的**：NSURLSession 只看配置里列的协议类，而且框架可能直接读 ivar 而不走 getter —— 那样表面一切正常、实际一个请求都拦不到 |
| 灰不灰的真正来源 | 除了 `/song/enhance/privilege`，**播放列表/专辑/详情响应里内嵌的 `privileges[]` 数组**才是列表 UI 读来判断灰不灰的。只改专用接口是最常见的「改对了还是灰」原因，所以现在两边都改 |
| 注入环境 | **零依赖**：只用 libobjc + Foundation + UIKit。不链 substrate / libhooker / Orion，所以同一个二进制既能被 TrollFools 注入非越狱 App，也能装成越狱 deb |
| 网易加密 | `/eapi/` 的**请求体**是 AES 加密的，但**响应体是明文** JSON，所以只做响应重写、完全不碰加密 |
| 不卡播放 | 重写丢到独立并发队列，不占 URLSession 的串行 delegate 队列；`privilege` 一解锁就**预取**，用户点播放时 URL 已就绪 |
| 内存安全 | 单响应 >3 MB 直接流式透传不缓冲，6 MB 是硬上限，超了自动降级；音频 CDN（`*.music.126.net`）**不拦截** |
| 会话保真 | 上游 session 用 `defaultSessionConfiguration` + 共享 cookie 存储，并捕获 App 的 `HTTPAdditionalHeaders` 重新贴上，否则登录态会丢 |
| 装载时机 | hook 安装**移出 dyld 路径**（延到 main queue 第一拍），每个 hook 单独 try/catch 并逐条打日志。在 dyld 里 swizzle，一旦写错就是 App 连一帧都画不出来就死；延后一拍既够早（能拦到 App 真实流量）又让崩溃日志可读 |
| 安全模式 | 连续两次启动即崩 → 第三次自动禁用全部 hook，保证 App 可用；面板里能读崩溃报告并一键恢复。版本号变化会自动清除安全模式 |
| 崩溃记录 | 未捕获异常 + SIGABRT/SEGV/BUS/ILL/FPE/TRAP 都写进 `crash.log`（含 backtrace 与 ObjC 调用栈），面板可看可分享 |
| 类簇安全 | `NSURLSession(Configuration)` 是类簇，公开类上往往没有实现。策略是：**公开类挂一次**（覆盖正常调用点）+ **只在真正自己实现该方法的私有子类上再挂一次**。少了后半句会漏挂，少了"只在自己实现时"这句会把自己的 hook 当成原实现 → 无限递归 |
| 背景会话 | 绝不给 background session 塞自定义协议：NSURLSession 遇到这种任务会直接抛异常，等于 App 一有后台请求就崩 |
| 海外限制 | 给网易 API 请求注入 `X-Real-IP: 118.88.88.8` |
| ATS | `http://` 音源走自写的裸 socket HTTP 客户端，完全绕开 App Transport Security；`https://` 走 NSURLSession |

---

## 2. 音源实测状态（2026-10，逐条真机外网验证）

| 音源 | 搜索 | 换直链 | 结论 |
|---|---|---|---|
| **酷我 `kuwo`** | ✅ `search.kuwo.cn/r.s` | ✅ `antiserver.kuwo.cn/anti.s` | **主力**。周杰伦《晴天/稻香/夜曲》《小苹果》等 5/5 全部拿到 320k 真链 |
| **波点 `bodian`** | ✅ 复用酷我曲库 | ✅ `bd-api.kuwo.cn` 签名接口 | **可用，且是独立通道**（不同域名、不同鉴权），返回 `audioHttpsUrl`，还带 `bitrate/duration` |
| 酷狗 `kugou` | ✅ `mobilecdn.kugou.com` | ⚠️ `trackercdn` 只对权利已清的歌有效 | 付费歌返回 `status:2`，老接口直接 `"需要付费"`。**部分可用** |
| 咪咕 `migu` | ✅ `search_all.do` | ❌ `201007 请求失败` | 匿名被服务端拒绝，**必须配 cookie**（`providerCookies.migu`），否则只能贡献元数据 |

> 关键教训：酷狗 `trackercdn` **不能带错的 `album_id`** —— 加了错的 album_id，本来能用的请求会变成 `status:2`。所以插件先不带 album_id 试，再退到带。`wwwapi.kugou.com` 需要注册过的设备 `dfid`，匿名返回 `err_code 30020`，不用。

### 波点接口是怎么挖出来的

波点官网只是下载页，真实接口在 `bd-api.kuwo.cn`，裸请求一律 **HTTP 402 Payment Required**（是网关拦截，不是真付费墙）。加 `csrf` + `Cookie: kw_token=<同值>` 后网关放行，剩 `{"code":-10,"msg":"参数错误"}` —— 说明缺的是**签名**。

签名算法（`src/UNMBodianSign.m`，已用录制的真值做单元测试）：

```
timestamp = Date.now()
query     = URL 里 '?' 之后的部分，去掉所有非字母数字，再把剩下的字符升序排序
sign      = md5("kuwotest" + query + url.pathname)
最终 URL  = <原 URL>&timestamp=<ts>&sign=<sign>
```

还差最后一块拼图：App 身份头 `plat: ar`、`channel: aliopen`、`ver: 3.9.0`、`devid: <随机数字>`、`host: bd-api.kuwo.cn`、`user-agent: Dart/2.19 (dart:io)` —— 没有这些，网关在检查签名之前就 402 了。

盐是字面量 `kuwotest`。验证通过的请求与响应：

```
GET http://bd-api.kuwo.cn/api/play/music/v2/audioUrl?&br=320kmp3&musicId=51685512
    &timestamp=1792175305170&sign=59c4168ac69ea2d943ae24183163eb3a
->  {"code":200,"data":{"audioUrl":"http://bd-bj.kuwo.cn/...mp3?from=bodian",
                        "audioHttpsUrl":"https://bd-bj.kuwo.cn/...",
                        "format":"mp3","duration":269,"bitrate":320,"size":"10.3Mb"}}
```

参考实现对这套东西的实现我也对照过（本项目是独立的 Objective-C 重写，只借鉴了接口形态）。

---

## 3. 构建

本地**不需要 Mac**：Linux 上 `clang` + `lld`（lld 能直接产出 Mach-O，不用 cctools）+ 一份 iPhoneOS SDK 就够。

```bash
# 只拉一个 SDK，别整仓 clone
git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git ~/sdks
cd ~/sdks && git sparse-checkout set iPhoneOS16.5.sdk

sudo apt install -y clang lld llvm make fakeroot dpkg-dev

cd netease-unm-ios
IOS_SDK=~/sdks/iPhoneOS16.5.sdk ./tools/build-dylib.sh   # -> dist/UNMiOS.dylib
./tools/pack.sh                                          # -> dist/UNMiOS.deb（有 ldid 则签名）
```

产物已在本机验证过：`arm64`、`LC_CODE_SIGNATURE` 存在、`__mod_init_func` 里有构造函数、
14 个 `UNM*` 类全部在二进制里、substrate 引用 0、`-Wall` 零警告。

- **没有 Mac 也不想装环境** → 推上 GitHub，`.github/workflows/build.yml` 会在 macOS runner 上
  自动跑测试 + 构建，Artifacts 直接下 `UNMiOS-dylib`。
- **越狱 deb** → `export THEOS=~/theos && make package`。
- 只出 `arm64`：App Store 的网易云就是 arm64；Linux 版 clang 会把 arm64e 折叠成 arm64，硬拼也没意义。

---

## 4. 巨魔注入（TrollStore / TrollFools）

> 前置：设备已装 **TrollStore**（iOS 14.0b2–16.6.1 / 16.7 RC / 17.0）。

1. 装 [TrollFools](https://github.com/Lessica/TrollFools)：下 IPA → 用 TrollStore 安装。
   它靠 `insert_dylib` + ChOma 原地改 App 二进制，再用 TrollStore 的签名能力重签，
   **所以 App Store 版网易云也能注入**，不用先重签 IPA。
2. 打开 TrollFools → 选 **网易云音乐** → `+` / 选文件 → 选 `dist/UNMiOS.dylib`。
3. 等它改完包（重签，图标可能闪一下），**完全杀掉**网易云再启动。
4. 放一首原来灰掉的歌。

### 确认生效

装上后应该出现一个悬浮球（在屏幕右侧）：

- **红色** = 插件已加载但还没拦到任何请求
- **绿色** = 已经在拦截/改写

点球或摇一摇打开面板，日志里也会打：

```
UNMiOS 1.1.0 loaded into com.netease.cloudmusic
config: enabled=1 providers=kuwo,bodian,kugou,migu ... menu=1/1/0
interceptor installed (getter: ok, setter: ok, headers: ok, session: ok)
菜单入口：开（悬浮球）/ 开（摇一摇）/ 关（导航栏）
```

`interceptor installed` 那一行很关键：四个 `ok` 至少要有一个是 `ok`，
如果全是 `no`，日志里会额外写一行红字提示，说明拦截层完全没挂上。

命中时：

```
[eapi/song/enhance/player/url] 186016 《晴天》 (1812 -> 1903 bytes)
解灰命中 id=186016 《晴天》 -> kuwo (0.96, 晴天)
[playlist/detail] 内嵌权限解锁 312 项
```

日志文件：`<App 容器>/Library/Caches/unmios/unmios.log`（面板里的「查看日志」也能看，还能直接分享）。

---

## 5. 配置

首次启动会在沙盒里写一份模板，**默认值开箱即用**。要改就用 Filza 编辑：

```
<App 容器>/Documents/unmios.plist
```

也支持（后者覆盖前者）：

```
/var/mobile/Library/Preferences/com.yg.unmios.plist
<App 容器>/Library/Preferences/com.yg.unmios.plist
<App 容器>/Documents/unmios.plist
<App 容器>/Documents/unmios.json
```

改完不用重启，**2 秒内自动重载**。

| 键 | 默认 | 说明 |
|---|---|---|
| `enabled` | `true` | 总开关 |
| `providerOrder` | `[kuwo, bodian, kugou, migu]` | 音源优先级；删掉某个即禁用 |
| `providerCookies` | `{}` | 例如 `{"migu":"<sid>"}`。**咪咕必须配才能出链**；酷狗也可能需要 |
| `rewritePlayerURL` / `rewriteDownloadURL` / `rewritePrivilege` | `true` | 三个接口的重写开关 |
| `enableXRealIP` / `xRealIP` | `true` / `118.88.88.8` | 解海外锁区 |
| `lookupTimeoutMS` | `2000` | 单音源单次请求超时 |
| `totalTimeoutMS` | `5500` | 单首歌全部音源的预算，超了放弃（避免卡播放） |
| `maxLookupsPerResponse` | `3` | 一个响应里最多换几首 |
| `prefetchFromPrivilege` | `true` | 权限接口解锁后立刻后台预取 |
| `prefetchConcurrency` | `2` | 并发预取数 |
| `matchThreshold` | `0.60` | 匹配阈值，调高更严 |
| `matchDurationTolerance` | `6.0` | 时长容差（秒） |
| `neteaseDetailFallback` | `true` | 缺元数据时用网易公开 detail 接口补齐 |
| `logLevel` | `3` | 0 关 / 1 错误 / 2 警告 / 3 信息 / 4 调试 |
| `logEveryIntercept` | `false` | 打每个被拦截的请求 |
| `discoveryMode` | `false` | 只观察不改写：打所有请求 + **App 侧调用栈** + dump 类名到 `classes.txt` |
| `extraHooks` | `[]` | 逃生口：`["ClassName:selector"]`，`+` 前缀表示类方法。只接受**零参数、返回对象**的方法（不用 libffi 转发变参不安全），返回 `NSData`/`NSDictionary` 会被走一遍宽松重写 |
| `cacheTTLHours` | `168` | 元数据/匹配缓存有效期 |
| `showFloatingButton` | `true` | 悬浮球入口 |
| `enableShakeMenu` | `true` | 摇一摇打开面板 |
| `showNavBarEntry` | `false` | 导航栏「UNM」按钮（可能和 App 冲突，默认关） |

App 内面板改的所有值都写进 `<沙盒>/Documents/unmios.plist`，和手改文件是同一份配置。

---

## 6. 客户端换版本后怎么修

```
1. 配置 discoveryMode = true
2. 重启 App，播一首灰歌
3. 看 unmios.log：
   ├ 有 [discovery] POST interface3.music.163.com/eapi/song/enhance/player/url
   │   → 走的是 URL Loading System，只是接口路径变了，改 src/UNMInternal.m
   │     的 UNMEndpointForPath 即可
   └ 完全没有这行，但下面的调用栈里出现网易云的类
       → 把栈里那个类和方法写进 extraHooks
4. 同时看 classes.txt（全部类名 + 重点类的完整方法列表）
```

## 7. 测试

`tools/run-tests.sh` 跑的是**同一份源码**（不是重写），对录制下来的真实报文做断言：

- MD5（含 UTF-8 输入）与 **波点签名对真值向量**的复现
- 标题归一化（去 `(Live)`、`【纯音乐】`、全角括号、HTML 实体）
- 模糊匹配：精确命中 > Live 版 > 阈值；同歌手不同歌、同歌名不同人**必须被拒**
- 酷我 `rformat=json` 的单引号 JSON 容错解析
- 响应重写：灰歌被换、**能播的歌一个字节都不动**、`privilege` 的 `st/pl/level/chargeInfo` 正确改写、
  `download/url` 的 dict 形态、无关接口原样透传但元数据被收割
- 出厂配置默认值（音源顺序、阈值、超时关系、无内置 cookie）

```bash
./tools/run-tests.sh      # 需要 macOS；CI 里已经挂上（推代码自动跑）
```

> 为什么不在 Linux 上跑：GNUstep 默认的 legacy ABI **不支持为 `@property` 自动合成 ivar**，
> 本项目的模型/配置类在那种 ABI 下编译不过（要修就得给头文件塞一堆 ivar，为测试污染生产代码）。
> macOS 的 non-fragile ABI 没这个问题，所以 CI 用 macOS runner。

## 8. 目录结构

```
netease-unm-ios/
├─ src/
│  ├─ UNMHook.{h,m}          自建 libobjc swizzler（不依赖 substrate，拒绝挂不存在的方法）
│  ├─ UNMVersion.h           版本号单一来源
│  ├─ UNMCrashGuard.{h,m}    崩溃记录（异常 + 信号 + backtrace）与安全模式
│  ├─ UNMLog.{h,m}           分级日志，写沙盒 + NSLog
│  ├─ UNMStats.{h,m}         运行时计数 + 事件环形缓冲（菜单和诊断的数据源）
│  ├─ UNMConfig.{h,m}        plist/JSON 配置，热重载，可写回
│  ├─ UNMUtil.{h,m}          自实现 MD5、全角转换、归一化、容错 JSON、时长解析
│  ├─ UNMHTTP.{h,m}          NSURLSession + 裸 socket 双通道 HTTP（抗 ATS）
│  ├─ UNMInternal.{h,m}      接口路径识别、域名判定
│  ├─ UNMProvider.{h,m}      音源注册表 + 候选模型 + cookie 读取
│  ├─ UNMKuwoSearch.{h,m}    酷我/波点共用的搜索后端（含结果缓存，避免重复搜）
│  ├─ UNMBodianSign.{h,m}    波点签名（纯函数，可单测）
│  ├─ UNMProviderKuwo.m      酷我（antiserver 三重退路）
│  ├─ UNMProviderBodian.m    波点（签名接口，优先 https 链接）
│  ├─ UNMProviderKugou.m     酷狗（sqhash→320hash→hash 阶梯，不带 album_id）
│  ├─ UNMProviderMigu.m      咪咕（strategy/listen-url v2.4 + 旧接口兜底，支持 cookie）
│  ├─ UNMMatcher.{h,m}       标题/歌手/时长打分
│  ├─ UNMStore.{h,m}         元数据表 + 匹配缓存 + 预取 + 并发去重
│  ├─ UNMRewriter.{h,m}      三个接口 + 内嵌 privileges 的响应重写
│  ├─ UNMURLProtocol.{h,m}   拦截器 + 上游 session + 头捕获 + 类簇安全的协议注入
│  ├─ UNMDiagnose.{h,m}      音源自检（不依赖网易云）
│  ├─ UNMMenu.{h,m}          App 内面板：悬浮球 / 摇一摇 / 导航栏按钮
│  └─ UNMiOS.m               入口：构造器、崩溃守卫、注册、装 hook、菜单
├─ test/                     macOS 上跑的单元测试 + UNMStore 桩
├─ tools/{build-dylib.sh, pack.sh, run-tests.sh}
├─ Makefile  control  UNMiOS.plist  layout/
└─ .github/workflows/build.yml   test + build + upload
```

## 9. 还是灰的 / 播不了 —— 按这个顺序查

**第一步：看有没有悬浮球。** 球是插件加载的唯一铁证。

```
球没出现
  └─ 注入没成功。九成是这三种情况：
       ① TrollFools 改的不是这台设备上那份 App
       ② 改完没等它重签完成就启动了
       ③ 启动前没完全杀掉进程（后台卡片上滑也要清掉）
     → 重新注入一次，注入后先完全杀进程再启动

球出现了，但还是灰
  └─ 点球（或摇一摇）→ 「诊断」，看第一行「拦截：N」

     拦截 = 0
       └─ 请求根本没进到插件。开「发现模式」+「记录每个被拦截的请求」→ 重启 App
          → 播一首灰歌 → 回「诊断」看有没有 [discovery] 行和调用栈
             • 有 /eapi/song/enhance/... 行 → 拦截正常，是名单/时机问题，把日志发我
             • 没有任何网易云的 URL → 这个版本没走 URL Loading System，
               把 discovery 打印出来的调用栈发我，我用 extraHooks 精确挂它

     拦截 > 0，但「改写 = 0」
       └─ 拦到的是别的接口，没拦到 privilege/player_url。
          开「记录每个被拦截的请求」，看事件列表里到底有哪些路径。
          如果只有 /song/detail 没有 privilege → 列表的灰来自 detail 里内嵌的 privileges，
          规则版本应该已经覆盖；把事件列表发我

     改写 > 0，但列表还是灰
       └─ 这是 UI 缓存问题：网易云把 privilege 结果存在本地。
          去 App「设置 → 清除缓存」清一次，然后完全杀掉再启动

     能变白，但点了不播
       └─ 看「自检」是不是全 ❌
             • 全 ❌  → 你的网络到酷我/波点被墙了（某些海外线路会），换个网络试
             • 有 ✅  → 换源成功但播放被拒，把「诊断」里的「换源命中」和最近事件发我
```

**先跑「自检」再抱怨。** 自检不经过网易云、不用播放任何歌，直接测四个音源能不能出链。
自检全绿但歌还是灰 → 问题在拦截层；自检全红 → 问题在网络/音源，跟插件没关系。

其他常见现象：

| 现象 | 处理 |
|---|---|
| 播放有 1–2 秒延迟 | 冷启动换源。第二次播同一首走缓存；`prefetchFromPrivilege` 也会预热 |
| 咪咕一直 ❌ | 正常，匿名被拒。面板 →「参数」→ 填咪咕 cookie |
| 酷狗一直 ❌ | 该歌权利未清，日志会写 `kugou 无直链（付费/需登录）` |
| 登录/推送异常 | TrollFools 重签后 entitlements 可能掉，改用 TrollStore 装的 IPA 版本再注入 |
| App 启动即崩 | 载入路径不对。用默认的 `@executable_path/UNMiOS.dylib`，或改用 deb |
| 悬浮球挡住按钮 | 长按拖动，会吸附到最近的边并记住位置 |

## 10. 边界

- **只是换源**，不是破解网易的版权。音质取决于第三方（通常 320k mp3），歌词/评论/云盘同步仍是网易的。
- 第三方直链**有 TTL**。插件只缓存「哪首歌对应哪个音源的哪个 id」，真正的直链每次按需重取
  （内存缓存 90 秒），所以不会拿到过期链接。
- 音源接口是活的。默认给四个源、两个独立通道（酷我 + 波点）就是冗余设计：一个挂了还有另一个。
- `/weapi/` 请求体是加密的，但**响应仍是明文**，所以响应重写不受影响；目前也不需要读请求体。
- 本项目是独立实现，只在接口形态上参考了公开的社区实现；不含任何账号、cookie 或密钥。
