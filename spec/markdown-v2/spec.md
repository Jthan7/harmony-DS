# Feature Specification: Markdown 完整渲染引擎升级（markdown-v2）

**Created**: 2026-11-05  
**Status**: Draft  
**Input**: User description: "我希望尽可能实现所有回答正确渲染，至少要达到90-95%，我可以接受稍微增加包体，但是要保持运行流畅高效"

## Overview

升级现有自研 Markdown 渲染引擎，使 DeepSeek 回答的渲染正确率达到 90-95%：补全标准 Markdown 语法（嵌套列表/任务列表/删除线/图片/可点击链接/脚注/引用增强）、新增原生 LaTeX 公式渲染器（零包体）、新增 Mermaid 图表 WebView 渲染（mermaid.min.js 离线打包 +~2.5MB）、新增主流语言代码语法高亮（自研 tokenizer）。硬约束：流式输出渲染无卡顿、总包体增量 <4MB、既有功能零回归。

## User Scenarios & Testing *(mandatory)*

### User Story 1 - 标准 Markdown 全语法正确渲染 (Priority: P1)

用户向 DeepSeek 提问获得包含嵌套列表、任务列表、删除线、图片、链接、脚注、嵌套引用、表格内格式、段内换行的回答，全部按语义正确渲染，不再出现 `~~`、`![](...)`、`[^1]`、`[ ]` 等原文符号外露。

**Why this priority**: 标准 Markdown 是 DeepSeek 回答的绝对主体（占比最高），此项直接决定 90-95% 目标的大头。

**Independent Test**: 发送一条覆盖全部新语法的测试消息，逐项截图核对渲染结果，无原文符号外露即通过。

**Acceptance Scenarios**:

1. **Given** 回答含 2/4 空格与 Tab 混合缩进的多级混合列表, **When** 渲染, **Then** 层级缩进正确、有序无序混排正确、深度不限
2. **Given** 回答含 `- [ ]` 与 `- [x]`, **When** 渲染, **Then** 显示为未勾选/已勾选复选框图标而非 `[ ]` 字面
3. **Given** 回答含 `~~删除~~`、`![图](url)`、`[链接](url)`、`[^1]` 脚注、`>>` 嵌套引用、表格内 `**粗体**`, **When** 渲染, **Then** 依次显示删除线样式、Image 组件内联图（失败显示占位）、可点击链接（应用内 WebView 打开）、上标角标+文末脚注列表、嵌套引用层级样式、表格单元格内行内格式生效
4. **Given** 回答段内含单个换行, **When** 渲染, **Then** 保留软换行（不被合并为空格）

---

### User Story 2 - LaTeX 数学公式原生渲染 (Priority: P1)

用户提问数学/物理/工程类问题，回答中的行内 `$...$` 与块级 `$$...$$` 公式渲染为排版后的公式（上下标、分数、根号、希腊字母、求和积分等），而非原文符号。

**Why this priority**: 数学类回答是当前与官方体验差距最大的场景，LaTeX 原文外露最影响观感。

**Independent Test**: 发送"推导二次方程求根公式"等数学问题，核对公式渲染为上标/分数/根号排版结构。

**Acceptance Scenarios**:

1. **Given** 行内 `$E=mc^2$` 与块级 `$$x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}$$`, **When** 渲染, **Then** 上标正确抬高缩小、分数上下结构、根号覆盖、`\pm` 显示 ±
2. **Given** 公式含 `\sum_{i=1}^{n}`、`\int_a^b`、`\alpha\beta\pi\infty\leq\neq\approx`, **When** 渲染, **Then** 上下限位置正确、符号正确映射
3. **Given** 公式含未识别结构（矩阵 `\begin{matrix}`、多行对齐 `\begin{aligned}`）, **When** 渲染, **Then** 整段降级为等宽公式原文样式，不空白不崩溃
4. **Given** 流式输出中 `$$` 尚未闭合, **When** 渲染, **Then** 以原文显示等待闭合，闭合后切换公式渲染
5. **Given** 文本含货币符号（如"价格 $100 与 $200"）, **When** 渲染, **Then** 不被误识别为公式（闭合配对校验）

---

### User Story 3 - 代码语法高亮 (Priority: P2)

