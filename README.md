# AI Quota MenuBar

macOS 菜单栏小工具,实时查看 **GLM(智谱)** 与 **DeepSeek** 的用量和余额。
原生 **Swift + AppKit** 实现,零第三方依赖。

菜单栏标题示例:

```
GLM🟢82%
```

> DeepSeek 余额显示在下拉菜单里,不占标题栏。

## 功能

**GLM**
- 5 小时滚动 token 配额(已用 / 剩余百分比,绿/黄/红指示)
- MCP / 时长配额
- 配额重置时间
- 当日 token 消耗、调用次数及各模型明细

**DeepSeek**
- 账户余额(CNY)
- > 日消耗需要平台账号登录才能查到,API key 拿不到,故不展示

**其它**
- 每 2 分钟自动刷新;23:00–08:00 视为休息时段跳过刷新
- 网络请求在**后台线程**执行,不会卡住菜单栏
- 请求失败时**保留上一次的有效数据**,不会清空显示
- 菜单里点 **Quit** 能真正退出(launchd 仅在崩溃时才自动重启)

## 目录结构

```
.
├── swift/                               # Swift 原生实现(主版本)
│   ├── Sources/GlmQuotaMenubar/         # main / AppDelegate / MenuBarController /
│   │                                    # ApiService / SecretsLoader / Models
│   ├── Makefile                         # make build | run | install | uninstall
│   ├── run.sh                           # 独立启动 / 安装入口
│   └── com.lixiang.glm-quota-menubar.plist
├── run.sh                               # 根入口(自动编译 swift/ 并安装)
├── com.lixiang.glm-quota-menubar.plist  # launchd 模板(指向 swift 二进制)
├── glm_quota_menubar.py                 # 旧 Python + rumps 版本(保留作参考)
└── README.md
```

## 依赖

- macOS
- Swift 命令行工具(Xcode Command Line Tools 自带 `swiftc`,无需安装 Xcode)
- 零第三方库,纯系统 AppKit

> 注:当前 macOS beta 上 Swift Package Manager 的 manifest 编译有问题,故直接用 `swiftc` 编译,不依赖 SPM。

## 配置 API Token

把 key 写入 `~/.config/zsh/ai-secrets.env`(路径写死在 `swift/Sources/GlmQuotaMenubar/SecretsLoader.swift`):

```sh
export ANTHROPIC_AUTH_TOKEN_GLM="你的智谱 api key"
export ANTHROPIC_AUTH_TOKEN_DEEPSEEK="你的 deepseek api key"
```

> 变量名沿用 `ANTHROPIC_AUTH_TOKEN_*` 前缀,仅为兼容既有配置,实际放的是对应平台的 key。

## 运行

仓库里**没有写死任何用户路径**。首次运行 `run.sh` 会自动用 `swiftc` 编译出二进制(`swift/.build/glm-quota-menubar`),之后直接复用。

### 手动启动

```sh
./run.sh
```

后台运行,日志在 `/tmp/glm-quota-menubar.log`。

### 开机自启(launchd)

```sh
./run.sh --install     # 安装(自动把本机绝对路径写入 plist)
./run.sh --uninstall   # 卸载
```

`--install` 会以模板方式把 `__BINARY__` 替换为本机实际路径——因为 launchd 不展开 `~` 和环境变量,plist 必须是绝对路径。

也可以单独在 `swift/` 里用 `make`:

```sh
cd swift
make build        # 仅编译
make run          # 手动启动
make install      # 安装 launchd 自启
make uninstall    # 卸载
```

## 已知限制

- DeepSeek 只能查余额,日消耗需登录网页端查看
- GLM 当日用量按本机时区的“今天”统计;若机器时区与北京时间不一致,边界可能有偏差
- 夜间 23:00–08:00 不刷新

## License

MIT
