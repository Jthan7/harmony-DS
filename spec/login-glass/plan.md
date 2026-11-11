# Implementation Plan: 登录页液态玻璃全原生重构（login-glass）

**Input**: Feature specification from `spec/login-glass/spec.md`

## Summary

将 WebView 内嵌官方登录页重构为全原生液态玻璃登录页（仅手机号+短信验证码），底层直连 DeepSeek 短信登录 API。核心逆向证据已全部取证完毕并持久化于 `spec/login-glass/evidence/`（端点、请求头、明文请求体字段、AES-CBC+RSA-OAEP 加密方案、生产公钥、PoW 样本双验证通过）。原 WebView 登录与嗅探工具保留为隐藏入口（长按呼出），作为回退路径。

## Technical Context

**Language/Version**: ArkTS (API 24+ 兼容 / targetSdk 26)
**Primary Dependencies**: @kit.NetworkKit(http)、@kit.CryptoArchitectureKit(cryptoFramework：AES-CBC、RSA-OAEP)、@kit.ArkTS(taskpool 复用现有 PoW)、@kit.ArkWeb(WebView 回退)、@kit.BasicServicesKit(Preferences)
**State Management**: 保留项目现状——登录页为 `@ComponentV2`（@Local），增量重构不迁移
**Storage**: TokenStore（token 持久化，复用）、Preferences（device-id 持久化，新增）
**Testing**: arkts_check + devecocli build + 模拟器 UI 验证（真机短信登录 + 视觉截图比对）
**Target Platform**: HarmonyOS 手机（模拟器 127.0.0.1:5555 API 26 验证）
**Project Type**: 既有 HarmonyOS 应用增量重构
**Performance Goals**: 登录 PoW（difficulty≈80000）求解在 taskpool 线程完成，UI 不阻塞；发码到可输入 <2s；登录按钮加载态到进入聊天 <5s（含 PoW 求解）
**Constraints**: 登录成功率不得低于现有 WebView 方案；失败时 WebView 回退必须可用；MessageItem/ChatPage 等既有模块零改动（仅 LoginPage 及新增文件）；`Login` 路由名与 `LoginBuilder` 导出保持不变
**Scale/Scope**: 3 个新服务文件 + 1 个新组件 + LoginPage 重写 + 测试文档更新

## Project Structure

### Documentation (this feature)

```text
spec/login-glass/
├── spec.md                       # 需求规范（已确认）
├── plan.md                       # 本文件
└── evidence/                     # ⚠️ 发布版本已移除（见下方说明）
    ├── api-analysis.md           # API 逆向取证分析（端点/字段/加密/公钥/PoW 样本）
    ├── sniff_sms.json            # 发码请求原始嗅探日志
    └── sniff_login.json          # 登录请求原始嗅探日志
```

> **⚠️ 关于 evidence/ 目录**
>
> 发布到公开仓库时，`evidence/` 下的三份文件已被移除。原因：这些是**真实运行期抓包记录**，
> 其中包含可用的账号登录 token、邮箱、手机号、设备 UUID 以及加密后的请求体密钥。
>
> 协议层面的关键信息**并未丢失**，已固化在以下位置：
>
> | 信息 | 现存位置 |
> | :--- | :--- |
> | 端点契约索引（4 个端点 + 请求头 + 加密方案） | `entry/src/main/ets/service/DeepSeekLoginClient.ets` 文件头注释 |
> | 生产 RSA 公钥（SPKI base64） | `entry/src/main/ets/service/RequestCipher.ets` 常量 `RSA_PUBLIC_KEY_SPKI_B64` |
> | PoW 挑战/求解契约 | `entry/src/main/ets/service/PowChallenge.ets`、`PowSolver.ets`、`DeepSeekHash.ets` |
> | 请求体字段（snake_case 明文契约） | `DeepSeekLoginClient.ets` 的 `SendSmsBody` / `LoginSmsBody` 接口 |
> | 端点清单与请求头表 | `spec/login-glass/spec.md` |

### Source Code (repository root)

```text
entry/src/main/ets/
├── service/
│   ├── RequestCipher.ets         # [新增] 请求体加密：AES-128-CBC(PKCS7) + RSA-2048-OAEP(SHA-256/MGF1-SHA-256)，内置生产公钥常量
│   ├── DeviceIdStore.ets         # [新增] 设备标识持久化：首启生成 UUID v4 存 Preferences，全局单例读取
│   └── DeepSeekLoginClient.ets   # [新增] 原生登录客户端：guest挑战→PoW求解→加密请求→token 提取；含 sendSmsCode/loginBySms/checkDevice
├── components/
│   └── WebLoginFallback.ets      # [新增] WebView 登录回退组件：迁移现有 LoginPage 的 WebView+嗅探+Cookie 轮询逻辑，onLoginSuccess 回调
└── pages/
    └── LoginPage.ets             # [重写] 全原生液态玻璃表单 + 隐藏调试入口（长按）→ WebLoginFallback/嗅探面板
```

