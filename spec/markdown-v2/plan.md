# Implementation Plan: markdown-v2（Markdown 完整渲染引擎升级）

**Input**: Feature specification from `spec/markdown-v2/spec.md`

## Summary

升级自研 Markdown 渲染引擎达到 90-95% 回答渲染正确率：解析器补全嵌套列表/任务列表/删除线/图片/脚注/引用合并/软换行/公式识别；行内渲染迁移至 MutableStyledString（支持 GestureStyle 可点击链接 + ImageAttachment 行内图片 + BaselineOffsetStyle 上下标）；新增原生 LaTeX 渲染器（块级公式原生布局、行内公式线性化渲染、复杂结构降级）；新增 10 语言自研语法高亮 tokenizer；新增 Mermaid WebView 渲染（mermaid.min.js v10 UMD 离线打包 rawfile，+~2.5MB）。流式性能通过块签名复用 + 解析缓存保障。

## Technical Context

**Language/Version**: ArkTS（API 26 目标，兼容 6.1.1(24)）  
**Primary Dependencies**: 零第三方运行时依赖；新增静态资源 mermaid.min.js v10 UMD（~2.5MB，rawfile）  
**State Management**: 既有项目 State Management V2（@ComponentV2/@Local/@Param/@Computed），本次增量沿用 V2，不迁移既有组件  
**Storage**: 无新增持久化；模块级 LRU 缓存（高亮 token、公式解析结果）  
**Testing**: arkts_check + devecocli build + 模拟器 UI 截图验证（uitest/hdc）  
**Target Platform**: HarmonyOS phone（API 26 模拟器 + 真机）  
**Project Type**: 既有 HarmonyOS 应用增量特性  
**Performance Goals**: 流式输出单帧解析+更新 <16ms；5000 字解析 <10ms；10KB 代码高亮 <10ms；mermaid 首渲染 <2s  
**Constraints**: HAP 增量 <4MB；纯 ArkTS 严格模式（禁 any/unknown/索引签名）；既有功能零回归  
**Scale/Scope**: 新增 5 个 ArkTS 文件 + 扩展 2 个既有文件 + 2 个 rawfile 资源

## Project Structure

### Documentation (this feature)

```text
spec/markdown-v2/
├── spec.md              # 需求规格（已确认）
├── plan.md              # 本文件
└── tasks.md             # Phase 3 生成
```

### Source Code (repository root)

```text
entry/src/main/
├── ets/
│   ├── components/
│   │   ├── MarkdownParser.ets        # [扩展] 解析器：嵌套列表/任务列表/删除线/图片/脚注/引用合并/软换行/公式识别/codeClosed
│   │   ├── MarkdownRenderer.ets      # [扩展] 渲染器：新块类型分发 + 行内渲染改用 StyledText
│   │   ├── MdInlineBuilder.ets       # [新增] MdSpan[] → MutableStyledString（样式/GestureStyle 点击/ImageAttachment 行内图/BaselineOffsetStyle 上下标/行内公式线性化）
│   │   ├── StyledText.ets            # [新增] 通用富文本组件：@Param spans → TextController 绑定，链接点击回调
│   │   ├── LatexParser.ets           # [新增] LaTeX 源 → LatexNode 树（纯函数，含降级检测与模块级缓存）
│   │   ├── LatexRenderer.ets         # [新增] 块级公式原生渲染：分数/根号/上下标/求和积分 Limits 结构（Row/Stack/Column 组合）
│   │   ├── CodeHighlighter.ets       # [新增] 10 语言 tokenizer（单遍扫描）+ One Dark 配色表 + token 缓存
│   │   └── MermaidView.ets           # [新增] WebView 封装：Code/Chart/Fallback 状态机，javaScriptProxy 传码与回传尺寸
│   ├── pages/
│   │   └── WebFallbackPage.ets       # [复用] 链接点击预览（带 url 参数跳转，不新建页面）
│   └── ...
└── resources/rawfile/
    ├── mermaid_view.html             # [新增] 图表渲染壳页（加载本地 mermaid.min.js，neutral 主题，深浅适配白底）
    └── mermaid.min.js                # [新增] mermaid v10 UMD 离线包（~2.5MB）
```

**Structure Decision**: 遵循既有项目架构（flat components/ 目录、pages/、service/），不引入 MVVM 迁移。新增文件均放入既有 `components/` 平铺目录，与 MarkdownParser/MarkdownRenderer 同级，保持项目现有约定。资源文件按规范置于 `entry/src/main/resources/rawfile/`（不放在 ets/ 下）。文件数：新增 7 个（6 ArkTS + 1 html）+ 1 个资源 js。

## Complexity Tracking

无违规项。遵循既有架构与目录约定，无重复目录、无额外分层。

## Research & Decisions

### RD-01 行内渲染路线：MutableStyledString（替代 Span 组件）

