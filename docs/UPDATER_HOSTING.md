# Updater 托管要求

当前尚未选择正式更新托管服务，Production endpoint 未配置。普通构建保持 `NOT_CONFIGURED`，不会使用 `example.invalid`、HTTP 或开发者本地地址冒充生产更新源。

`config/updater.example.json` 只说明需要的 `beta`、`windows-x86_64`、HTTPS endpoint 和公钥字段，不是 Production 配置，也不能原样发布。

## 待选择的方案

项目所有者需要在以下方案中选择一个：

1. GitHub Releases 与静态 `latest.json`
2. 自有 HTTPS 域名
3. Cloudflare R2、Amazon S3 或同类静态对象存储
4. 暂时只保留本地集成，不配置公网 endpoint

当前仓库没有 Git remote。本任务不创建仓库、remote、Release，也不上传安装包。

## 必须满足的托管契约

- 全部 Production URL 使用 HTTPS，证书链有效。
- Production 工具拒绝 localhost、IP literal、`.local` 及 IANA 示例/测试域名；本地集成测试不得把这些地址烘焙进发布构建。
- `latest.json` 使用 UTF-8 无 BOM，返回有效 JSON 和正确 Content-Type。
- 平台键为 `windows-x86_64`，渠道为 `beta`。
- 下载 URL 指向不可变的版本化安装包，不能指向 `七酱桌宠.exe` 可变别名。
- 同目录保留安装包、对应 `.sig`、`latest.json`、`SHA256SUMS.txt`、release manifest 和发布说明。
- `latest.json.signature` 等于 `.sig` 文件的实际文本内容。
- 更新版本必须是有效 SemVer，且严格高于已安装版本；安装包文件名必须包含精确版本，不发布降级元数据。
- `platforms.<target>.url` 的末段必须与实际版本化安装包文件名完全一致，配对签名文件必须命名为 `<安装包>.sig`；不得通过重定向把元数据绑定到可变别名。
- `platforms.<target>.size` 必须是最终安装包的实际字节数，并在上传前后复核。
- 不把密码、令牌、私钥路径、用户名、绝对本机路径或带敏感 query 的 URL 写入静态文件。

建议目录：

```text
release/updater/
  0.2.1-beta.1/
    七酱桌宠_0.2.1-beta.1_x64-setup.exe
    七酱桌宠_0.2.1-beta.1_x64-setup.exe.sig
    latest.json
    SHA256SUMS.txt
    release-manifest.json
    RELEASE_NOTES.md
```

上面的版本号只是目录格式示例，不代表该版本已构建或发布。

## 发布顺序

1. 在本地提供仓库外公钥，对最终安装包和 `.sig` 做真实密码学验签，并验证哈希、manifest 与 `latest.json` 的版本、URL 文件名和实际 size。
2. 先上传版本化安装包与 `.sig`，保持它们不可公开发现或不更新索引。
3. 从独立环境下载并核对长度、SHA-256 与签名。
4. 最后原子替换或上传 `latest.json`，让客户端发现更新。
5. 清理 CDN 缓存时只针对元数据；版本化二进制应使用不可变缓存策略。

如果安装包或签名上传失败，不发布新 `latest.json`。已发布元数据发生故障时可以让 endpoint 暂时返回上一个有效版本或停止自动发现，但不得把低版本伪装成高版本，也不得关闭签名验证。

## 权限与日志

托管访问令牌只存在于发布操作者的安全凭据存储或受控 CI secret 中，不进入仓库和本地 QA 输出。服务端访问日志由所选托管商处理；正式采用服务前应确认保留期、地区、访问控制和隐私说明是否需要更新。