回答中的代码块按语言着色（关键字/字符串/注释/数字），对齐官方代码块配色风格；未知语言保持现有无色渲染+复制按钮。

**Why this priority**: 代码类回答高频且现有渲染观感平淡，但缺失不会产生"错误"显示，优先级低于语法补全与公式。

**Independent Test**: 发送"写一个 TypeScript 防抖函数"等问题，核对代码块着色正确。

**Acceptance Scenarios**:

1. **Given** ```js/ts/python/java/c/cpp/json/bash/sql/html/css 代码块, **When** 渲染, **Then** 关键字/字符串/注释/数字四类分色着色，配色为深底浅色系
2. **Given** 未知语言代码块（如 ```rust）, **When** 渲染, **Then** 降级为现有无色渲染，复制按钮保留
3. **Given** 10KB 长代码块, **When** 高亮, **Then** tokenizer 单遍扫描完成 <10ms，无可感知卡顿

---

### User Story 4 - Mermaid 图表渲染 (Priority: P2)

回答中的 ```mermaid 代码块渲染为图表（流程图/时序图/饼图），使用离线打包的 mermaid.min.js 在 WebView 中渲染；语法错误或流式未闭合时降级为代码块显示。

**Why this priority**: DeepSeek 极少主动输出 mermaid，但用户确认需要支持（接受 +2.5MB 包体）。

**Independent Test**: 发送"画一个用户登录流程图（mermaid）"，核对渲染为流程图。

**Acceptance Scenarios**:

1. **Given** 闭合的 ```mermaid flowchart 代码块, **When** 渲染, **Then** WebView 加载本地 mermaid.min.js 渲染为图表，首渲染 <2s，浅色主题与白底协调
2. **Given** 流式输出中 mermaid 代码块未闭合, **When** 渲染, **Then** 先按普通代码块渲染，闭合且有效后切换图表
3. **Given** mermaid 语法错误, **When** 渲染, **Then** 降级显示代码块原文（带复制按钮），不白屏
4. **Given** 消息含 mermaid 图后被移除, **When** 消息销毁, **Then** WebView 实例同步销毁无泄漏
5. **Given** 超宽图表, **When** 渲染, **Then** 横向滚动，高度有上限不撑爆页面

---

### User Story 5 - 流式性能与零回归 (Priority: P1)

长回复（5000 字含公式/表格/代码混合）流式输出期间界面无卡顿；所有既有功能（玻璃气泡/TTS/抽屉/键盘避让/用户资料）零回归。

**Why this priority**: "运行流畅高效"是用户硬约束，性能不达标则前四个故事的价值不成立。

**Independent Test**: 发送长回复诱导问题（如"详细对比 10 种排序算法，含公式与代码"），全程观察滚动与渲染流畅度。

**Acceptance Scenarios**:

1. **Given** 5000 字混合内容流式输出, **When** 每 chunk 到达, **Then** 解析+diff 更新 <16ms，无可感知掉帧
2. **Given** 内容增量更新, **When** 重新解析, **Then** blockSignature key 机制保证未变化块节点复用不重建
3. **Given** 既有功能验证集（TC-01/02/05/06/07/10/12/14）, **When** 回归执行, **Then** 全部通过
4. **Given** 不含 Markdown 的旧消息, **When** 渲染, **Then** 与升级前显示一致

### Edge Cases

