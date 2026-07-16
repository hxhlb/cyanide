# Cyanide Tweak 资源与互斥表

本文档记录 Cyanide 原生 tweak 实际修改的系统资源，以及需要阻止同时启用的组合。运行时唯一数据源是 `Cyanide/TweakCompatibility.m`；本文档用于审查和维护。

## 维护规则

新增原生 `PackageCatalog` 项目时必须同时完成以下工作：

1. 在 `cyanide_tweak_resource_registry()` 登记 package identifier、enabled key、名称和修改资源。
2. 如果它与现有 tweak 独占同一资源，将 enabled key 加入对应互斥组；同一功能可以加入多个互斥组，没有冲突则只登记资源。
3. 更新本文档。
4. Debug 构建遇到未登记的原生 package 会触发断言；Release 构建会禁止安装该 package，并显示缺少兼容性元数据。

RepoTweaks/QuickLoader 下载的 JavaScript 脚本会在运行时变化，无法仅凭静态 package identifier 得出资源范围。它们在总表中登记为动态资源容器，具体脚本仍需提供独立的资源声明和 `cleanup()`。映射到原生 backend 的 RepoTweaks package 使用 `repoNativeEnabledKey` 参与同一套互斥检查。

## 原生与内部功能

| 功能 | Package identifier | 修改的进程/对象/文件 | 互斥组 |
|---|---|---|---|
| StatBar | `com.darksword.statbar` | SpringBoard 状态栏区域的独立 `UIWindow`；温度、内存、网络刷新循环 | 状态栏 Overlay |
| NSBar | `com.darksword.nsbar` | SpringBoard 状态栏区域的独立 `UIWindow`；网速刷新循环 | 状态栏 Overlay |
| NiceBar Lite | `com.darksword.nicebarlite` | SpringBoard 状态栏区域的独立 `UIWindow`；天气及系统信息槽位 | 状态栏 Overlay |
| Signal Display | `com.darksword.rssidisplay` | `STUIStatusBarWifiSignalView`、`STUIStatusBarCellularSignalView` 的 dBm 显示 | 无确定硬冲突 |
| SpringBoard Customizer | `com.darksword.sbcustomizer` | `SBIconController` 的主屏幕/Dock 行列、标签和布局配置 | 主屏幕布局 |
| Powercuff | `com.darksword.powercuff` | `CPMSHelper` 电源与温控策略级别 | 无 |
| Axon Lite | `com.darksword.axonlite` | 通知列表过滤状态与 Axon Overlay | 无确定硬冲突 |
| TypeBanner | `com.darksword.typebanner` | 输入提示 Overlay；MobileSMS keepalive | 无确定硬冲突 |
| Notification Island | `com.darksword.notificationisland` | ActivityKit/Dynamic Island 通知展示 | 无确定硬冲突 |
| IPA Decryptor | `com.darksword.ipadecryptor` | 读取已安装 App/Mach-O；在 Documents 生成解密 IPA | 工具，不参与 Run 互斥 |
| Dynamic Stage Lite | `com.darksword.stagestrip` | SpringBoard hosted application scene 与悬浮场景窗口 | 悬浮 Scene |
| MilkyWay Lite | `com.darksword.mwlite` | SpringBoard hosted application scene、悬浮窗口和控制栏 | 悬浮 Scene |
| Location Simulator | `com.darksword.locationsim` | 选定进程中的 `CLSimulationManager`/`CLLocation` 状态 | 工具，不参与 Run 互斥 |
| SnowBoard Lite | `com.darksword.snowboardlite` | `SBIconView`/icon image provider 的主题图片状态 | 图标主题引擎 |
| LiveWP | `com.darksword.livewp` | 主屏幕和锁屏壁纸窗口中的 `AVPlayerLayer` | 壁纸 Layer |
| Metal Lock Light | `com.banana.metal-lock-light` | 锁屏壁纸窗口中的 `CAMetalLayer` 和 Metal renderer | 壁纸 Layer |
| Mood Wallpaper | `com.banana.mood-wallpaper` | 主屏幕和锁屏壁纸窗口中的 motion-driven `UIImageView` | 壁纸 Layer |
| Home Layout Extras | `com.darksword.layoutextras` | 主屏幕/Dock layout insets 和图标 transform/scale | 主屏幕布局 |
| Gravity Lite | `com.darksword.gravitylite` | UIKit Dynamics 接管主屏幕图标；可选接管 Dock 图标 | 主屏幕布局 |
| Watch Layout | `com.darksword.watchlayout` | 从已安装应用目录生成纵向滚动的蜂窝 Overlay，包含文件夹内应用与系统应用；不移动原图标、不写 icon model | 主屏幕布局 |
| App Downgrade | `com.darksword.appdowngrade` | App Store metadata 查询、历史版本 API 与 StoreKitUI 降级请求 | 工具，不参与 Run 互斥 |
| App Update Blocking | `com.darksword.appupdateblocking` | 通过 `installd` 创建或删除按应用更新屏蔽标记 | 工具，不参与 Run 互斥 |
| UIKit Debug Overlay | `com.darksword.debugoverlay` | `UIDebuggingInformationOverlay` 可用性；状态栏双击手势 | 无 |
| Enable Upside Down | `com.darksword.upsidedown` | Home、Cover Sheet 和 scene participant 的方向方法 | 无 |
| App Switcher Grid | `com.darksword.appswitchergrid` | `SBAppSwitcherSettings.switcherStyle`；可选 iPad switching behavior | 无 |
| iPad Dock | `com.darksword.floatingdock` | `SBFloatingDockController` scene participant、窗口和 App Library pod | App Library 能力 |
| QuickLoader | `com.darksword.quickloader` | 长驻 QuickJS runtime；具体系统资源由当前脚本决定 | 动态 |
| FastLockX Lite | `com.darksword.fastlockx-lite` | 锁屏生物识别、AOD、计时器、媒体、手电筒和低电量行为 | 无确定硬冲突 |
| Nano Registry | `com.darksword.nanoregistry` | Watch 配对兼容 registry 与 MobileAsset cache | 持久化工具 |
| Call Recording Sound | `com.darksword.callrecording-sound` | CallServices disclosure sound 文件与 Cyanide 备份 | 持久化工具 |
| Hide Home Bar | `com.darksword.hide-home-bar` | `MaterialKit.framework/Assets.car` 首页内存内容 | 独占安装队列，需 respring |
| OTA Updates | `com.darksword.ota-block` | launchd `disabled.plist`、OTA preferences、MobileGestalt OTA cache | 持久化工具 |
| Disable App Library | `com.darksword.disable-app-library` | `SBIconController` trailing/overlay App Library controller | App Library 能力 |
| Disable Icon Fly-In | `com.darksword.disable-icon-flyin` | `SBCoverSheetPresentationManager` 图标动画状态 | 无 |
| Zero Wake Animation | `com.darksword.zero-wake-animation` | `SBScreenWakeAnimationController` 唤醒时长和速度 | 无 |
| Zero Backlight Fade | `com.darksword.zero-backlight-fade` | SpringBoard wake settings 的 backlight fade duration | 无 |
| Double-Tap to Lock | `com.darksword.double-tap-to-lock` | 主屏幕/root window 双击手势；调用 SpringBoard 锁屏动作 | 无确定硬冲突 |
| Drag Coefficient | `com.darksword.drag-coefficient` | UIKitCore `_UIAnimationDragCoefficient` 行为 | 全局动画参数，无确定硬冲突 |
| Icon Theme Engine | `com.darksword.themer` | 内部主题后端；`SBIconView`/icon image provider | 图标主题引擎 |
| RepoTweaks | `com.darksword.repotweaks` | 下载并执行 JavaScript；具体系统资源由脚本决定 | 动态 |
| Kill All Apps | `com.darksword.killallapps` | `SBApplicationController` 运行中 App 的终止操作 | 一次性动作 |