**Structure Decision**: 遵循项目既有架构（pages/components/service 分层，无 MVVM 迁移）。登录业务逻辑收敛到 service 层三个新文件（加密/设备标识/登录客户端各一，职责单一且都可独立测试）；WebView 回退是独立 UI 组件；LoginPage 仅做表单组装与状态编排。文件数量（4 新 + 1 重写）为该复杂度下的最小充分拆分。

### Path Conventions

- 新增 service 文件：`entry/src/main/ets/service/`（与 DeepSeekWebClient 同层）
- 新增组件：`entry/src/main/ets/components/WebLoginFallback.ets`
- 重写页面：`entry/src/main/ets/pages/LoginPage.ets`
- 证据文件：`spec/login-glass/evidence/`（只读参考，不进构建；发布版本已移除，协议信息见 `DeepSeekLoginClient.ets` 头注释）
- 测试文档：`docs/TEST_REQUIREMENTS.md`（追加登录特性用例）

### Dependencies & Execution Order

```text
DeviceIdStore ─┐
RequestCipher ─┼─→ DeepSeekLoginClient ─┐
(PowSolver 现有) ┘                        ├─→ LoginPage(重写) ←─ WebLoginFallback
TokenStore(现有) ─────────────────────────┘
```

1. RequestCipher / DeviceIdStore 可并行先行（无相互依赖）
2. DeepSeekLoginClient 依赖前两者
3. WebLoginFallback（WebView 迁移）与 service 层并行
4. LoginPage 重写最后（依赖全部）
5. 测试文档更新收尾

### Parallelization Example

RequestCipher.ets 与 DeviceIdStore.ets 与 WebLoginFallback.ets 三者无依赖，可并行实现；DeepSeekLoginClient 必须等 RequestCipher/DeviceIdStore 就绪后开工。

## Complexity Tracking

无宪法违规。新增 service 文件均有独立复用/测试价值（RequestCipher 可被未来任何加密端点复用；DeviceIdStore 是设备指纹基础设施；登录客户端独立于 UI 可单测）。

## Research & Decisions

### RD-01 技术路线：全原生直连 SMS API（取证已完成，零猜测）
- **Decision**: 原生表单直连 `create_sms_verification_code` 与 `login_by_mobile_sms`；所有端点、字段、加密方案、公钥均来自真实嗅探与 bundle 静态分析（见 evidence/api-analysis.md），非猜测
- **Rationale**: 用户选择全原生路线；取证证据完整且 PoW 样本已双验证 100% 全等；登录可靠性有 WebView 回退兜底
- **Alternatives considered**: WebView+CSS 注入定制（视觉受限）；原生UI+隐藏WebView自动化（脆弱）

### RD-02 加密方案：复刻 Web 端 AES-CBC + RSA-OAEP 双层加密
- **Decision**: RequestCipher 用 cryptoFramework 实现：随机 16B AES-128 key + 16B IV → AES-CBC(PKCS7) 加密明文 JSON → `key||IV`(32B) → RSA-2048-OAEP(SHA-256, MGF1-SHA-256) 加密 → base64 作 `x-request-encryption-key` 头，密文 ArrayBuffer 作 body
- **Rationale**: 该两端点强制加密（bundle 拦截器对 eN 集合内 POST 强制启用）；生产公钥已提取（SPKI base64，见 evidence/api-analysis.md §4）
- **Alternatives considered**: 尝试明文探针（服务端按拦截器逻辑应拒绝；且即使可行也与 Web 端行为不一致，风控风险高）
- **⚠ 实现要点**: HarmonyOS cryptoFramework 的 RSA-OAEP MGF1 哈希必须与 WebCrypto 一致（MGF1-SHA-256）。若默认 MGF1 为 SHA-1 会导致服务端解密失败，须用 cipher 规格串显式指定（如 `RSA2048|PKCS1|OAEP|SHA256|MGF1_SHA256`），实现时用 devecocli docs 核实当前 API 的规格串格式

### RD-03 PoW 复用：现有 PowSolver/PowChallenge/DeepSeekHash 直接复用
- **Decision**: guest 挑战与聊天 PoW 同构（`DeepSeekHashV1("<salt>_<expire_at>_<n>") === challenge`，n < difficulty），复用现有 taskpool 求解器；响应头 `x-ds-guest-pow-response = base64({"salt":"<挑战salt>","answer":<n>})`
- **Rationale**: 已用 Node 移植版对两组真实捕获样本复算全等验证（evidence/api-analysis.md §3）
- **Alternatives considered**: 无需新写求解器

