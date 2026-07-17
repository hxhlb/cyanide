<p align="center">
  <strong>简体中文</strong> | <a href="README_EN.md">English</a>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/hxhlb/cyanide/main/Cyanide/Assets.xcassets/AppIcon.appiconset/icon-ios-1024x1024.png" alt="Cyanide" width="160">
</p>

<h1 align="center">Cyanide</h1>

<p align="center">
  基于 DarkSword 内核读写原语的可侧载 iOS tweak 运行器。
</p>

<p align="center">
  <a href="https://github.com/hxhlb/cyanide/releases/latest"><img src="https://img.shields.io/github/v/release/hxhlb/cyanide?label=release" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="AGPL-3.0 license"></a>
</p>

Cyanide 将 DarkSword 内核利用链、Installer 风格界面与基于 RemoteCall 的
SpringBoard tweak 结合在一起。它不是传统越狱：多数运行时 tweak 由应用直接应用，
并仅在当前 SpringBoard 会话中保持生效；少数工具会有意写入持久化文件或偏好设置。

本仓库是原始 [`zeroxjf/cyanide`](https://github.com/zeroxjf/cyanide)（原名
`cyanide-ios`）项目的活跃维护分支 [`hxhlb/cyanide`](https://github.com/hxhlb/cyanide)。Patreon
集成已经移除，所有可安装的内置 tweak 均无需关联账户。

## 兼容性

当前内核漏洞适用范围：

- iOS/iPadOS 17.0 through 18.7.1
- iOS/iPadOS 26.0 through 26.0.1
- 不支持 A19 和 M5 设备

Cyanide 使用的内核漏洞 `CVE-2025-43510` 和 `CVE-2025-43520` 已在
iOS/iPadOS 18.7.2 与 26.1 中修复。SpringBoard 私有 API 也会随系统版本变化，
因此处于漏洞适用范围内并不代表每个 tweak 都能在对应系统和设备上正常工作。

## 安装

从 [`GitHub Releases`](https://github.com/hxhlb/cyanide/releases/latest)
下载最新的未签名 IPA，再使用你选择的侧载工具签名并安装。

也可以添加 Cyanide 的 AltStore 软件源：

<p align="center">
  <a href="https://celloserenity.github.io/altdirect/?url=https://raw.githubusercontent.com/hxhlb/cyanide/main/source.json">
    <img src="https://github.com/CelloSerenity/altdirect/blob/main/assets/png/AltSource_Blue.png?raw=true" alt="Add AltSource" width="200">
  </a>
  <a href="https://github.com/hxhlb/cyanide/releases/latest">
    <img src="https://github.com/CelloSerenity/altdirect/blob/main/assets/png/Download_Blue.png?raw=true" alt="Download IPA" width="200">
  </a>
</p>

## 主要功能

### Tweak 运行器

- Installer 风格的软件包浏览、队列、设置、日志与本地文件共享
- 软件包兼容性分组，可识别互斥 tweak 并阻止同时加入队列
- 内核读写初始化、应用沙盒逃逸与 SpringBoard RemoteCall
- 对支持的 tweak 执行运行时清理和会话恢复
- 使用 QuickLoader 与 RepoTweaks 运行本地或仓库托管的 JavaScript tweak

### 内置 Tweaks

| 分类 | Tweak | 功能 |
|---|---|---|
| 状态栏 | StatBar | 在状态栏附近显示电池温度、可用内存、CPU 和网络信息 |
| 状态栏 | NSBar | 在状态栏显示实时上传与下载速度 |
| 状态栏 | NiceBar Lite | 在状态栏槽位显示自定义文字、日期、天气和系统信息 |
| 主屏幕 | SBCustomizer（SpringBoard 自定义） | 调整 Dock 图标数量、主屏幕行列数并隐藏图标名称 |
| 主屏幕 | Home Layout Extras | 调整主屏幕与 Dock 的边距和图标缩放 |
| 主屏幕 | Gravity Lite | 为主屏幕图标加入重力、碰撞、弹性和设备倾斜效果 |
| 主屏幕 | Watch Layout | 使用可滚动的 Apple Watch 风格蜂窝布局浏览并启动应用 |
| 主屏幕 | Hide Home Bar | 隐藏底部 Home Bar；应用或恢复后需要 respring |
| 主题 | SnowBoard Lite | 导入并应用本地 SnowBoard/IconBundles 风格图标主题 |
| 主题 | LiveWP | 在主屏幕和锁屏播放本地视频壁纸 |
| 主题 | Metal Lock Light | 在锁屏壁纸上渲染可调颜色与反射强度的金属光照效果 |
| 主题 | Mood Wallpaper | 根据设备左右倾斜在多张静态壁纸之间切换 |
| SpringBoard | Axon Lite | 按应用分组通知中心中的通知请求 |
| SpringBoard | Dynamic Stage Lite | 在 SpringBoard 上显示两个可移动、缩放的应用窗口 |
| SpringBoard | MilkyWay Lite | 以可移动、缩放的悬浮窗口同时运行多个应用 |
| SpringBoard | iPad Dock | 在 iPhone 上启用带 App 资源库入口的 iPad 风格 Dock |
| SpringBoard | App Switcher Grid | 将系统多任务切换器改为网格样式 |
| SpringBoard | UIKit Debug Overlay | 双击状态栏打开 UIKit 调试层级工具 |
| SpringBoard | Upside Down | 允许 SpringBoard 和应用使用上下颠倒方向 |
| SpringBoard | FastLockX Lite | 提供 Face ID 重试和自动解锁控制 |
| SpringBoard | Disable App Library | 移除最后一页之后的 App 资源库页面 |
| SpringBoard | Disable Icon Fly-In | 跳过解锁或返回主屏幕时的图标飞入动画 |
| SpringBoard | Zero Wake Animation | 移除屏幕唤醒时的渐亮动画 |
| SpringBoard | Zero Backlight Fade | 移除锁定与解锁时的背光淡入淡出 |
| SpringBoard | Double-Tap to Lock | 双击主屏幕空白区域锁定设备 |
| SpringBoard | Drag Coefficient | 调整 SpringBoard 的全局 UIKit 动画速度 |
| 系统 | Powercuff | 通过模拟温控压力限制 CPU/GPU 性能；效果持续到重启 |

### JavaScript Tweaks

| 功能 | 说明 |
|---|---|
| QuickLoader | 导入并运行本地 `.js` tweak |
| RepoTweaks | 从 HTTPS 软件源下载、配置、运行和清理 JavaScript tweak |

### 工具与持久化修改

| 工具 | 功能 |
|---|---|
| MobileGestalt Editor | 编辑选定的设备身份、型号和能力配置 |
| IPA Decryptor（Beta） | 导出已安装应用并解密主可执行文件；内嵌 framework、extension 与 dylib 可能仍保持加密 |
| App Downgrade | 通过可配置的历史版本接口查询并安装 App Store 旧版本 |
| App Update Blocking | 为选定应用创建或移除 App Store 更新屏蔽标记 |
| Location Simulator | 使用静态坐标模拟 CoreLocation 位置 |
| Watch Pairing Override | 修改本机保存的 watchOS 配对兼容范围 |
| Call Recording Sound | 替换或恢复通话录音开始与停止提示音 |
| OTA Updates | 禁用或恢复系统 OTA 更新任务 |

### 开发中

| Tweak | 当前状态 |
|---|---|
| Signal Readouts | 数字蜂窝/Wi-Fi 信号显示，当前不可安装 |
| TypeBanner | iMessage 输入状态横幅，当前不可安装 |
| Notification Island | 将通知横幅映射到灵动岛，当前不可安装 |

部分软件包仍属实验功能、仅适配特定设备，或因尚未完成而保持禁用。表格描述的是
功能范围，不代表所有系统版本均已完整验证。每项功能应以
应用内的软件包说明与警告为准。近期用户可见改动请查看
[`RELEASE_NOTES.md`](RELEASE_NOTES.md)；系统资源与互斥关系请查看
[`docs/TWEAK_COMPATIBILITY.md`](docs/TWEAK_COMPATIBILITY.md)。

## 安全说明

Cyanide 会使用内核漏洞、私有 API 和运行时方法替换。尤其在未测试的系统版本上，
可能出现 SpringBoard 重启、界面冻结、功能部分生效或设备重启。

应用功能前请阅读对应软件包的警告。运行时 tweak 通常可通过 Cyanide 的 Clean Up
或 respring 恢复，但修改系统文件、MobileGestalt 值或偏好设置的工具可能在
respring 或重启后继续生效。请备份重要数据，不要在无法恢复的设备上测试。

## 构建

环境要求：

- macOS、兼容版本的 Xcode 与 iPhoneOS SDK
- `xcbeautify` 可选；缺失时构建脚本会回退到原始 `xcodebuild` 输出
- 仅 VPhone 打包流程需要 `ldid`

构建未签名的真机 IPA：

```sh
./scripts/build.sh
```

脚本会生成 `build/Cyanide-<version>.ipa`，并让 `build/Cyanide.ipa` 指向
最新构建。

构建模拟器版本：

```sh
SDK=iphonesimulator ./scripts/build.sh
```

## JavaScript Tweaks

QuickLoader 可以导入本地 `.js` 文件，RepoTweaks 可以从 HTTPS JSON 仓库加载
JavaScript 软件包。脚本能够调用功能强大的 RemoteCall helper，因此请只使用你信任的
脚本和仓库。

修改 SpringBoard 内存状态的脚本应提供同步的 `globalThis.cleanup` 函数：

```js
globalThis.cleanup = function () {
  r_msg2_main(view, "setHidden:", 0);
  clearInterval(timer);
};
```

Cyanide 会在受支持的脚本被禁用、移除或随会话清理停止时调用 `cleanup()`。该函数
只应恢复脚本自身修改的状态，并应尽快完成。它无法自动撤销持久化文件或系统修改。

## 参与贡献

欢迎提交错误报告和范围明确的 Pull Request：

- [报告问题](https://github.com/hxhlb/cyanide/issues/new)
- [提交 Pull Request](https://github.com/hxhlb/cyanide/pulls)

修改 SpringBoard 私有 API 路径时，请注明测试设备与系统版本。不同 iOS 版本之间的
行为差异很大，因此兼容分支应保持明确和有限。

## 致谢

- [`zeroxjf`](https://github.com/zeroxjf)：原始 Cyanide 项目及其
  Installer/Settings 集成
- [`opa334`](https://github.com/opa334):
  [`darksword-kexploit`](https://github.com/opa334/darksword-kexploit), ChOma,
  与 XPF
- [`wh1te4ever`](https://github.com/wh1te4ever):
  [`darksword-kexploit-fun`](https://github.com/wh1te4ever/darksword-kexploit-fun)
  及 RemoteCall 基础
- [`rooootdev`](https://github.com/rooootdev)：内核利用稳定性参考
- [`kolbicz`](https://github.com/kolbicz)：DarkSword tweak 与位置模拟参考
- [`d1y`](https://github.com/d1y)：多个 Cyanide 移植功能使用的 AGPL-3.0 实现
- [`rpetrich`](https://github.com/rpetrich)：Powercuff
- [`Julio Verne`](https://github.com/julioverne)：Gravity
- [`tomt000`](https://github.com/tomt000)：Dynamic Stage
- `Iggy05`：QuickLoader 与 RepoTweaks
- `neonmodder123`：Web Respring 方法

其他功能的专项致谢保留在源码和应用内软件包说明中。

## 许可证

Cyanide 使用 [GNU Affero General Public License v3.0](LICENSE) 许可证。
从其他项目改编的 AGPL 代码继续使用相同许可证。
