# 七酱桌宠个性化 AI 伙伴系统实施方案

> 英文名称：Qijiang Desktop Pet Personalized AI Companion System
>
> 文档状态：**仅规划，尚未实施**
>
> 记录日期：2026-07-20
>
> 建议首个候选版本：`0.4.0-beta.1`（或后续尚未占用的功能版本）

## 1. 文档目的

本文用于保存七酱桌宠“个性化 AI 伙伴系统”的已确认产品与技术方案，供后续独立开发任务直接使用。

目前不得因为本文存在而认为功能已经启用。当前项目不应连接 DeepSeek、Supabase、腾讯云验证码或 SMTP，也不应写入任何生产密钥。

后续实施时仍需保持以下现有约束：

- 保持 Tauri 2、React、TypeScript 和 Rust 架构。
- 保持现有 identifier 不变。
- 保持角色包协议 `schemaVersion: 1` 不变。
- 不把固定角色名称、动作或素材硬编码进核心业务。
- 不影响桌宠主窗口、设置、外观中心、托盘、Updater 和角色加载功能。
- 不加入支付、广告、遥测、云端角色商城或模型工具执行。

## 2. 已确认的产品决策

| 项目 | 已确认方案 |
| --- | --- |
| 服务架构 | Supabase 云端账号、Postgres、RLS 和 Edge Functions 代理 |
| AI 模型 | `deepseek-v4-flash` |
| 模型模式 | 显式关闭默认思考模式 |
| 账号方式 | 邮箱和密码，必须验证邮箱 |
| 注册范围 | 开放注册 |
| 年龄范围 | 仅限 18 岁以上 |
| 注册防护 | 腾讯云天御验证码 2.0 |
| 验证码回退 | Tauri WebView2 探针失败时关闭开放注册并回退邮箱白名单 |
| 邮件服务 | 用户自有 SMTP |
| 人格范围 | 每个用户、每个角色分别保存独立人格 |
| 回复方式 | 流式回复，完成后进行第二次结构化分析 |
| 长期记忆 | 模型只提出候选，用户确认后才保存 |
| 原始聊天保留 | 云端 180 天 |
| 本机缓存 | 只缓存近期会话，且必须加密 |
| 个人每日额度 | 每账号每天 100 条回复 |
| 全局每日额度 | 每天 5000 条回复 |
| 数据权威来源 | 云端为权威，本机缓存只用于加速和离线只读 |

## 3. 功能范围

### 3.1 首版包含

- 注册、邮箱验证、登录、退出和会话恢复。
- 每个用户独立的数据空间。
- 每个角色独立的人格设置。
- 流式文字聊天。
- 多会话历史记录。
- 最近聊天上下文。
- 用户确认后保存的长期记忆。
- 记忆查看、编辑、删除和清空。
- AI 回复完成后发出受控情绪和动作提示。
- 本机近期会话加密缓存。
- 离线查看近期缓存。
- 个人数据导出。
- 删除账户和云端数据。
- 个人及全局额度控制。
- 错误分类、日志脱敏和诊断状态。

### 3.2 首版不包含

- 自动保存永久记忆。
- 自动亲密度或关系等级。
- 恋爱养成、纪念日或情侣功能。
- 向量数据库和语义检索。
- 语音输入、语音合成或声音包。
- 图片、文件或多模态聊天。
- AI 主动操作电脑。
- Tool Calls、Shell、文件系统、设置、Updater 或任意网络工具调用。
- 用户自定义 DeepSeek API 地址。
- 用户自带 API Key。
- 付费、会员、广告或账户余额系统。

## 4. 总体架构

```text
聊天窗口 / AI 伙伴设置
        │
        ▼
React companion 领域客户端
        │ Tauri 窄权限命令与 Channel
        ▼
Rust companion 模块
        │ HTTPS
        ▼
Supabase Auth / Postgres / Edge Functions
        │ 服务端专用密钥
        ├────────► DeepSeek V4 Flash
        └────────► 腾讯云验证码票据校验
```