### RD-04 device-id：持久化 UUID v4
- **Decision**: DeviceIdStore 首次生成 UUID v4（util.generateRandomUUID），存 Preferences，全周期复用；作为 `x-device-id` 头与请求体 `device_id` 字段
- **Rationale**: Web 端 device-id 为 localStorage 持久化 UUID；固定 device-id 有利于服务端风控画像稳定
- **Alternatives considered**: 每次随机生成（风控画像不稳定，拒绝）

### RD-05 biz_code 语义与成功判定
- **Decision**: 登录成功判定以 `data.biz_data.user.token` 非空为准（biz_code=1 LOGIN_TO_EXISTING_ACCOUNT 同样返回 token，视为成功）；错误时展示服务端 `biz_msg`/`msg`，映射不到的展示兜底文案
- **Rationale**: 取证样本实证 biz_code=1 时 token 照常返回
- **Alternatives considered**: 按 biz_code 枚举白名单判定（枚举不可穷举，拒绝）

### RD-06 隐藏调试入口与回退交互
- **Decision**: 长按页面标题/Logo 区域 ≥1s 弹出隐藏菜单（"使用网页登录（备用）"、"嗅探模式"、"API 记录"）；WebLoginFallback 以全屏弹层方式打开，登录成功回调走与原生一致的 finishLogin；嗅探开关/日志面板逻辑随 WebView 迁移到 WebLoginFallback
- **Rationale**: 用户要求调试工具保留但隐藏；长按是低误触且可发现的开发者手势
- **Alternatives considered**: 多次点击版本号（Android 习惯，鸿蒙不常见）；彻底移除（用户已否决）

### RD-07 液态玻璃视觉规范（与既有设计语言统一）
- **Decision**:
  - 背景：`chat_bg` 底 + 两团低透明度品牌蓝径向渐变"氛围光斑"（左上/右下），营造玻璃折射背景
  - 表单卡片：居中 `backgroundEffect`(radius≈30, saturation 1.4-1.6, brightness 1.1-1.2, color rgba(255,255,255,0.5-0.6), adaptiveColor DEFAULT) + 1px rgba(255,255,255,0.9) 高光描边 + 柔和投影（rgba(38,38,38,0.10), offsetY 2-6）
  - 登录按钮：品牌蓝 `#4D6BFE` 胶囊大按钮，加载态内嵌小型 Loading；发送验证码按钮：玻璃次级按钮（发送中→"<n>s 后重发"禁用态）
  - 输入框：`input_bg` 圆角输入区，+86 区号前缀固定展示
  - 深色模式：全部颜色走 `$r('app.color.*')` 资源 + adaptiveColor 自动适配；错误态文案用 `danger` 色
  - 安全区：顶部状态栏避让 + 键盘避让处理，键盘弹出时表单上移不被遮挡
- **Rationale**: 与 ChatPage 已验收的液态玻璃加号按钮/气泡参数同族（backgroundEffect + 白色高光边框 + 柔影三件套）
- **Alternatives considered**: 纯扁平设计（用户明确要玻璃效果）

### RD-08 请求失败兜底链路
- **Decision**: 原生登录任何环节失败（网络/加密/PoW/服务端 biz 错误）→ 表单内联错误提示 + "遇到问题？使用网页登录" 引导链接（点击直达 WebLoginFallback）；WebView 回退路径不依赖任何原生新代码
- **Rationale**: 登录功能永不中断是 P1 约束（FR-003）
- **Alternatives considered**: 无

### RD-09 check_device 尽力而为
- **Decision**: 登录成功后异步调用 `auth_token/check_device`（明文 JSON + Bearer 新 token），失败静默忽略，不阻塞进入聊天
- **Rationale**: 复刻 Web 端行为保持设备登记一致性；非关键路径
- **Alternatives considered**: 不调用（行为差异可能影响风控画像，尽量复刻）

### Implementation Strategy

- 每个新文件完成后立即 `arkts_check` 单文件校验；全部就绪后整体构建
- 加密模块实现时先用 evidence 中的公钥+固定样本本地回环自验（固定 key/IV 加密后解密回环比对），再上真机
- MGF1 哈希规格串不确定时查 devecocli docs（RD-02 风险点）
- LoginPage 重写保持对外契约（路由/TokenStore/finishLogin）逐项核对后删除旧 WebView 代码

## Data Model