- **Decision**: 全部行内内容（段落/标题/表格单元格/列表/引用）统一改用 `MutableStyledString` + `TextController` 绑定 Text 组件构建，封装为通用 `StyledText` 组件。
- **Rationale**: 官方 FAQ（faqs-arkui-888/1337）确认 Text 内嵌 Span 组件的布局属性与触摸事件不生效——**可点击链接无法用 Span 实现**；faqs-arkui-901 确认 StyledString 支持 GestureStyle（onClick）、ImageAttachment（行内图片）；官方文档确认 BaselineOffsetStyle（上下标）、DecorationStyle（删除线）均可用。单一渲染路径避免 Span/StyledString 双轨维护。
- **Alternatives considered**: ① 混用 Span + 独立 Text 链接（破坏行内排版，否决）；② RichEditor 只读模式（交互组件误触输入风险，否决）。
- **关键注意**（faqs-arkui-901）：GestureStyle 回调对象生命周期需延长至组件成员变量，避免函数内临时对象被提前回收导致点击失效。

### RD-02 LaTeX 渲染：块级原生布局 + 行内线性化 + 分级降级

- **Decision**: 三级策略——
  1. **块级 `$$...$$`**：LatexParser 解析为 LatexNode 树，LatexRenderer 用原生组件全布局（分数 Column 上下结构、根号 Stack 覆盖线、上下标 baselineOffset、Limits 求和积分上下限）；
  2. **行内 `$...$`**：LatexParser 解析后**线性化**为 StyledString 样式串（上下标用 BaselineOffsetStyle + 缩小字号，希腊字母/运算符 Unicode 映射，分数降为 `a⁄b` 线性形式）；
  3. **降级**：未识别命令/结构（矩阵、aligned、自定义宏）→ 块级降级为等宽浅蓝底公式原文，行内降级为等宽原文。
- **Rationale**: 行内流式排版中堆叠结构（分数等）在 Text 流内无法用普通组件布局（CustomSpan 自绘成本高、流式场景稳定性差）；KaTeX 级排版需 WebView（用户已否决）。复杂结构在实际回答中绝大多数出现在块级展示模式。
- **Alternatives considered**: ① CustomSpan 自绘行内分数（复杂度高、流式重绘风险，否决）；② 全部公式只做线性化（块级观感差，否决）。

### RD-03 公式识别与货币 `$` 防误判

- **Decision**: 行内公式识别规则（parseInline 内）：开 `$` 后**紧邻非空白**，闭 `$` 前**紧邻非空白**，内容不含换行，且内容至少满足其一：含 LaTeX 特征字符（`^ _ \ { }`）、或为 ≤20 字符的 `[0-9a-zA-Z.+\-*/=<>()]+` 串。块级 `$$` 独立行起始、配对闭合。
- **Rationale**: "价格 $100 与 $200"——第一对 `$` 间内容含 CJK 且闭 `$` 前是空白 → 拒绝 ✓；"$x^2$" 含 `^` → 接受 ✓。规则简单可测。
- **Alternatives considered**: 全局正则预扫描（流式下边界状态复杂，否决）。

### RD-04 Mermaid 资源获取与加载

- **Decision**: 通过 `npm pack mermaid@10`（v10.9.x，最后一个提供 UMD dist 的稳定大版本）获取离线包，提取 `dist/mermaid.min.js` 放入 rawfile 根目录；`mermaid_view.html` 同目录相对引用 `mermaid.min.js`；Web 组件 `$rawfile('mermaid_view.html')` 加载（faqs-arkweb-39 确认 rawfile 本地加载路径）；图表代码经 `registerJavaScriptProxy` 注入（rawfile 不支持查询参数），渲染结果高度经 proxy 回调设置 Web 高度（上限封顶，超宽 Web 内横向滚动）；主题 `neutral`。
- **Rationale**: v11 dist 转向 ESM 单文件体积更大且 UMD 兼容性弱；npm CLI 获取避免手工拼装 URL；proxy 双向通信是 ArkWeb 标准模式。
- **Alternatives considered**: ① v11 ESM + importmap（体积更大，否决）；② 在线 CDN（违反离线约束，否决）。

### RD-05 语法高亮：规则表驱动单遍 tokenizer

- **Decision**: 每语言一张规则表（关键字集合/行注释符/块注释定界/字符串定界），单遍扫描产出 HighlightToken[]（Keyword/String/Comment/Number/Plain 五类），One Dark 风格配色（深底浅字，对齐官方观感）。html/css 各自专用规则（标签/属性/选择器）。模块级 LRU Map 缓存（key = lang + codeText 长度 + hash，上限 64 条）。渲染用 Span 组件着色（代码块内无手势需求，无需 StyledString）。
- **Rationale**: 规则表驱动使 10 语言共享一个扫描器；单遍扫描无回溯，满足 10KB<10ms；Span.fontColor 着色是零成本路径。
- **Alternatives considered**: ① 通用正则替代扫描器（灾难性回溯风险，否决）；② StyledString 高亮（无手势需求，过度设计，否决）。

### RD-06 流式性能：块签名复用 + 解析缓存 + 解析预算实测