必须遵守以下边界：

- React/WebView 不得直接请求 DeepSeek。
- DeepSeek API Key 只存在于 Supabase Edge Function Secrets。
- Supabase Secret Key、腾讯云 Secret 和 SMTP 密码不得进入桌面程序。
- 客户端只允许包含 Supabase Publishable Key、项目 URL、验证码公开标识等公开配置。
- 所有模型输出均视为不可信输入。

## 5. 桌面端体验设计

### 5.1 独立聊天窗口

新增 `chat` 根窗口，不把聊天界面塞入透明桌宠主窗口。

建议窗口规格：

- 推荐尺寸：`760 × 720`。
- 最小尺寸：`560 × 520`。
- 支持调整大小，不默认最大化。
- 200% DPI 时会话列表折叠为选择器。
- 关闭窗口时取消尚未完成的生成请求。

主要区域：

- 当前账户与角色信息。
- 会话列表和“新对话”。
- 消息列表。
- 流式回复状态。
- 多行输入框。
- 发送、停止和重试。
- 待确认记忆卡片。
- 离线、限额、未登录和服务错误状态。

键盘规则：

- `Enter` 发送。
- `Shift + Enter` 换行。
- `Esc` 关闭可关闭的浮层或对话框。
- 流式阶段不逐 Token 向屏幕阅读器播报，完成后再播报完整回复。

### 5.2 入口

桌宠右键菜单和系统托盘菜单统一新增：

```text
AI 伙伴
```

不占用现有单击、双击、悬停或拖动交互。

未登录时打开登录界面；已登录时打开当前角色的聊天界面。

### 5.3 设置页面

设置导航新增“AI 伙伴”，包含：

1. 个性
   - 用户希望被如何称呼。
   - 伙伴显示称呼。
   - 语气：温柔、平静、直接、活泼。
   - 回复长度：简短、标准、详细。
   - 自定义说明。
   - 明确边界和不希望涉及的内容。

2. 记忆
   - 待确认候选。
   - 已记住内容。
   - 编辑、删除和清空。
   - 重要记忆标记。

3. 账户与隐私
   - 当前登录状态。
   - 数据会发送给哪些服务。
   - 退出登录。
   - 删除本机缓存。
   - 导出个人数据。
   - 删除账户。

现有“恢复默认设置”不得删除账户、聊天、人格或记忆。

## 6. 前端和 Tauri 接口

AI 伙伴必须使用独立 `core/companion` 领域，不得把云端聊天数据加入现有 `AppSettings`、`settings.json`、`localStorage` 或 `DesktopControlSnapshot`。

建议公共类型：

```text
CompanionServiceStatus
CompanionUser
PersonaConfig
ConversationSummary
ChatMessage
MemoryCandidate
MemoryItem
CompanionStreamEvent
CompanionPresentationCue
```

流事件仅允许：

```text
started
delta
analysis
completed
failed
```

每个流事件必须包含：

- `requestId`
- `conversationId`
- `messageId`
- `characterId`

Tauri 窄权限命令分为：

- 服务状态。
- 注册、邮箱验证码确认、登录、退出和会话刷新。
- 会话创建、列表、读取和删除。
- 发送、取消和重试生成。
- 人格读取和保存。
- 记忆列出、接受、拒绝、编辑和删除。
- 导出数据、清除缓存和删除账户。

所有构建必须提供可反序列化的 companion 配置对象。未配置时：

- 显示“AI 伙伴服务尚未配置”。
- 不发起网络请求。
- 不影响主窗口和托盘启动。
- 不允许使用 `null` 表示禁用。

## 7. 注册、登录与验证码

### 7.1 Supabase 项目

