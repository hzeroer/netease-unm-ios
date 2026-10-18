# UNMiOS V3.2.1

只修文档与一处名不副实的代码：**音源其实一直是波点主力、咪咕备用**，但 README 的开头还写着「当前只支持咪咕」。

## 文档纠正

`## 音源` 整节重写：

- 开头明确「默认 **波点主用、咪咕备用**，`providers` 出厂值 `bodian,migu`」
- 波点单列一节（搜索 `search.kuwo.cn/r.s`、取链 `bd-api.kuwo.cn`、签名算法），并说明曲库更全
- 咪咕保留为备用，两个 id（`contentId` / `copyrightId`）都必须给这一点保留
- 原「为什么只留这一个」→「为什么是这两个」，表格内容不变

## 酷狗：说删了其实还在

上一版 README 写「除波点、咪咕外代码已全部删除」，但 `UNMProviderKugou.m` 一直参与编译、
启动日志里也一直打印 `sources: migu,kugou,bodian`——只是不在默认顺序里，属于**注册了但从不被调用**的死代码。

这一版真的删了：

| 位置 | 处理 |
|---|---|
| `src/UNMProviderKugou.m` | 文件删除 |
| `src/UNMiOS.m` | 取消前置声明与 `UNMRegisterProvider` 调用 |
| `src/UNMMenu.m` | 去掉音源标签、canonical 顺序、cookie 输入入口 |
| `UNMConfig.h/.m`、`UNMProvider.h`、`UNMMatcher.h` | 过时注释纠正 |

验证：

```
$ strings dist/UNMiOS.dylib | grep -E "^(bodian|migu|kugou|kuwo)$" | sort -u
bodian
migu
$ strings dist/UNMiOS.dylib | grep -ci kugou
0
```

## 体积

```
609,808 bytes   arm64  Mach-O dylib
sha256  4c3ef592a5fb14df440bc60afc8a324970cc0c800e23b45c1267161ebf0dfe6e
```

比 V3.2.0 少 4 KB（整个酷狗模块）。

## 功能

与 V3.2.0 完全一致：换源播放（波点主用 / 咪咕备用）、收藏（歌单路线，选择即收藏）。
听歌排行的结论也不变——服务端按下架状态过滤，插件做不到。

---
# UNMiOS V3.2.0

这一版只做一件事：**把收藏做成了真的能用**。听歌排行那一整块删掉了。

## 新增：收藏（歌单路线）

客户端对下架歌曲的收藏拦在前面——点红心只弹「版权方要求该资源无法操作」，**一个请求都不发**
（`/eapi/song/like` 从头到尾没出现过）。所以插件不去碰那个按钮，改走「把歌加进歌单」。

服务端对「加进歌单」的校验和「红心」不同：只看你有没有这个歌单的写权限，不看这首歌能不能播。
于是同一首歌，红心失败，加进歌单成功。

菜单里只有一行：

```
收藏
  选择歌单并收藏…
```

- 点开列出**你自己创建的歌单**，订阅来的会被过滤掉（写不进去）
- **选中的那一刻就完成收藏**，不用再点第二次
- 当前目标后面带 `✓`
- 选择记在 `unmios.plist` 的 `favoritePlaylistId`，清空即回到「我喜欢的音乐」

实现走明文接口 + App 自己的 Cookie：

```
GET  /api/nuser/account/get          → userId
GET  /api/user/playlist?uid=…        → 找 specialType==5
POST /api/playlist/manipulate/tracks → op=add&pid=…&trackIds=["id","id"]
```

`trackIds` 要把同一个 id 写两遍，写一遍不生效。

当前歌曲靠 hook `NMSong -setPlayUrlInfo:` 记录，所以**换源播放的歌也能正确收藏**——
这一点之前踩过坑：早先只在投放替代地址时记录，结果收藏到的是别的歌（收藏 185899 霍元甲那次）。

## 移除：听歌排行

菜单里不再有「听歌排行」小节，相关代码整段删除：

| 删除项 | 说明 |
|---|---|
| 菜单「补报播放」「查询排行」 | 两行都没了 |
| `UNMPlayReport.h/.m` | 整个模块 |
| `playLog_jarInfoDic` setter / getter 钩子 | 纯诊断用 |
| `dumpPlayRecordAPI` 类扫描 | 纯诊断用 |
| `UNMURLProtocol` 的 clientlog 请求体日志 | 纯诊断用 |

**为什么删**：查到最后是服务端的规则，不是请求写得对不对。

| 观察到的事实 | 说明 |
|---|---|
| 客户端**确实**为换源歌曲上报了播放，`id` 正确 | 上报通道一直是通的 |
| 载荷里 `time:0`、`end:"ui"` | 客户端把这次播放当作被切走的中断 |
| 按完整字段重发 `end:"playend", time:200` | 服务端收下 `code 200`，仍不计入 |
| 换成排行榜真正的数据源 `api/feedback/weblog` | 同上 |

正常歌曲能进排行，周杰伦这些下架歌不进。结论：**服务端按「这首歌对你是否可播」过滤播放记录**，
和上报字段无关。这跟收藏那次是同一类限制，区别是收藏有绕路（歌单），排行没有。

## 体积

```
613,968 bytes   arm64  Mach-O dylib
sha256  bda801c5af7175dd73be5b7ebb793ee8e7e7bfc7a3316ba679ff8d394168c8c9
```

比加了排行的版本还小一点（排行模块和几个诊断钩子都去掉了）。

## 保持不变

- 换源播放：波点主用、咪咕备用
- 崩溃安全网、自检、诊断页、导出类结构

## 仍然存在的问题

1. **下架歌不进听歌排行**（服务端限制，已在上文说明）
2. 搜索页热搜榜一闪而过
3. 部分曲目没有替代源（冷门翻唱、纯音乐）
4. 偶尔把伴奏版当成原曲匹配上
