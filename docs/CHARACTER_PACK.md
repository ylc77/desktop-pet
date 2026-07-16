# 角色资源包制作说明

## 目录和注册

每个角色是 `public/characters/<角色ID>/` 下的独立目录。运行 `npm run validate:characters` 后，校验器扫描目录并生成运行时索引；业务代码不包含角色名、帧数或帧率。

必需文件：

```text
<角色ID>/
  manifest.json
  preview.png
  animations/
    idle/
      idle_0001.png
```

建议同时提供 `preview.png`、`icon.png`、`skins/`、`metadata/license.md` 和 `metadata/source.md`。

## manifest 字段

- `schemaVersion`：当前只支持 `1`。
- `id`：小写英文、数字、下划线或连字符，必须与目录名相同；内置回退包保留使用 `_placeholder`。
- `frameSize`：所有帧的固定画布尺寸。
- `anchor`：0 到 1 的归一化锚点，站立角色通常为 `{ "x": 0.5, "y": 1 }`。
- `defaultScale`：角色首次接入或首次启动时使用的默认显示比例。
- `hitbox`：可选的归一化矩形点击区域，字段为 `x`、`y`、`width`、`height`；透明留白较大的素材应配置该字段。
- `animations.<state>.path`：角色目录内的相对路径，禁止 `..` 和绝对路径。
- `fps`：1 到 60。
- `loop`：是否循环。
- `returnTo`：单次动作结束后的状态。
- `priority`、`interruptible`：抢占规则。
- `weight`、`minDelayMs`、`maxDelayMs`：随机环境动作。
- `minDurationMs`、`maxDurationMs`：可选；为循环环境动作设置一次出现的持续范围，达到时长后在自然循环点退出。
- `anticipation`、`recovery`：可选；分别引用资源包内的前摇和收尾动作。播放器按“前摇 → 主体 → 收尾 → returnTo”组合，旧包无需提供。
- `offsetX`、`offsetY`、`scale`：动作级对齐修正。
- `flipXAllowed`：能否随角色朝向水平翻转。
- `movement`：可选；为移动动作提供 `speed`、`acceleration`、`deceleration` 和 `edgePadding`，单位按逻辑像素/秒解释并在高 DPI 下换算。独立左右素材可用 `direction` 声明该动作朝向，并用 `reverseTo` 指向到达边缘后应切换的相反方向动作；未声明 `direction` 时继续沿用 `flipXAllowed` 的通用镜像方式。
- `visual`：可选角色级视觉配置；`dropShadow` 可关闭轮廓阴影，`groundShadow` 是跟随锚点、可禁用的独立接触阴影层。
- `interactions`：把 `click`、`doubleClick`、`hover`、`drag` 和 `land` 映射到资源包中的动作名，并可设置 `cooldownMs`。

动作名不是核心代码枚举。资源包可以直接声明 `walk_left`、`walk_right`、`hover`、`double_click` 或其他符合命名规则的动作。`idle` 是唯一必需动作；缺失的可选动作会回退到 `idle`，不会导致主程序退出。

推荐正式角色目录：

```text
characters/character-id/
  manifest.json
  preview.png
  animations/
    idle/
    walk_left/
    walk_right/
    sleep/
    hover/
    click/
    double_click/
    drag/
```

## PNG 规则

- RGBA 透明 PNG；同一动作画布尺寸必须一致。
- 所有帧使用透明背景，当前校验器要求 RGBA PNG（color type 6）。
- 固定四位序号：`walk_0001.png`、`walk_0002.png`。
- 编号必须从 1 连续递增。
- 播放顺序来自构建时生成并按文件名排序的 `frames.json`，不依赖操作系统目录顺序。
- 不要逐帧自动裁切；脚底或自然基准点要稳定。
- 每一帧不得随机缩放；同一动作不能明显跳位，不同动作之间应保持一致比例。
- 透明边缘不得有明显白边、黑边或损坏像素。

校验限制：单边画布最大 `4096px`、单帧最大 `16 MiB`、单个动作最多 `240` 帧、FPS 为 `1-60`。非法路径、超限图片、损坏 PNG、不连续编号、重复角色 ID、无效锚点或不兼容 `schemaVersion` 都会给出具体错误并阻止 release 构建。

运行时会再次解析 manifest、以受控并发加载和解码图片，并剔除损坏的可选帧。解码引用缓存按 `frameSize` 估算 RGBA 占用，默认保留预算约为 `64 MiB`，同时仍受帧数上限约束；大画布会自动降低缓存帧数和解码并发，不能因合法但巨大的画布把数百帧长期保留在内存。缓存上限不代表角色包可以忽略素材尺寸优化。某动作全部损坏时禁用该动作；`idle` 全部损坏时回退到 `_placeholder`。角色包错误不得使主程序崩溃。

## 正式外观确认

在生成任何正式角色设定图或动画帧之前，先与用户确认：角色类型、明确画风、身体比例、主色、服装或外壳、性格、标志特征、参考图授权、首批动作和目标显示尺寸。未确认时只能使用仓库内的几何占位素材。

角色包不得包含未经授权的商标、现有角色、真人肖像或其他版权资源。`metadata/source.md` 应记录来源，`metadata/license.md` 应记录发布、修改和商业使用许可。

未来正式素材还必须满足跨动作的比例、锚点、视角、光影、造型连续性以及动作衔接要求。完整制作标准见 [高保真角色素材制作规范](HIGH_FIDELITY_CHARACTER_ASSET_GUIDE.md)，交付时按 [角色视觉人工验收清单](CHARACTER_VISUAL_REVIEW_CHECKLIST.md) 逐项审核。

自动校验和动画技术测试通过不等于正式美术通过。当前白猫照片仅是应用图标，未经用户明确确认和授权，不得自动转换为角色或用于推导角色风格。当前正式路径仍是 `schemaVersion: 1` 的 PNG 序列帧；本轮增加的阶段、持续时间、移动和视觉元数据全部为可选字段，未提供这些字段的旧角色包继续沿用原有默认行为。未来再增加高保真元数据时，也必须同步落地代码、校验器、测试和文档，并保持旧角色包无需修改即可继续运行。