- 新建七酱桌宠专用 Supabase 项目。
- 区域选择新加坡 `ap-southeast-1`。
- 只开启邮箱密码登录。
- 关闭匿名、手机、OAuth 和无密码注册。
- 开启邮箱确认。
- 使用自有 SMTP。

### 7.2 腾讯云验证码流程

1. Rust 客户端向注册初始化 Edge Function 请求短期验证码初始化数据。
2. 服务端生成短期 `aidEncrypted`。
3. Tauri WebView2 动态加载腾讯验证码脚本。
4. 用户完成挑战，客户端取得票据。
5. 客户端把票据和邮箱发送给注册网关 Edge Function。
6. Edge Function 调用腾讯云票据校验 API。
7. 校验成功后签发与邮箱绑定、五分钟有效、仅可使用一次的注册凭证。
8. 客户端调用 Supabase 邮箱密码注册，并在注册元数据中携带凭证。
9. `Before User Created` Hook 原子校验并消费凭证。
10. 凭证无效、过期、已使用或邮箱不匹配时拒绝注册。

不得只相信客户端返回的“验证成功”。

### 7.3 WebView2 探针和回退

正式实现注册前，先验证：

- 开发版和 Release 版均可动态加载验证码。
- Tauri 协议环境能够正常打开、完成和关闭挑战。
- 票据可以通过服务端复核。
- 100% 至 200% DPI 不裁切。
- CSP 只开放必要腾讯云域名。

如果探针失败：

- 自动关闭开放注册。
- 不允许跳过验证码继续注册。
- 回退到管理员邮箱白名单。
- 登录、已有账户和聊天功能继续可用。

### 7.4 邮箱确认

确认邮件使用一次性验证码，用户直接在七酱桌宠中输入，不依赖浏览器回跳或应用深链接。

注册时必须由用户主动勾选：

- 已满 18 岁。
- 同意 AI 数据与隐私说明。
- 知道聊天内容会发送给 Supabase 和 DeepSeek。

## 8. 云端数据模型

至少建立以下表：

| 表 | 用途 |
| --- | --- |
| `profiles` | 用户公开配置，不重复保存密码 |
| `consents` | 隐私政策版本和同意时间 |
| `character_personas` | 每用户、每角色的人格 |
| `conversations` | 会话元数据 |
| `messages` | 用户和助手消息 |
| `memory_candidates` | 待用户确认的记忆候选 |
| `memories` | 已确认长期记忆 |
| `signup_grants` | 一次性注册凭证 |
| `usage_daily` | 每日个人和全局额度 |
| `request_ledger` | 请求幂等、计费和状态 |

所有用户表启用 RLS：

```text
auth.uid() = user_id
```

Edge Function 必须从已验证 JWT 获取用户 ID，忽略客户端声称的权威用户 ID。

人格、会话和记忆使用 `(user_id, character_id)` 隔离。角色暂时被删除时保留数据，重新安装相同角色 ID 后恢复。

## 9. DeepSeek 调用流程

一次用户发送对应一个客户端请求，但服务端最多进行两次 DeepSeek 调用。

### 9.1 第一次调用：流式回复

- 模型：`deepseek-v4-flash`。
- 显式关闭思考模式。
- 以流式文本返回自然语言回复。
- 不启用 Tool Calls。
- 不允许自定义 Base URL。

限制：

- 用户单条输入最多 2000 个字符。
- 上下文最多 24 条完整消息。
- 序列化上下文最多 32000 个字符，超出时从最旧消息开始移除。
- 回复最多 800 tokens。
- 最近记忆最多 16 条，总计不超过 3000 字符。

### 9.2 第二次调用：结构化分析

流式回复完成后，第二次调用只分析当前用户消息和完整助手回复，返回严格 JSON：

```text
emotion
animationCue
memoryCandidates
```

要求：

- 最多生成 3 条记忆候选。
- 输出最多 300 tokens。
- 空内容、无效 JSON 或超时只导致“分析不可用”。
- 分析失败不得把已完成的聊天回复标记为失败。
- 分析结果不能直接写入永久记忆或执行系统操作。

