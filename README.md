# MyDeepSeek

> HarmonyOS 原生实现的 DeepSeek 客户端（ArkTS + 原生 C），**零第三方运行时依赖**。

> 逆向复刻 DeepSeek Web 端 API 的技术实现演示，非官方客户端。可拿去自己修改编译，也可以发账号给我拉进测试组直接安装使用。

---

## 目录

- [一、项目定位](#一项目定位)
- [二、核心机制实现](#二核心机制实现)
  - [1. 反机器人 PoW：DeepSeekHashV1](#1-反机器人-powdeepseekhashv1)
  - [2. 请求体双层加密（AES + RSA-OAEP）](#2-请求体双层加密aes--rsa-oaep)
  - [3. SSE 流式解析：双协议兼容](#3-sse-流式解析双协议兼容)
  - [4. 增量渲染性能：三层优化](#4-增量渲染性能三层优化)
  - [5. Markdown / LaTeX 渲染管线](#5-markdown--latex-渲染管线)
  - [6. 其他关键机制](#6-其他关键机制)
  - [7. 兜底策略矩阵](#7-兜底策略矩阵)
- [三、目录结构](#三目录结构)
- [四、使用与构建指南](#四使用与构建指南)
- [五、第三方组件与归属](#五第三方组件与归属)
- [六、⚠️ 发布与合规提示](#六️-发布与合规提示)
- [七、许可证](#七许可证)

---

## 一、项目定位

本项目用一个**纯 ArkTS 原生应用**复现了 DeepSeek 网页版的核心能力：

| 能力 | 实现方式                       |
| :--- |:---------------------------|
| 短信验证码登录 | 直连私有 API，自带 PoW 求解 + 请求体加密 |
| 流式对话（深度思考 / 联网搜索） |  SSE 双协议解析器                |
| Markdown / 代码高亮 / LaTeX 公式 | 研解析器与渲染器                   |
| 文件上传与引用 | multipart 上传 + 解析状态轮询      |
| 语音输入 / 朗读 | 端侧 ASR + 服务端神经 TTS         |
| 会话历史与多轮分支 | 服务端会话列表 + 本地消息树            |



---

## 二、核心机制实现

### 1. 反机器人 PoW：DeepSeekHashV1

DeepSeek 的部分接口（发码、登录、文件上传、对话提交）要求携带一个**工作量证明**票据，否则返回 `biz_code 40300/40301/40303/40304`。

#### 1.1 自定义哈希算法

`DeepSeekHashV1` **不是标准 SHA3-256**。它采用 SHA3-256 的填充规则（pad `0x06`，rate 136 字节，输出 32 字节），但 **Keccak-f[1600] 置换跳过第 0 轮**（仅执行 rounds 1..23）：

```
entry/src/main/ets/service/DeepSeekHash.ets
  ├── RC[]            24 个轮常量表
  ├── keccakF(s)      全展开的置换，50 个 uint32 状态字，无位数组
  ├── deepSeekHashV1Hex(message)        → 64 位十六进制
  └── deepSeekHashV1Matches(message, w)  → 直接比对状态字，命中即返回
```

**性能关键点**：朴素实现每轮迭代都要拼出 64 字符十六进制串再比较。`deepSeekHashV1Matches()` 改为把目标 challenge 预解析成 8 个 uint32（`parseDeepSeekHashWords()`），**逐字比对状态字、首个不匹配立即返回**。省掉了整个字符串分配，这是纯 ArkTS 路径能有可用速度的前提。

#### 1.2 求解问题

寻找 `n ∈ [0, difficulty)` 使得：

```
DeepSeekHashV1(`${salt}_${expireAt}_${n}`) === challenge
```

实测难度：发码 `difficulty=20`，登录 `difficulty=80000`。

#### 1.3 双实现 + 原生加速

```
entry/src/main/ets/service/PowSolver.ets
  @Concurrent solvePowTask(...)        ← 运行在 taskpool 工作线程
    ├── ① solvePowNative()             ← 原生 C 快路径（~100×）
    └── ② 纯 ArkTS 暴力循环            ← 原生异常/返回 -2 时兜底
```

原生实现 `entry/src/main/cpp/deepseek_pow.c` 相比 ArkTS 版多了一个关键优化——**块模板预计算**：

消息格式恒为 `salt_expireAt_n`，前缀（salt + 分隔符 + expireAt）在所有候选中**恒定不变**。因此 C 版：

1. 一次性把前缀写入 136 字节 `tmpl[]` 缓冲区；
2. 预先在第 135 字节放好 `0x80` 结束标记；
3. 每个候选只需写入 `n` 的十进制数字 + `0x06` 填充字节；
4. 直接从字节缓冲组装 34 个小端 uint32，跑 `keccakF`。

NAPI 绑定见 `entry/src/main/cpp/napi_init.cpp`，返回约定：`>= 0` 为解、`-1` 未找到、`-2` 出错（触发 ArkTS 兜底）。

#### 1.4 安全网：原生解必须复验

即使原生返回了 `n`，ArkTS 侧**仍会用 `deepSeekHashV1Matches` 复验一次**才返回。这防的是 C 与 TS 两份实现之间的移植偏差——一旦有偏差，会产出"本地看来自洽、服务端拒绝"的错误答案，且极难排查。

#### 1.5 票据预热：把 PoW 从关键路径彻底移出

`DeepSeekWebClient.ets` 中的 `PowTicketManager` 是让用户**感觉不到 PoW 延迟**的关键：

```
用户输入期间          发送消息
     │                    │
     ├─ 后台 warm() ──────┤  ← 预取挑战 + 预解挑战（LOW 优先级 taskpool）
     │   (App 启动即调用)  │
     │                    ├─ getHeader() 取缓存票据（剩余寿命 >30s 才算可用）
     │                    ├─ 用掉后立即再 warm() 下一张
     │                    └─ 缓存/in-flight 都没有 → 现场获取+求解（兜底）
```

- `ChatPage.aboutToAppear()` 启动即预热，**首条消息也不付延迟代价**；
- `ChatPage.runStream()` 中 PoW 票据 Promise 与 `createSession()` **并行启动**，两者都不阻塞彼此；
- 票据剩余寿命不足 30 秒即视为不可用，避免边界失效。

### 2. 请求体双层加密（AES + RSA-OAEP）

DeepSeek Web 端 bundle 中的拦截器 `eO` 对特定 POST 端点强制启用请求体加密。本项目在原生侧完整复刻：

```
明文 JSON
  → UTF-8 字节
  → AES-128-CBC (PKCS7)  [随机 16B key + 随机 16B IV]  → 密文 = HTTP body
  → key(16B) || IV(16B)  [32 字节]
  → RSA-2048-OAEP (SHA-256, MGF1-SHA-256) 加密           → base64
  → 请求头 x-request-encryption-key
```

实现：`entry/src/main/ets/service/RequestCipher.ets`

#### 踩坑记录：HarmonyOS 的 OAEP 规格串

HarmonyOS `cryptoFramework` 要求 OAEP 规格为 **4 段式**：

```typescript
const RSA_CIPHER_SPEC: string = 'RSA2048|PKCS1_OAEP|SHA256|MGF1_SHA256';
const AES_CIPHER_SPEC: string = 'AES128|CBC|PKCS7';
```

**MGF1 必须显式指定 SHA-256**——WebCrypto 的 `RSA-OAEP` 默认 MGF1 用同一哈希，但 HarmonyOS 不隐式对齐。若写成 3 段式，服务端解密会**静默失败**（无异常、仅返回业务错误），极难定位。

RSA 公钥以 SPKI/X.509 base64 常量内置（DeepSeek 生产公钥，**公钥本身是公开的**，服务端解密必需）。另提供 `localSelfTest()`：固定 key/IV 加密→解密回环比对，RSA 因无私钥无法回环，改为校验密文长度恰为 256 字节。

### 3. SSE 流式解析：双协议兼容

服务端存在**两套并存的流式协议**，客户端必须同时支持。

#### 3.1 旧协议（类型化增量）

```json
{"v": "增量文本", "t": "think | finish"}
```

`t=think` 走思考通道，`t=finish` 标记思考阶段结束，此后无类型标记的增量归属答案。

#### 3.2 新协议（路径寻址操作流）

```json
{"p": "response/fragments/-1/content", "o": "APPEND | SET | BATCH", "v": ...}
```

`p` 是类 JSON-Pointer 的**服务端响应树地址**，`o` 是操作类型。路径下标的语义：

| 下标 | 含义 |
| :--- | :--- |
| `-1` | 当前流式目标 fragment（新协议） |
| `≥ 0` | 旧协议的位置型 fragment |
| `results` / `content` | fragment 的子字段 |

#### 3.3 状态机

`CompletionStream` 用两个结构追踪 fragment 类型：

- `fragModelTypes: string[]` — 新协议：已提交 fragment 的类型序列，**末元素即当前流式目标**；
- `fragmentTypes: Map<number, string>` — 旧协议：位置下标 → 类型。

`currentFragType()` 在模型为空时（首个 fragment 尚未提交）**推断**当前目标：

```typescript
if (thinkEnded || !reqThinkingEnabled) return 'RESPONSE';
return 'THINK';
```

#### 3.4 权威全文替换：修正增量遗漏

服务端有时会下发**完整 fragment 数组**（`applyFragmentsArray()`），其中包含增量流从未覆盖过的**种子/前缀文本**。此时客户端重算思考/答案全文，并通过 `onThinkingReplace` / `onAnswerReplace` 回调**全量替换**本地内容——这纠正了单纯依赖增量拼接会丢失前缀的问题。

> 技巧：替换前先与 `lastThinkAll` / `lastAnswerAll` 比对，内容未变则不触发回调，避免每帧都重排。

#### 3.5 搜索 fragment 隔离

`SEARCH` / `TOOL_SEARCH` 类型的 fragment 走**独立通道**（`onSearchResults` / `onSearchState`），其 content 是查询过程提示，**绝不会混入答案正文**。搜索阶段在首个思考/回答片段到达时结束。

#### 3.6 SSE 帧解析

`entry/src/main/ets/service/SseParser.ets`：

```typescript
const text: string = decoder.decodeToString(bytes, { stream: true });
```

`{ stream: true }` 是关键——它让解码器**保留跨块截断的多字节 UTF-8 序列**。一个中文字符可能被 TCP 分包切成两半，没有这个选项就会解出乱码。`flush()` 负责处理末尾没有换行符的最后一行。

### 4. 增量渲染性能：三层优化

朴素实现（每收到一个 SSE chunk 就重新解析整个答案）是 **O(n²)**，在长回答上必然卡死 UI。本项目分三层优化：

#### 第 1 层：硬边界增量解析缓存

`entry/src/main/ets/components/MarkdownRenderer.ets` 维护：

```
cacheKey      已确认稳定的文本前缀
cachedBlocks  已解析结果（只追加）
scanPos       增量扫描位置
```

`advanceBoundary()` 只向前扫描**新收到的行**，且仅在**解析结果与后续内容无关**的位置推进边界：

- 围栏代码块闭合（` ``` `）
- 块级公式闭合（`$$` / `\]`）
- 标题行 / 分隔线 / 脚注定义行
- 空行（且下一行必须已完整接收，且**不是列表项**——因为松散列表会跨空行继续编号）

边界之前的文本只解析一次并永久缓存，每次更新只重解析边界之后的短尾。

> 流式未闭合的代码块/公式仍会作为 block 输出（`codeClosed = false`），渲染器据此显示原始文本而非空白。

#### 第 2 层：100ms flush 节流

`entry/src/main/ets/pages/ChatPage.ets`：

SSE chunk 到达速度远高于 UI 渲染能力。页面把增量先写进普通字符串缓冲 `thinkingBuf` / `answerBuf`，再由 **100ms 定时器**统一拷进 `@Trace` 字段：

```typescript
this.flushTimer = setInterval(() => { /* buffers → assistant.thinking / .content */ }, 100);
```

这把重渲染频率限制在 **10Hz**，是长回答不卡顿的直接原因。

#### 第 3 层：节点复用 + 合并 + 缓存

**内容哈希 ForEach key**：ArkUI 的 `ForEach` 在 key 不变时会**复用节点而不重渲染**——这对增量更新是灾难（改动的块不会刷新）。因此 key 包含块的完整内容指纹：

```typescript
(b: MdBlock, idx: number): string => `${idx}_${blockSignature(b)}`
```

`blockSignature()` 是对块内所有字段（kind / level / depth / 任务状态 / 引用块 / 代码文本 / LaTeX 源 / 每个 span 的文本与样式标志 / 每个表格单元格）的 `hash*31` 滚动哈希。结果：**变了的块重建，没变的块复用**。

**另外两个优化**：

- `CodeHighlighter.mergeAdjacent()` 合并相邻同类 token，大幅减少 ArkUI 需要实例化的 `Span` 组件数量；
- 代码高亮与 LaTeX 解析各带 **LRU 缓存（上限 64）**，流式重复解析几乎零成本。

### 5. Markdown / LaTeX 渲染管线

```
原始 Markdown 字符串
   ↓  MarkdownParser.parseMarkdown()      → MdBlock[]   （块级 AST）
   ↓  MarkdownParser.parseInline()        → MdSpan[]    （行内 AST，逐块）
   ↓  MarkdownRenderer                     → @Builder 树
   ↓  MdInlineBuilder.buildInlineStyled()  → MutableStyledString
   ↓  StyledText                           → TextController.setStyledString()
```

#### 5.1 自研两级解析器

`entry/src/main/ets/components/MarkdownParser.ets`（625 行）：

- **块级**：行状态机，产出 `MdBlock[]`，覆盖标题 / 围栏代码 / 嵌套列表 / 任务列表 / 引用 / GFM 表格 / 分隔线 / 脚注定义 / 块级公式。
  - 嵌套列表用**缩进栈**实现：弹出所有缩进 ≤ 栈顶的层级，因此 2 空格、4 空格、Tab 混排都能正确嵌套（Tab 按 4 列制表位计算）。
  - 表格分隔行兼容 `:---` / `---:` / `:---:` 三种对齐写法。
- **行级**：字符扫描器，产出 `MdSpan[]`，每个 span 携带 `bold` / `italic` / `code` / `strike` 标志与 `linkUrl` / `imageUrl` / `footnoteRef` / `latexSource` 等附加信息。

#### 5.2 货币安全的公式识别

`$100 and $200` **不能**被当成公式。判定规则（全部满足才算行内公式）：

1. `$` 后紧跟的字符不是空白；
2. `$` 前的字符不是空白；
3. 内容不含 `$` 与换行；
4. 长度 ≤ 300；
5. 内容要么含 LaTeX 特征字符（`^ _ \ { }`），要么匹配 ≤20 字符的纯数学字符正则。

`$100` 因含空格与字母而被排除。

`\(` 与 `\[` 只有在**存在配对闭合符且内容含 LaTeX 特征字符**时才视为数学定界符，否则按普通转义处理。

#### 5.3 富文本：MutableStyledString

ArkUI 的 `Text` 本身不支持上下标、删除线与行内链接点击。本项目用 `MutableStyledString` + `StyledStringKey` 解决：

| StyleKey | 用途 |
| :--- | :--- |
| `FONT` | 颜色 / 字号 / 字重 / 斜体 / 字体 |
| `DECORATION` | 下划线、删除线 |
| `BASELINE_OFFSET` | 上下标、脚注/引用角标 |
| `BACKGROUND_COLOR` | 行内代码底色、引用角标底色 |
| `GESTURE` | 链接点击 |

> **两个 ArkUI 官方坑（代码注释中已标注）**：
> - `GestureStyle` 的回调对象**必须**由 `MutableStyledString` 的成员变量持有，否则会被 GC 回收，点击静默失效（`faqs-arkui-901`）。
> - `Span` 自身的触摸事件不触发（`faqs-arkui-888/1337`），因此**行内链接只能靠 `GestureStyle`**，没有第二条路。

引用角标解析（`resolveReference`）采用三级兜底，因为服务端 `cite_index` 的基准并不一致：精确匹配 → 数组下标 N → 数组下标 N-1。

#### 5.4 LaTeX：递归下降解析 + 原生布局

`entry/src/main/ets/components/LatexParser.ets` 递归下降解析出 `LatexNode` 树，覆盖 `\frac` / `\sqrt` / 上下标 / `\sum` `\prod` `\int` 限位 / `\text` 系列字体 / 重音符号 / 约 200 项符号表。

`entry/src/main/ets/components/LatexRenderer.ets` **完全用原生 ArkUI 布局**排版，不用 WebView、不用 Canvas：

| 结构 | ArkUI 实现 |
| :--- | :--- |
| 分数 | `Column { 分子 Row / Divider / 分母 Row }` |
| 根号 | `Row { 根号 Text / Stack { 体 Column ; 上横线 Row(height 1) } }` |
| 上下标 | `Row { 基 Text ; 脚本 Text .baselineOffset(±size) }` |
| 限位 | `Column { 上标 Row / 大算符 Text / 下标 Row }` |

**优雅降级**：矩阵环境、`aligned`、无法识别的命令会触发 `fail()`，把**整条公式回退为等宽源码**显示——绝不渲染空白，也绝不崩溃。

#### 5.5 代码高亮：单遍非回溯分词器

`entry/src/main/ets/components/CodeHighlighter.ets`（600 行）自研分词器，由**语言规则表**驱动：

支持语言：`javascript` / `typescript` / `jsx` / `tsx` / `java` / `c` / `cpp` / `python` / `bash` / `sh` / `zsh` / `sql` / `json` / `html` / `xml` / `css` / `scss` / `less`。

分词器按优先级依次尝试，**每个 `try*` 返回布尔保证只有一个分支消费输入**，因此严格线性时间：

```
tryHtmlComment → tryBlockComment → tryLineComment → tryString
  → tryBashVar → tryNumber → tryIdentifier → 兜底累加普通文本
```

语言差异处理相当细致：Python 三引号与 `f""`/`r""`/`b""` 前缀、JS 模板字符串（可跨行，区别于其他引号）、Bash `$VAR`/`${VAR}`/`$?`/`$#`、十六进制/二进制/八进制字面量、C/Java 数值后缀 `f`/`L`/`u`、CSS 单位与选择器、HTML 标签名（靠 `lastSigChar` 追踪前一个非空白字符，只有 `<` 或 `/` 之后的名称才算关键字）、SQL 关键字大小写不敏感。

配色为 One Dark 主题：关键字 `#C678DD`、字符串 `#98C379`、注释 `#5C6370`、数字 `#D19A66`、正文 `#ABB2BF`。

### 6. 其他关键机制

#### 6.1 持久化分层：按数据敏感度选 API

三个 Store 刻意使用**三种不同的 HarmonyOS API**：

| Store | API | Kit | 存储内容 |
| :--- | :--- | :--- | :--- |
| `TokenStore.ets` | `asset`（KeyStore 支撑的安全资产库） | AssetStoreKit | 登录 token |
| `SettingsStore.ets` | `preferences` | ArkData | 功能开关 |
| `DeviceIdStore.ets` | `preferences` | ArkData | 设备 UUID |

**登录 token 存 AssetStore 而非普通 Preferences**——它由 OS KeyStore 支撑、静态加密。写入用 `asset.Accessibility.DEVICE_FIRST_UNLOCKED`（首次解锁前不可用），三个方法全部同步（`querySync`/`addSync`/`removeSync`）并完整 try/catch 包裹——**KeyStore 故障降级为"未登录"，而不是崩溃**。

`DeviceIdStore` 生成 UUID v4 持久化，用于给服务端一个稳定设备指纹（对齐 Web 端 `localStorage` 行为）；Preferences 不可用时降级为内存 UUID，保证登录流程不中断。

#### 6.2 状态管理：纯 V2 装饰器

项目**完全不使用** `AppStorage` / `@Provide` / `@Consume` / `@Link`：

| 场景 | 机制 |
| :--- | :--- |
| 组件内状态 | `@ComponentV2` + `@Local` |
| 父传子 | `@Param` |
| 子回调父 | `@Event` |
| 对象模型 | `@ObservedV2` + `@Trace`（`ChatMessage` / `SearchResultInfo` / `ChatAttachment`） |

`@Trace` 打在**单个字段**上，因此改 `msg.content` 只重渲染读取该字段的组件，而非整个列表。

跨页面的全局服务用**模块级单例**（`TokenStore` / `SettingsStore` / `PowTicketManager` / `TtsService` / `AsrService` / `NavStackHolder`），不引入 DI 框架。

#### 6.3 导航：叠层透明命中测试

`entry/src/main/ets/pages/Index.ets` 的做法比较特殊：

`ChatPage` 作为**根内容直接渲染**（不放在 `Navigation` 内），避免 Navigation 的 NavBar 裁掉底部安全区。然后把 `Navigation(this.pathStack)` **叠在上面**，其 home 内容为空，并设 `hitTestBehavior(HitTestMode.Transparent)`：

- 无 destination 时 → 触摸穿透到下层聊天页；
- 推入 destination（登录页 / 网页回退）→ 位于上层，命中测试自然优先。

同时 `hideNavBar(true)` 会**破坏 Navigation 默认的返回拦截**，因此栈被注册到模块级 `NavStackHolder`，由 `Index.onBackPress()` 手动 pop。

#### 6.4 服务端 TTS：二进制帧 + 拉模式音频

`entry/src/main/ets/service/DeepSeekTtsService.ets`：

1. `POST /api/v0/auth/ticket`（若服务端要求 PoW 则求解后带 `x-ds-pow-response` 重试）→ 拿到票据；
2. WebSocket 连 `wss://chat.deepseek.com/api/v0/chat/tts/`；
3. 收到二进制帧：`4 字节大端 uint32 序号 || S16LE 单声道 24kHz PCM`；
4. 用 `DataView.getUint32(0, false)` 解析序号，`value.slice(4)` 取音频。

**拉模式写入**：不用已废弃的 `write()`，而是注册 `renderer.on('writeData', cb)`，由音频服务**主动来要**数据。`fillAudioBuffer()` 从 `PendingChunk[]` FIFO 队列取数据，跨缓冲区边界时正确切分，剩余部分补静音。

**ACK 流控**：1 秒定时器发 `{"event":"ack","received_seq":N,"played_seq":M}`。`finish` 时按 `receivedBytes / 48`（24kHz × 2 字节 = 48 字节/毫秒）估算剩余播放时长，等待 `总时长 - 已播 + 250ms` 才判定完成——**因为 WebSocket 早就关了，音频还在播**。

#### 6.5 端侧 ASR：竞态与 VAD

`entry/src/main/ets/service/AsrService.ets`：

- **竞态处理**：`finish()` / `cancel()` 可能在引擎 `onStart` 回调触发**之前**被调用。服务用 `sessionStarted` + `finishPending` / `cancelPending` 标志位，在 `onStart` 里重放——这样"快速按下又松开"不会丢 utterance。
- **VAD 放宽**：`vadEnd: 60000` 与 `maxAudioDuration: 60000` 把静音超时拉到最大，因为默认约 2 秒的 VAD 截断是按住说话时"说一半被切掉"的根因。

结果分两个缓冲：`finalText`（已提交结果）+ `partialText`（最新暂定），实时展示为两者拼接。

#### 6.6 Mermaid：WebView + JS 桥

`entry/src/main/ets/components/MermaidView.ets` 是**唯一**用 WebView 渲染内容的地方。加载 `rawfile/mermaid_view.html`（内含离线 `mermaid.min.js`），通过 `javaScriptProxy` 暴露 `MermaidBridge`（`getCode()` / `onRendered(h)` / `onError(msg)`）。页面侧渲染后用 `getBoundingClientRect().height` 量高回传，原生侧据此设定 WebView 高度（钳制在 `[120, 640]`）。

三态机：`LOADING` → `CHART` → `FALLBACK`。JS 报错、页面错误、或**流式过程中代码块尚未闭合**时进入 `FALLBACK`，显示原始代码块。

### 7. 兜底策略矩阵

本项目的一条设计原则：**每个可能失败的环节都有降级路径**。

| 主路径 | 失败后降级 |
| :--- | :--- |
| 服务端神经 TTS | → 端侧 `CoreSpeechKit` TTS（并先剥离 Markdown 标记，避免念出 ` ``` ` 和 `**`） |
| 原生 C PoW | → 纯 ArkTS PoW（且原生解仍需 ArkTS 复验） |
| 原生短信登录 | → WebView 官方登录页（隐藏入口：长按标题 ≥1 秒） |
| LaTeX 原生排版 | → 等宽源码（不渲染空白、不崩溃） |
| Mermaid 图表 | → 原始代码块 |
| 未知代码语言 | → 无高亮单色 `Span` |
| 远程配置/API 异常 | → 渲染失败态并保留既有数据 |

---

## 三、目录结构

```
publish/
├── AppScope/                       应用级配置与图标资源
│   ├── app.json5                   bundleName / 版本号 / 图标
│   └── resources/base/
├── entry/
│   ├── build-profile.json5         模块构建配置（原生 CMake 路径、abiFilters）
│   ├── oh-package.json5             依赖声明
│   └── src/
│       ├── main/
│       │   ├── ets/
│       │   │   ├── entryability/    EntryAbility（键盘避让模式 = RESIZE）
│       │   │   ├── model/           ChatModels（@ObservedV2 数据模型）
│       │   │   ├── service/         网络 / 加密 / PoW / TTS / ASR / 存储
│       │   │   ├── components/      Markdown / LaTeX / 高亮 / 消息气泡等
│       │   │   └── pages/           ChatPage / LoginPage / Index / WebFallback
│       │   ├── cpp/                 原生 C PoW + NAPI 绑定
│       │   └── resources/rawfile/   mermaid.min.js + 离线 HTML
│       ├── test/  ohosTest/  mock/
├── spec/                           需求与设计文档（spec / plan / tasks）
├── tools/syscap-check-patch/       工具链误报补丁脚本
├── build-profile.json5              签名配置（**已清空密码**，见示例文件）
├── build-profile.json5.example      签名配置模板与说明
└── oh-package.json5  hvigorfile.ts  code-linter.json5
```

---

## 四、使用与构建指南

### 1. 环境要求

| 项 | 要求 |
| :--- | :--- |
| DevEco Studio | 5.0 及以上（支持 API 26 / HarmonyOS NEXT） |
| SDK | `targetSdkVersion 26.0.0`，`compatibleSdkVersion 6.1.1(24)` |
| 设备 | HarmonyOS NEXT 真机，或 API 24+ 模拟器 |
| 原生编译 | 需 C/C++ 工具链（CMake + NDK），用于 PoW 快路径 |
| 网络 | 需访问 `chat.deepseek.com` |

### 2. 导入工程

1. DevEco Studio → **File → Open**，选择本仓库根目录（含 `build-profile.json5` 的那一层）。
2. 等待 DevEco 完成 Sync（会自动安装 `oh_modules` 依赖）。
3. 若提示原生工程配置，按提示确认 CMake 与 NDK 路径。

### 3. 【必改】拿到这份代码后需要修改的地方

> 下表按**优先级**排列。前两项不做，工程无法正常出包/安装。

| # | 文件 | 字段 / 位置 | 当前值 | 需要改成 | 为什么 |
| :--: | :--- | :--- | :--- | :--- | :--- |
| 1 | `AppScope/app.json5` | `bundleName` | `com.example.mydeepseek` | 你自己的反域名，如 `com.yourname.mydeepseek` | bundleName 绑定 AGC 应用与设备标识，用通用值可能与他人冲突；改名后需重新申请证书 |
| 2 | `build-profile.json5` | `signingConfigs[].material` | 路径为相对路径、**密码为空** | 在 DevEco 中配置（见下方步骤 A） | 空密码无法签名；仓库内不留真实口令 |
| 3 | `AppScope/resources/base/element/string.json` | `app_name` | `MyDeepSeek` | 你想要的应用显示名 | 仅影响桌面名称 |
| 4 | `entry/src/main/ets/service/DeepSeekWebClient.ets` | `BASE_URL` / `X_CLIENT_VERSION` | `https://chat.deepseek.com` / `2.7.0` | 若服务端协议升级则同步 | `x-client-version` 必须与 Web 端一致，否则可能被拒 |
| 5 | `entry/src/main/ets/service/DeepSeekLoginClient.ets` | `X_CLIENT_VERSION` | `2.7.1` | 同上 | 同上 |
| 6 | `entry/src/main/ets/service/RequestCipher.ets` | `RSA_PUBLIC_KEY_SPKI_B64` | DeepSeek 生产公钥 | **通常无需修改** | 这是**公钥**（非私钥），服务端解密必需；仅当改用其他服务端时才需替换 |
| 7 | `entry/src/main/ets/service/DeepSeekWebClient.ets` | `USER_AGENT` | 桌面 Chrome UA | 保持或按需调整 | 部分风控会校验 UA 一致性 |
| 8 | `entry/src/main/ets/service/DeepSeekTtsService.ets` | TTS WebSocket 地址 | `wss://chat.deepseek.com/api/v0/chat/tts/` | 若接口变更则同步 | 服务端语音合成端点 |

### 4. 配置签名（必做）

**方式 A — DevEco 自动生成（推荐）**

1. 菜单 **File → Project Structure → Signing Configs**
2. 勾选 **Automatically generate signature**
3. 登录华为开发者账号（需已开通 AppGallery Connect 并创建应用）
4. DevEco 会自动创建证书并把真实值写回 `build-profile.json5`

**方式 B — 使用已有证书**

1. 从 AppGallery Connect 申请 `.p12` / `.cer` / `.p7b`
2. 放入 `AppScope/material/`（该目录已被 `.gitignore` 忽略）
3. 按 `build-profile.json5.example` 中的字段说明填写 `build-profile.json5`

> ⚠️ **DevEco 写入的签名密码是可逆密文**。拿到 `build-profile.json5` 就能解密出明文口令。
> **切勿把配置好的 `build-profile.json5` 提交到公开仓库**；如需入库，请把该文件加入 `.gitignore`（本仓库已预留注释掉的规则）。

### 5. 编译与运行

**DevEco Studio**

1. 顶部工具栏选择设备（真机或模拟器）
2. 点击 **Run**（`Shift+F10`）

**命令行（hvigor）**

```bash
# 编译
hvigorw assembleHap --mode module -p product=default -p module=entry@default

# 安装并启动（需已连接设备）
hdc install entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.example.mydeepseek
```

> 命令行签名需自行在 `build-profile.json5` 中填好有效配置；否则请改用 DevEco 的自动签名。

### 6. 系统权限

`entry/src/main/module.json5` 已声明：

| 权限 | 类型 | 用途 |
| :--- | :--- | :--- |
| `ohos.permission.INTERNET` | `system_grant` | 网络请求 |
| `ohos.permission.MICROPHONE` | `user_grant` | 语音输入（运行时弹窗申请） |

### 7. 常见问题

| 现象 | 原因与处理 |
| :--- | :--- |
| `install sign info inconsistent` | 设备上已有同 bundleName 的旧包但签名不同 → `hdc uninstall com.example.mydeepseek` |
| 登录返回业务错误但无明确提示 | `x-client-version` 与服务端不匹配 → 核对第 4 项必改表 |
| 首条消息首字延迟偏高 | PoW 预热未生效 → 确认 `ChatPage.aboutToAppear()` 中 `PowTicketManager.warm(token)` 已调用 |
| 原生模块加载失败 | CMake/NDK 未配置 → 检查 DevEco 的 Native 配置；PoW 会自动回退纯 ArkTS |
| 公式显示为源码 | 该 LaTeX 语法超出支持范围，属预期降级行为 |
| Mermaid 显示为代码块 | 图表语法错误，或流式过程中代码块尚未闭合 |

---

## 五、第三方组件与归属

| 组件 | 用途 | 许可证 |
| :--- | :--- | :--- |
| `entry/src/main/resources/rawfile/mermaid.min.js` | Mermaid 图表渲染（离线内置） | MIT |

其余全部为自研实现：Markdown 解析器、LaTeX 解析器、代码高亮器、加密模块、PoW 求解器、SSE 解析器。

---

## 六、⚠️ 发布与合规提示

### 关于本仓库

- 本仓库为**技术研究与学习目的**的演示项目，**非 DeepSeek 官方产品**，与 DeepSeek 官方无任何关联。
- 项目通过**逆向分析 Web 端公开 bundle** 复刻了私有 API 调用方式。使用者需自行评估使用行为的合规性，并遵守目标服务方的服务条款。
- DeepSeek 商标与相关权利归其所有者所有。

### 关于签名与密钥

- 本仓库**不包含任何私钥、证书或签名口令**。`build-profile.json5` 中的密码字段已清空。
- `RequestCipher.ets` 中的 RSA **公钥**是公开信息，服务端解密必需，不构成密钥泄露。

### 如果你 fork 了本仓库

- 请立刻配置**自己的**签名，不要沿用他人的证书。
- 请把配置好的 `build-profile.json5` 加入 `.gitignore`。

### ⚠️ 重要：不要直接发布上游开发仓库

如果你是在自己的开发环境里二次开发，**请只提交本仓库（`publish/`）这一份副本**，不要提交原始开发目录。原始开发目录的 git 历史中曾包含以下内容，虽然当前工作区已做清理，但**历史提交里仍然存在**：

- 签名证书的加密口令（可逆解密）
- 一次真实登录抓包中的账号 token、邮箱、手机号、设备 UUID

**因此请务必**：

1. **不要** `git push` 原始开发目录到任何远端；
2. 重新配置本仓库后，**轮换**你的 HarmonyOS 签名密钥（若曾对外暴露）；
3. 如果抓包中出现过的账号 token 仍然有效，**立即在服务端注销所有会话**使 token 失效。

---

## 七、许可证

本项目源码采用 **MIT License** 发布。

`entry/src/main/resources/rawfile/mermaid.min.js` 为第三方组件，遵循其原始 MIT 许可证。