- **Decision**: ① blockSignature 扩展新字段（depth/taskState/公式源/mermaid 状态/高亮 lang），未变化块不重建；② 高亮 token 与公式解析结果模块级 LRU 缓存，流式重解析时命中缓存；③ `$$`/``` 未闭合期间该块内容按普通文本渲染（解析器输出 codeClosed=false 原文块），闭合后一次性切换为公式/图表块（签名变化触发重建，单次）；④ 实现阶段对 5000 字样本实测解析耗时，超标（>10ms）再追加节流（@Computed 前置 16ms debounce），不预先过度设计。
- **Rationale**: 当前全量重解析对 5k 字符为毫秒级，缓存消除高亮/公式的重复计算；避免为未证实的瓶颈引入节流延迟（节流会推迟流式上屏，损害体验）。
- **Alternatives considered**: ① 增量解析器（只解析尾部变化区，实现复杂度极高，YAGNI，否决）；② 预置 16ms 节流（推迟首字上屏，先实测再定）。

### RD-07 链接预览复用 WebFallbackPage

- **Decision**: 链接点击复用既有 WebFallbackPage（已注册路由），携带 url 参数跳转，不新建页面。
- **Rationale**: 复用既有 ArkWeb 预览能力，零新增页面；WebFallbackPage 已具备 URL 加载能力。
- **Alternatives considered**: 新建轻量预览页（重复实现，否决）。

## Data Model

### 解析器模型（MarkdownParser.ets 扩展）

```text
MdBlockKind（枚举扩展）
  Paragraph | Heading | Code | ListItem | Quote | Divider | Table
  + BlockFormula   # $$...$$ 块级公式
  + FootnoteDef    # [^n]: 定义行

MdBlock（字段扩展）
  既有: kind, spans, level, codeLang, codeText, isOrdered, ordinal, tableRows
  + depth: number            # 列表嵌套层级（0 起）
  + taskState: number        # 0=非任务 1=未勾选 2=已勾选
  + codeClosed: boolean      # 代码块/公式块是否已闭合（流式判断）
  + quoteLevel: number       # 引用嵌套层级（1 起）
  + latexSource: string      # BlockFormula 原始源
  + footnoteId: number       # FootnoteDef 编号

MdSpan（字段扩展）
  既有: text, bold, italic, code, linkUrl
  + strike: boolean          # 删除线
  + imageUrl: string         # 非空则为行内图片（text 充当 alt）
  + footnoteRef: number      # >0 则为脚注角标
  + latexSource: string      # 非空则为行内公式（由 MdInlineBuilder 线性化）
```

### LaTeX 模型（LatexParser.ets）

```text
LatexNodeKind: Atom | Group | Sup | Sub | Frac | Sqrt | Limits | Styled(粗斜) | Degraded
LatexNode: { kind, text(Atom/Sty/Degraded 文本), style, children,
             base+sup(Sub/Sup), num+den(Frac), index+body(Sqrt),
             op+lower+upper(Limits) }
LatexResult: { root: LatexNode | null, degraded: boolean, degradedSource: string }
# 解析入口: parseLatex(src): LatexResult（模块级 LRU 缓存）
```

### 高亮模型（CodeHighlighter.ets）

```text
TokenKind: Keyword | String | Comment | Number | Plain
HighlightToken: { kind, text }
LangRule: { keywords: Set<string>, lineComments: string[],
            blockComment: [string, string] | null, stringDelims: string[] }
# 支持: js, ts, python, java, c, cpp, json, bash, sql, html, css
# 入口: highlight(code, lang): HighlightToken[]（LRU 缓存）
```

### Mermaid 状态（MermaidView.ets）

```text
MermaidState: Code(未闭合/默认) | Chart(渲染成功) | Fallback(语法错误/加载失败)
# props: { code: string, closed: boolean }
# javaScriptProxy: getDiagramCode() → string; onRendered(heightPx) → void; onError(msg) → void
```

## Contracts & Interfaces

### 模块公开接口

```text
parseMarkdown(src: string): MdBlock[]                       # 既有签名不变，输出模型扩展
parseLatex(src: string): LatexResult                        # 新增
linearizeLatexInline(src: string): StyledRun[]              # 新增（行内公式 → 样式串片段，供 MdInlineBuilder 拼接）
highlight(code: string, lang: string): HighlightToken[]     # 新增
buildInlineStyled(spans: MdSpan[], onLink: (url) => void): MutableStyledString  # 新增
```

### 组件契约

```text
StyledText: @ComponentV2 { @Param spans: MdSpan[], @Param fontSize, @Param lineHeight,
                           onLinkClick?: (url: string) => void }
LatexRenderer: @ComponentV2 { @Param source: string, @Param degraded: boolean }
MermaidView: @ComponentV2 { @Param code: string, @Param closed: boolean }
```

### 既有调用方影响

```text
MessageItem.ets → MarkdownRenderer({ rawText })   # 签名不变，零改动
WebFallbackPage 路由                               # 复用（url 参数），链接点击跳转入口
```

### 资源契约

```text
rawfile/mermaid.min.js   # mermaid v10 UMD，dist/mermaid.min.js 原文件
rawfile/mermaid_view.html # 相对引用 ./mermaid.min.js；mermaid.initialize({ startOnLoad: false, theme: 'neutral', securityLevel: 'strict' })
```