### 9.3 请求状态和幂等

- 客户端为每次发送生成唯一 `requestId`。
- 服务端以 `requestId` 防止重复生成和重复计费。
- 用户消息先以待处理状态记录。
- 流式部分内容只存在于临时 UI。
- 只有 `completed` 的助手消息才能进入后续上下文。
- 取消或失败的部分回复不得进入长期记忆。
- 客户端断线后可以根据 `requestId` 查询最终状态。

## 10. 人格与长期记忆

### 10.1 人格配置

每个 `(user_id, character_id)` 拥有独立人格：

- 用户称呼：最多 40 字符。
- 伙伴称呼：最多 40 字符。
- 语气枚举：温柔、平静、直接、活泼。
- 回复长度枚举：简短、标准、详细。
- 自定义说明：最多 1000 字符。
- 边界说明：最多 1000 字符。
- 修订号和更新时间。

首版不保存关系分数。

### 10.2 记忆规则

候选类型：

- 偏好。
- 事实。
- 事件。
- 边界。

每条候选包含来源消息、内容、置信度、敏感性和过期时间。

规则：

- 模型只能提出候选。
- 所有候选都必须由用户确认。
- 用户可以编辑后保存。
- 拒绝后立即删除正文。
- 未处理候选 7 天后过期。
- 每角色最多 100 条有效记忆。
- 重要记忆优先进入模型上下文。
- 已确认记忆保留至用户删除或账户删除。

## 11. 回复驱动桌宠动作

模型不得返回任意动画名，只能返回以下语义提示：

```text
none
positive
comfort
curious
surprised
thinking
sleepy
```

客户端通过角色包现有交互配置映射：

- `positive`、`surprised`：优先双击动作，其次点击动作。
- `comfort`、`curious`、`thinking`：优先悬停动作，其次点击动作。
- `sleepy`：仅当实际存在 `sleep` 动画时使用。
- 没有匹配状态时不触发。

动作提示必须包含：

- `responseId`
- `characterId`
- 情绪提示
- 动作提示
- `expiresAt`

执行前再次检查：

- 当前角色未切换。
- 动画状态真实存在。
- 提示未过期且未重复。
- 动画未暂停。
- 桌宠窗口可见。

状态转换不得使用强制模式，不能打断拖动、落地或不可中断动作。

角色包缺少相关动作时聊天仍应正常工作，不修改角色包协议。

## 12. 配额和费用熔断

日界线统一使用 UTC，界面显示换算后的本地重置时间。

- 每账号每天 100 条回复。
- 全局每天 5000 条回复。
- 每账号同一时刻最多一个生成请求。
- 每账号每分钟最多接受 5 次生成请求。

计数规则：

- 验证、登录或额度检查失败不计数。
- 请求接受时原子预留一条额度。
- 尚未开始调用模型就发生网络错误时释放预留。
- 已开始流式输出后取消仍计一条。
- 第二次结构化分析不单独计用户条数。
- 达到全局上限后禁止新生成，但历史、人格和记忆仍可访问。

## 13. 本机缓存和凭据

### 13.1 会话凭据

- Access Token 只驻留内存。
- Refresh Token 保存到 Windows Credential Manager。
- 退出登录时撤销会话并清除内存令牌。
- 删除账户时删除所有本机凭据。

### 13.2 SQLite 缓存

- 独立 companion SQLite 数据库。
- 只保存最近 30 天。
- 最多 20 个会话和 1000 条消息。
- 超出时按最旧数据清理。
- 离线只读，不建立离线发送队列。

消息正文使用 AES-256-GCM 加密：

- 每行独立随机 nonce。
- 随机设备密钥保存在 Credential Manager。
- 数据库中不得出现聊天明文。
- 密钥丢失时删除不可解密缓存并从云端重新同步。
- 不因本机缓存损坏删除云端数据。

