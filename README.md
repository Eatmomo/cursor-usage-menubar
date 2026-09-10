# cursor-usage-menubar

macOS 菜单栏显示 Cursor 订阅用量：计划池百分比、On-demand、Codex 风格用量热力图。

## 数据源

- 鉴权：本机 Cursor IDE `state.vscdb` 中的 `cursorAuth/accessToken`（需已登录 Cursor）
- `GetCurrentPeriodUsage` — 计费周期计划池
- `GetFilteredUsageEvents` — 按日 Token（热力图）
- `usage-summary` — On-demand 开关与额度

## 使用

```bash
./build.sh
./cursor-usage-menubar          # 前台跑
./install-launchagent.sh        # 开机自启 + KeepAlive
./uninstall-launchagent.sh      # 取消自启并退出
```

菜单栏默认显示 **Cursor Models** 百分比（与官网一致；`autoPercentUsed` 已是百分点，勿再 ×100）。

计划池两项：`Cursor Models` / `Other Models`。

### 用量热力图

对齐 Codex / CodexBar Token activity：

- 绿阶贡献图（周横排、周日为首）
- 点击标题折叠 / 展开
- 右侧切换 **本周** / **本月** 合计
- 悬停格子显示日期与当日 Token 总量