- 空消息 / 纯空格消息：不产生畸形块
- 代码块内含 Markdown 语法：不解析（隔离正确）
- 表格分隔行变体（`---`、`:---:`、`---:`）：全部识别
- 转义字符 `\*` `\~` `\$`：字面显示不触发格式
- 单个 `$` 出现且无配对：按普通文本处理
- mermaid.min.js 资源加载失败（理论不发生，本地资源）：降级代码块
- CJK 全角符号混排（中文引号包裹 markdown 语法）：按字面处理
- 超长单行（无换行 10KB）：Text 换行正常不溢出

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: 解析器 MUST 支持嵌套列表（2/4 空格与 Tab 缩进、多级、有序无序混合），渲染按层级缩进
- **FR-002**: 解析器 MUST 支持任务列表 `- [ ]`/`- [x]` 并渲染为复选框图标（两态）
- **FR-003**: 解析器 MUST 支持删除线 `~~...~~` 行内语法
- **FR-004**: 解析器 MUST 支持图片 `![alt](url)`，渲染为内联 Image（宽度自适应约束、失败占位）
- **FR-005**: 渲染器 MUST 使链接可点击并在应用内 WebView 页打开
- **FR-006**: 解析器 MUST 支持脚注引用 `[^n]`（上标）与文末脚注定义渲染
- **FR-007**: 渲染器 MUST 使表格单元格支持行内格式渲染
- **FR-008**: 解析器 MUST 合并相邻多行引用并支持 `>>` 嵌套层级
- **FR-009**: 解析器 MUST 保留段内软换行（去除现 join(' ') 合并行为）
- **FR-010**: 系统 MUST 提供原生 LaTeX 渲染器：行内/块级公式识别、上下标、分数、根号、希腊字母、常用运算符、`\text`、定界符；未识别结构降级等宽原文
- **FR-011**: 公式识别 MUST 做闭合配对校验（货币 `$` 不误判），流式未闭合按原文渲染
- **FR-012**: 系统 MUST 提供 10 语言（js/ts/python/java/c/cpp/json/bash/sql/html/css）自研语法高亮 tokenizer，四类 token 着色，未知语言降级无色
- **FR-013**: 系统 MUST 以离线打包的 mermaid.min.js（rawfile）+ WebView 渲染 mermaid 块；未闭合/语法错误降级代码块；实例随消息销毁
- **FR-014**: 渲染器 MUST 保持 blockSignature 节点复用机制并扩展至新块类型
- **FR-015**: 流式场景下解析 MUST 满足性能预算（长文本单次解析 <10ms，单帧解析+更新 <16ms）
- **FR-016**: 包体总增量 MUST <4MB
- **FR-017**: 所有新代码 MUST 通过 arkts_check 严格模式与 devecocli build

### Key Entities

- **MdBlock（扩展）**: 现有块模型新增字段：列表层级 depth、任务状态 taskState、脚注编号；新增块类型：公式块（行内/块级）、mermaid 块
- **MdSpan（扩展）**: 行内 span 新增删除线、图片、脚注引用属性
- **LatexNode**: 公式解析产物——原子（符号/文本）、上标、下标、分数（分子/分母）、根式（指数/被开方数）、分组；树状结构供渲染器映射原生组件
- **HighlightToken**: 高亮产物——{类型: keyword/string/comment/number/plain, 文本}；语言规则表驱动
- **MermaidBlockState**: mermaid 块状态机——streaming(未闭合)→code(闭合待渲染)→chart(渲染成功)→fallback(语法错误)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 构造的覆盖性测试消息集（≥20 条，覆盖全部语法类型）渲染正确率 ≥95%，其中标准 Markdown 语法 100%、高频 LaTeX 结构 ≥90%、mermaid 高频三类图表（flowchart/sequence/pie）100%
- **SC-002**: 5000 字混合内容流式输出全程无可感知卡顿，帧率无持续掉帧段
- **SC-003**: HAP 体积增量 <4MB（625KB 基线 → <4.7MB）
- **SC-004**: 既有功能回归测试（docs/TEST_REQUIREMENTS.md 关键用例）100% 通过
- **SC-005**: arkts_check 零错误、build 成功、Smoke PASS

## Assumptions

- DeepSeek 回答的 Markdown 输出符合 CommonMark 常规风格（与官方 web 渲染对照）
- mermaid.min.js 单文件 ESM 版本（约 2.5MB）可直接嵌入 rawfile 并在 WebView（API 26 ArkWeb）本地加载
- 现有 SSE 流式更新频率（服务端 chunk 到达即刷新）维持不变；若解析耗时超标采用节流优化而不改动 SSE 层
- 用户接受 WebView 图表首渲染约 1-2s 的本地加载延迟
- 暗色模式不在本期范围（现有配色仅浅色）

## Open Questions

- 链接点击后的应用内 WebView 预览页，是否需要复用现有 WebFallbackPage 还是新建轻量预览页？（倾向复用）
- 脚注点击是否需要锚点跳转（点击角标滚动到文末定义）？v1 可只做视觉渲染不做跳转
- 公式渲染的字号是否需要随正文字号设置联动？（当前无字号设置项，按固定字号实现）