## 14. 安全与隐私

不得记录或导出：

- DeepSeek API Key。
- Supabase Secret Key。
- 腾讯云 Secret。
- SMTP 密码。
- JWT 或 Authorization Header。
- 邮箱原文。
- 聊天正文。
- 人格正文。
- 长期记忆正文。
- DeepSeek 请求或响应正文。
- 上游服务原始错误正文。

诊断信息只允许包含：

- AI 服务是否启用。
- 当前模型名。
- 是否已登录。
- 最近错误类别。
- 错误计数。
- 脱敏 request ID。

隐私说明必须明确：

- 哪些内容发送给 Supabase、DeepSeek 和腾讯验证码。
- 数据保留时间。
- 本机缓存方式。
- 不会自动上传诊断包。
- 如何导出数据。
- 如何删除聊天、记忆和账户。

正式公开运营前，需要独立进行中国地区 APP 备案、个人信息保护和跨境数据处理合规核查。验证码供应商本身不能替代该核查。

## 15. 数据保留与删除

- 云端聊天记录：180 天后自动清理。
- 待确认候选：7 天。
- 被拒绝候选：立即删除正文。
- 已确认记忆：用户删除或账户删除前保留。
- 人格配置：用户删除或账户删除前保留。
- 本机缓存：30 天并受数量上限约束。

账户删除要求：

1. 重新验证当前身份。
2. 明确输入删除确认。
3. 撤销活动会话。
4. 删除 Auth 用户。
5. 级联删除用户云端数据。
6. 清除本机缓存和 Credential Manager 凭据。
7. 无论成功或失败都显示准确状态，不伪造完成结果。

## 16. 错误分类

客户端只展示受控错误类别：

```text
unconfigured
signedOut
emailUnverified
captchaUnavailable
captchaRejected
offline
timeout
unauthorized
quotaExceeded
globalQuotaExceeded
rateLimited
insufficientBalance
serviceUnavailable
invalidResponse
canceled
storageFailure
```

错误提示必须说明：

1. 发生了什么。
2. 用户可以做什么。
3. 必要时如何打开脱敏诊断信息。

## 17. 测试要求

### 17.1 自动测试

- 未配置 AI 服务时应用正常启动且不发起网络请求。
- Companion 配置缺失、非法或为 `null` 时构建或验证失败。
- 腾讯验证码成功、取消、超时、加载失败和票据伪造。
- 注册凭证有效、过期、重放、邮箱不匹配和并发消费。
- 直接绕过注册网关时被 Hook 拒绝。
- 两个用户之间的 RLS 隔离。
- 同一用户不同角色的人格、会话和记忆隔离。
- 流事件顺序、重复、乱序、迟到和断线恢复。
- 发送、停止、重试和关闭窗口取消。
- 401、402、429、500、503、断网和超时。
- 空 JSON、非法 JSON 和第二次分析失败。
- 个人和全局额度的并发竞争与 UTC 重置。
- 未确认记忆不得进入模型上下文。
- 动作不存在、角色切换、过期、暂停和高优先级状态。
- SQLite 中无法搜索到聊天明文。
- 日志、诊断、Git 和 Release 不包含密钥或聊天正文。
- 导出和删除账户的成功、失败及重试。

### 17.2 Windows QA

- Windows 10 和 Windows 11。
- WebView2 正常和缺失场景。
- 100%、125%、150%、175%、200% 缩放。
- 中文路径、中文邮箱界面和中文聊天。
- 网络代理、断网、网络切换。
- 睡眠与唤醒。
- 登录状态恢复。
- 长时间流式聊天。
- 聊天窗口关闭后无遗留请求或未响应进程。
- AI 服务故障时桌宠、托盘、设置、外观中心和退出仍正常。
- 开发版、Release 版和安装版启动至少保持运行 10 秒。

### 17.3 项目现有验证

实施完成后仍需执行：