## 硬互斥组

组内顺序也是旧设置异常时的确定性优先级。Cyanide 不会篡改偏好值；队列阻止新增冲突，Run 阶段只执行组内第一个已启用项并记录 `[COMPAT]` 日志。

| 组 | 优先级（高到低） | 原因 |
|---|---|---|
| 状态栏 Overlay | StatBar → NSBar → NiceBar Lite | 三者各自创建覆盖状态栏的窗口，同时运行会重叠并争用展示区域 |
| 主屏幕布局 | SpringBoard Customizer → Home Layout Extras → Gravity Lite → Watch Layout | 四者都会接管主屏幕布局、live icon geometry 或主屏幕图标 Overlay |
| 图标主题引擎 | Icon Theme Engine → SnowBoard Lite | 两者共用 icon image-provider/themer 后端，无法保持两个独立主题状态 |
| 悬浮 Scene | Dynamic Stage Lite → MilkyWay Lite | 两者都管理 SpringBoard hosted application scene 和悬浮窗口状态 |
| 壁纸 Layer | LiveWP → Metal Lock Light → Mood Wallpaper | 三者都在 SpringBoard 壁纸层插入并管理自有渲染层 |
| App Library 能力 | Disable App Library → iPad Dock | iPad Dock 的最右侧 pod 依赖 App Library；另一个功能会移除对应 controller |

## 条件重叠与待验证项

以下组合暂不做硬阻止。原因是冲突依赖子选项或系统版本，直接互斥会错误限制可用组合。

| 组合 | 当前判断 |
|---|---|
| Gravity Lite + iPad Dock | 仅当 Gravity Lite 的 Dock physics 开启时可能争用 Dock icon view；需按子选项验证 |
| Signal Display + 状态栏 Overlay | 修改对象不同，但窄屏设备可能发生视觉遮挡 |
| TypeBanner + Notification Island | 展示面不同；暂未发现共享 controller 所有权 |
| UIKit Debug Overlay + Double-Tap to Lock | 都使用双击，但目标 view 不同：状态栏与主屏幕/root window |
| App Switcher Grid + iPad Dock/Upside Down | 修改的方法不同；部分实现只借用其他类的 IMP，不代表共享状态 |
| QuickLoader/RepoTweaks + 任意原生 tweak | 取决于实际 JavaScript；必须由脚本资源声明和 `cleanup()` 决定 |

## 运行时策略

- 安装队列：检测已启用、待安装和待卸载状态。只有冲突项已停用或已排队卸载时，才允许安装另一项。
- 自动恢复队列：若旧设置同时启用了多个冲突项，只保留互斥组中优先级最高的待应用项。
- Run/Apply：再次执行相同优先级判定，防止手改 defaults 或旧版本遗留状态绕过队列。
- 用户偏好：互斥处理不自动把任何开关写成 `NO`；用户仍可先卸载当前项，再安装另一项。
- Hide Home Bar：继续使用原有“单独队列 + respring”规则，不并入普通 enabled-key 互斥组。
- 界面分组：Package Tab 仍展示全部可见 package，并按状态栏、主屏幕布局、壁纸等具体互斥域分别建立 section；Settings Tab 采用相同分组，但只整理具有配置页且同组至少有两个可见成员的项目。同一功能属于多个互斥域时，界面只采用 registry 中第一个匹配域作为展示归属，底层仍保留全部互斥关系。
