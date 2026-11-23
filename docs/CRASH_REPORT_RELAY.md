# Marco Movie 崩溃日志自动上报 GitHub Issue 网关部署指南

客户端 APK 内**不内置任何 GitHub Token**（避免被反编译提取或触发 GitHub 自动吊销）。客户端默认采用混合模式：

1. **优先自动提交**：`POST https://marcotv.wlj9919.top/movie/api/crash-report`
2. **失败自动降级扫码**：若网关未部署、超时或离线，电视端自动拉起 5 分钟局域网扫码页（或离线预填 GitHub Issue 二维码），手机扫码即可一键提交 GitHub Issue / 复制 / 下载 `.txt`。

---

## 3 步部署 Cloudflare Worker 转发网关（免费）

1. **生成最小权限 GitHub Token（Fine-grained PAT）**：
   - 打开 GitHub `Settings → Developer settings → Personal access tokens → Fine-grained tokens`
   - Repository access 仅勾选 `Pilipala9919/MarcoMovie`
   - Permissions 仅授予 **`Issues: Read and write`**（其他全部保持 No access）
2. **创建 Cloudflare Worker**：
   - 将 [scripts/crash_relay_worker.js](../scripts/crash_relay_worker.js) 粘贴到 Cloudflare Worker。
   - 在 Worker `Settings → Variables and Secrets` 添加加密 Secret：`GITHUB_TOKEN = <上一步生成的 token>`。
3. **绑定路由**：
   - 在域名 `marcotv.wlj9919.top` 的 Workers Routes 中新增一条路由：
     `marcotv.wlj9919.top/movie/api/crash-report` → 指向该 Worker。

部署完成后，电视端点击「提交所选日志」即可自动在 `Pilipala9919/MarcoMovie` 创建带 `bug` / `crash-report` / `android-tv` 标签的 Issue，同指纹崩溃会自动归并评论到已有开启状态的 Issue，并在电视端回显 Issue 编号（如 `#128`）。