### 配置常量
| 常量 | 值（取证） | 归属 |
| :--- | :--- | :--- |
| LOGIN_BASE_URL | `https://chat.deepseek.com` | DeepSeekLoginClient |
| X_CLIENT_VERSION | `2.7.0` | DeepSeekLoginClient |
| X_CLIENT_LOCALE / body.locale | `zh_CN` | DeepSeekLoginClient |
| X_CLIENT_TIMEZONE_OFFSET | `28800` | DeepSeekLoginClient |
| BODY_REGION | `[unset]`（字面量） | DeepSeekLoginClient |
| BODY_OS | `web` | DeepSeekLoginClient |
| RSA_PUBLIC_KEY_SPKI_B64 | 生产公钥（见 evidence/api-analysis.md §4） | RequestCipher |

### 请求模型（接口定义于 DeepSeekLoginClient.ets）
| 模型 | 字段 |
| :--- | :--- |
| GuestChallengeInfo | algorithm, challenge, salt, signature, difficulty, expireAt, expireAfter, targetPath |
| SendSmsResult | bizCode, bizMsg, sendWindowSecs |
| LoginResult | bizCode, bizMsg, token, userId, displayName, avatarUrl |

### 响应原始映射（JSON.parse 一次性映射到严格模型）
- create_guest_challenge 响应 → `data.biz_data.guest_challenge`（字段 snake_case → 驼峰）
- create_sms_verification_code 响应 → `data.biz_data.send_window_secs`
- login_by_mobile_sms 响应 → `data.biz_code`、`data.biz_msg`、`data.biz_data.user.{token,id,id_profile.{name,picture}}`
- 所有 raw 接口字段全部可选（`?`），映射后进入严格模型，token 非空才算成功（RD-05）

### 加密结果模型（RequestCipher.ets）
| 模型 | 字段 |
| :--- | :--- |
| CipherRequest | body: Uint8Array（AES-CBC 密文）; encryptionKey: string（RSA 密文 base64） |

### 设备标识（DeviceIdStore.ets）
Preferences 单键存储：`auth_device_id: string`（UUID v4，首启生成后只读复用）

## Contracts & Interfaces

### 模块接口
| 模块 | 接口签名 |
| :--- | :--- |
| RequestCipher | `encryptRequest(plainJson: string): Promise<CipherRequest>` —— 内部完成 AES 密钥/IV 生成、两层加密、公钥导入缓存 |
| DeviceIdStore | `getOrCreate(): Promise<string>` —— 首次生成 UUID v4 并持久化，之后直接返回 |
| DeepSeekLoginClient | `sendSmsCode(mobile: string): Promise<SendSmsResult>`；`loginBySms(mobile: string, smsCode: string): Promise<LoginResult>`；`checkDevice(token: string): Promise<boolean>` —— 内部封装 guest挑战→PoW→加密→请求全链路，UI 只感知两步 |
| WebLoginFallback | 组件入参 `onLoginSuccess: () => void`；嗅探开关/日志面板内聚在组件内 |

### 页面契约（不变量）
- `Login` 路由名、`LoginBuilder` 导出、`NavDestination` 根节点、`onBackPressed`/`onReady(pathStack)` 行为全部保持
- 登录成功：`TokenStore.set(token)` → `pathStack.pop()`（与现行为一致，ChatPage 零改动）
- `MarkdownRenderer({rawText})` 等既有契约零触碰

### UI 组件状态（LoginPage @ComponentV2）
| 状态 | 类型 | 说明 |
| :--- | :--- | :--- |
| phone | @Local string | 手机号（11 位校验） |
| smsCode | @Local string | 验证码 |
| countdown | @Local number | 发码倒计时（默认取响应 send_window_secs，异常兜底 60） |
| sendingCode | @Local boolean | 发码请求中（防重复提交） |
| loggingIn | @Local boolean | 登录请求中（按钮加载态） |
| statusText / statusError | @Local string | 内联状态/错误提示 |
| showWebFallback | @Local boolean | WebView 回退弹层开关 |
| showDebugMenu | @Local boolean | 隐藏菜单开关（长按触发） |

### Notes

- 登录 PoW difficulty≈80000，taskpool 求解预计数百毫秒~数秒，按钮加载态 + "安全校验中" 文案覆盖
- 短信验证码位数不做硬编码强校验（服务端行为为准），仅做非空+数字校验，长度容错 4-8 位
- 发码成功响应 `send_window_secs` 驱动倒计时；若响应缺失按 60 兜底
- 三 captcha token（turnstile/shumei/hcaptcha）固定空串：大陆手机号直连登录流程不触发人机验证，与取证一致