- TypeScript 类型检查。
- 前端测试。
- 角色包校验。
- 前端生产构建。
- Rust 格式检查。
- `cargo check`。
- Rust Release 测试。
- Release 构建。
- Safe QA 和真实 Windows 启动烟雾测试。

不得删除功能、跳过测试或隐藏错误以制造通过结果。

## 18. 推荐实施顺序

### P0：安全基础和技术探针

1. 把本需求确认为项目阶段变更并更新原则和隐私说明。
2. 建立独立 companion 模块和未配置安全状态。
3. 加强日志、诊断和秘密扫描。
4. 完成腾讯验证码 WebView2 探针。
5. 建立 Supabase 本地开发配置、迁移和 RLS 测试。

### P1：账号和聊天 MVP

1. 邮箱密码注册、验证码和邮箱确认。
2. 会话凭据和 Credential Manager。
3. 独立聊天窗口。
4. 流式 DeepSeek 代理。
5. 会话历史和本机加密缓存。
6. 个人及全局配额。

### P2：人格、记忆和动作

1. 每角色人格设置。
2. 第二次结构化分析。
3. 记忆候选确认流程。
4. 长期记忆管理和上下文注入。
5. 受控动作提示和状态机桥接。

### P3：隐私、部署和测试候选

1. 数据导出和账户删除。
2. 180 天清理任务。
3. 自有 SMTP 和生产 Secrets。
4. 完整安全、隐私、Windows 和长期运行 QA。
5. 构建 `0.3.0-beta.1` 候选包。
6. 通过所有 Gate 后再决定是否公开发布。

## 19. 后续实施所需外部输入

进入云端部署阶段前，需要用户在对应控制台自行准备：

- 新 Supabase 项目和所有者权限。
- DeepSeek 生产 API Key。
- 腾讯云验证码应用和服务端密钥。
- 自有 SMTP 主机、端口、账号和密码。
- 最终隐私政策版本和联系邮箱。

密码和密钥只能由用户在本机终端或对应云平台控制台交互输入，不得通过聊天、截图、项目文件或命令行明文传递。

## 20. 实施完成判定

只有同时满足以下条件，才能认定首版 AI 伙伴系统完成：

- 开放注册无法绕过验证码与注册 Hook。
- 两个用户之间无法访问对方任何数据。
- 每个角色的人格、会话和记忆相互独立。
- 流式聊天失败不会导致应用未响应或桌宠退出。
- 未确认记忆永远不会自动进入长期记忆库。
- 模型无法执行任意动画名或系统命令。
- 角色缺少动作时安全忽略提示。
- DeepSeek 和云平台密钥不在客户端、Git、日志或诊断中。
- 个人每日 100 条及全局每日 5000 条限制真实生效。
- 用户能够导出数据和删除账户。
- AI 服务不可用时现有桌宠功能继续正常工作。
- 全部自动测试、Release 构建和 Windows QA 通过。

## 21. 官方技术参考

- [DeepSeek Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing/)
- [DeepSeek Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode/)
- [DeepSeek JSON Output](https://api-docs.deepseek.com/guides/json_mode/)
- [DeepSeek API Error Codes](https://api-docs.deepseek.com/quick_start/error_codes)
- [Supabase Available Regions](https://supabase.com/docs/guides/platform/regions)
- [Supabase Edge Function Secrets](https://supabase.com/docs/guides/functions/secrets)
- [Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Supabase Before User Created Hook](https://supabase.com/docs/guides/auth/auth-hooks/before-user-created-hook)
- [Supabase Email Templates](https://supabase.com/docs/guides/auth/auth-email-templates)
- [Supabase Auth Rate Limits](https://supabase.com/docs/guides/auth/rate-limits)
- [腾讯云天御验证码快速入门](https://cloud.tencent.com/document/product/1110/36839/)
- [腾讯云验证码 Web 客户端接入](https://cloud.tencent.com/document/product/1110/36841)
