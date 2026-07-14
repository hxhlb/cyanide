# Release Notes

Keep concrete, user-facing release bullets here as changes land. The release
script reads `## Pending` before building, uses those bullets for GitHub release
notes and the generated in-app changelog, then moves them under `## Released`
after a successful build.

Good bullets describe the behavior users will notice:

- Reduced flicker when Dynamic Stage windows resize.
- Fixed installer queue badges after changing package selection.
- Added an iOS 17 fallback for Disable App Library.

Use one bullet per user-facing tweak or fix. Do not combine unrelated tweak
changes into the same bullet.

For bilingual notes, put the Chinese text in the bullet and the English text
on the following indented line. Do not join the two languages with `/`.

Avoid vague bullets like "Update settings", "Change project files", or
"Misc fixes".

It is OK to mention user-visible beta or experimental tweaks when describing
added or improved features. Credit original tweak or project authors alongside
the Cyanide port author when known. Do not mention experimental source movement,
non-public repository names, non-public implementation details, or commentary
about which experimental pieces are working versus not wired. If the change
cannot be phrased as a user-facing feature or fix without revealing internal
activity, omit it.

## Pending


## Released

### v1.4.1 - 2026-07-14

- [x] 新增 UIKit Debug Overlay。
  Added UIKit Debug Overlay.
- [x] 新增 Upside Down。
  Added Upside Down.
- [x] 优化 MilkyWay Lite 功能。
  Improved MilkyWay Lite.

### v1.4.0 - 2026-07-14

- [x] 新增 iPad Dock，可在 iPhone 上启用 iPad 风格 Dock，并使用 App 资源库入口。
  Added iPad Dock, bringing the iPad-style Dock and App Library access to iPhone.
- [x] 改进 JavaScript tweak 管理，支持同时启用多个来源软件包，并修复安装、移除和待处理状态显示。
  Improved JavaScript tweak management with multiple source packages and more accurate install, removal, and pending states.
- [x] 改进 JavaScript tweak 的停用与清理流程，让支持恢复的软件包能够正确移除已应用的效果。
  Improved JavaScript tweak disabling and cleanup so supported packages can correctly remove their applied effects.
- [x] 改进 Dock 颜色 tweak 的颜色选项，新增透明度支持。
  Improved the Dock Color tweak's color options with transparency support.
- [x] 完善 JavaScript tweak 开发文档。
  Improved JavaScript tweak documentation.

### v1.3.9 - 2026-07-11

- [x] 新增 IPA Decryptor（Beta）：可对本机已安装应用解密主可执行文件并导出 IPA；加密的 framework、扩展与 dylib 仍保持加密。
  Added IPA Decryptor (Beta) for installed apps: decrypt the main executable and export an IPA; encrypted frameworks, extensions, and dylibs remain encrypted.
- [x] 重组设置和软件包页面：IPA Decryptor 位于 Tools，QuickLoader/RepoTweaks 位于 JavaScript；软件包按 JavaScript 与其他软件包分组。
  Reorganized Settings and Packages: IPA Decryptor is under Tools, QuickLoader/RepoTweaks are under JavaScript, and packages are grouped into JavaScript and other packages.
- [x] 改进中简/中繁本地化，包括 Tweak SDK 写作指南；移除自动日志上传，仅保留本地查看和分享日志。
  Improved Simplified Chinese and Traditional Chinese localization, including the Tweak SDK writing guide; removed automatic log uploads while retaining local log viewing and sharing.
- [x] 将主题格式说明和仓库 tweak 设置拆分为独立页面，便于浏览和配置。
  Moved theme format guidance and repository tweak settings into dedicated pages for clearer browsing and configuration.

### v1.3.8 - 2026-07-03

- [x] 新增 Metal Lock Light 锁屏金属光照效果，支持颜色、反射强度和多种渲染模式。 / Added Metal Lock Light for lock-screen lighting, with color intensity, reflect intensity, and multiple render modes.
- [x] 新增 Mood Wallpaper 趣味壁纸，可根据设备左右倾斜在最多 8 张静态壁纸之间切换。 / Added Mood Wallpaper, switching between up to 8 still wallpapers based on device tilt.
- [x] 改进界面本地化、软件包队列状态和源页面文案。 / Improved UI localization, package queue status, and source-page copy.

### v1.3.7 - 2026-07-01

- [x] 为 MilkyWay Lite 添加可搜索的预选应用列表，可在设置中管理常用小窗应用。
      Added MilkyWay Lite app preselection with a searchable Settings list.
- [x] 优化 MilkyWay Lite 安装速度，SpringBoard 端只显示最近应用和用户预选应用。
      Kept MilkyWay Lite install fast by showing only recent apps plus the preselected picker list in SpringBoard.
- [x] MilkyWay Lite 现在可以包含常用系统应用，例如 Safari、电话、信息、设置、照片和相机。
      Allowed MilkyWay Lite to include common system apps such as Safari, Phone, Messages, Settings, Photos, and Camera.
- [x] 新增 MilkyWay Lite 小窗数量限制配置，支持在设定上限内同时打开多个小窗。
      Added a configurable MilkyWay Lite floating-window limit, with multiple windows supported up to the selected maximum.
- [x] 新增简体中文和繁体中文界面本地化。
      Added Simplified Chinese and Traditional Chinese localizations for the app UI.
- [x] 更新安装器、软件包、源和日志界面的本地化文本。
      Refreshed installer, package, source, and log UI text for the localized build.

### v1.3.6 - 2026-06-27

- [x] Removed Patreon integration and ungated all installable Cyanide tweaks, with stale account-linking state cleared so beta access is the same for everyone.
- [x] Patreon note: tweaks previously gated behind the $3/month tier are now free, $3/month members will receive refunds, and the $10/month Researcher tier is being lowered to $7/month with partial refunds for members who already paid.
- [x] Made in-development tweaks visible but disabled, with notes that their unfinished source remains for future contributors.

### v1.3.5 - 2026-06-24

- [x] Fixed repo tweak update badges so failed installs no longer clear available updates.
- [x] Repo tweak updates now stay as badges until you tap Update, instead of automatically entering the install queue.
- [x] Fixed repo tweak queue rows showing a redundant QuickLoader prefix before the tweak name.
- [x] Made repo tweak updates obvious in the Packages list with an Update Available label and badge.
- [x] Repo tweaks can now declare iOS compatibility limits, with unsupported packages blocked while already-installed ones remain removable.
- [x] Fixed installed source tweaks still appearing as queued through their QuickLoader/native backing package after install.
- [x] Fixed source update badges lingering after installing an update until the source was refreshed again.
- [x] Fixed removing an installed source tweak so Apply Tweaks actually runs the cleanup path instead of only clearing package metadata.
- [x] Reorganized package categories into Status Bar, Home Screen, Theming, SpringBoard, System, and JavaScript Tweaks.
- [x] Fixed section headers shifting horizontally during scroll.

### v1.3.4 - 2026-06-24

- [x] Fixed the queue popup staying visible after Apply Tweaks completes.

### v1.3.3 - 2026-06-24

- [x] Repo tweak detail view now shows the actual tweak description instead of generic install text.
- [x] Cleaned up tweak detail view styling — larger, more readable description and info text.
- [x] Source refresh on update forces repo cache repopulation so per-tweak icons and authors appear immediately.
- [x] Package icon badges now cycle through a spectrum of colors across all list views.

### v1.3.2 - 2026-06-24

- [x] Redesigned Home, Packages, and Sources tabs with a unified visual style — gradient hero, colored icon badges, bold section headers, and compact list cells.
- [x] Packages tab now shows a Recently Added section for new source tweaks and a flat alphabetical package list; category browser moved to Sources.
- [x] Added per-tweak SF Symbol icons and per-tweak author to the repo JSON format.
- [x] Added pull-to-refresh on Packages and Sources, with a green success banner after refresh.
- [x] QuickLoader opened from Home or Sources now runs tweaks directly without going through the install queue.
- [x] Fixed repo tweaks showing both QuickLoader and the tweak itself in the queue and installed package lists.
- [x] Updated JS tweak repo documentation with the new symbol and author optional fields.

### v1.3.1 - 2026-06-24

- [x] Improved QuickLoader UI with loaded tweak display, active status indicator, clear button, and prominent activate button.
- [x] Made the install queue show the loaded QuickLoader script name instead of a generic label.
- [x] Restored Hide Home Bar's stable page-zero path, forced cache-busted repo script fetches before QuickLoader installs, and prompts for respring after repo-served Hide Home Bar runs.
- [x] Fixed Location Simulator coordinate entry for Chinese labels, directions, and full-width punctuation.
- [x] Fixed SnowBoard Lite only applying some visible icons on iOS 26.
- [x] Improved SnowBoard Lite live repair by reusing the SpringBoard channel between ticks and backing off background repair work that could make SpringBoard feel slow.
- [x] Blocked SnowBoard Lite activation until a theme is selected, with a shortcut to open theme settings.
- [x] Made Hide Home Bar stay registered as hidden after respring, with Restore shown as the next package action.

### v1.2.23 - 2026-06-23

- [x] Added a Home tab with What's New, JavaScript Tweaks and RemoteCall Tweaks overviews, and community links.
- [x] Redesigned Packages as a category browser — tap a category to see its tweaks.
- [x] Added JavaScript tweak support by @MinePlayer16: QuickLoader for local .js files and an online Sources tab for HTTPS repos, with the zeroxjf repo (including Hide Dock) pre-installed.
- [x] Added developer documentation in the Sources tab for writing JS tweaks and setting up a repo, with copy and share options.
- [x] Added automatic source refresh with update detection badges on the Sources tab.
- [x] Fixed JS runner stalls, SBCustomizer queue/apply issues, SnowBoard Lite respring delays, and kernel setup hangs on IOSurface mapping failures. Not all reported bugs are addressed yet, but this update should bring more stability overall.

### v1.2.22 - 2026-06-12

- [x] Made FastLockX Lite install through the normal Apply Tweaks queue so it uses the shared SpringBoard setup with other runtime tweaks.
- [x] Paused FastLockX Lite retry pulses while the device is unlocked.
- [x] Improved Hide Home Bar page zeroing stability with a DirtyZero-style single-page write path and verified fallback.
- [x] Improved kernel setup stability when preparing the memory-racing stage.
- [x] Improved FastLockX Lite compatibility with Dynamic Stage Lite by finishing FastLockX setup before Dynamic Stage starts its live control loop.
- [x] Fixed FastLockX Lite not resuming its retry pulse after the device locks on iOS 18.
- [x] Prevented Dynamic Stage Lite from background-filling App Library tiles while FastLockX Lite is active to avoid SpringBoard restarts.
- [x] Fixed Dynamic Stage Lite windows being torn down when the device locks or the screen sleeps.
- [x] Improved FastLockX Lite unlock reliability by debouncing lock-screen timer sync and using no-wake unlock nudges when Face ID leaves the lock screen awake.

### v1.2.21 - 2026-06-12

- [x] Split SnowBoard Lite import into separate Folder and Archive (ZIP/DEB) options so archive imports work reliably on all sideloaded installs.
- [x] Added a hint in the folder import dialog for sideloaded users whose signing tool needs "Match provisioning identifier" enabled.

### v1.2.20 - 2026-06-12

- [x] Fixed SBCustomizer showing as still queued after a successful icon-label or layout apply.
- [x] Fixed unsupported-version runs leaving the Activity sheet stuck in a running state.
- [x] Fixed local builds failing on macOS Bash when no simulator-only xcodebuild extras are set.
- [x] Fixed SnowBoard Lite imports on Signulous installs by copying selected themes into Cyanide instead of opening them in place.

### v1.2.19 - 2026-06-11

- [x] Added FastLockX Lite, available to Patrons for early access, as an experimental tool that automatically unlocks the screen once Face ID is accepted; tested on iOS 18 and iOS 26, with iOS 17 support not confirmed yet. Credits: original FastLockX author Artem Kasper and Cyanide port by zeroxjf.
- [x] Fixed a Patreon linking crash when returning from the in-app OAuth flow.

### v1.2.18 - 2026-06-11

- [x] Tightened Hide Home Bar standalone queue enforcement across all package actions.
- [x] Added iOS 17 support for Drag Coefficient and lowered its minimum value to 0.01.
- [x] Replaced Home Layout Extras sliders with exact number entry rows.

### v1.2.17 - 2026-06-09

- [x] Added Hide Home Bar as a beta package using DirtyZero-style MaterialKit page zeroing.
- [x] Made Hide Home Bar run as a standalone queue item with prominent install-queue guidance.
- [x] Added public Hide Home Bar credits in the package details.
- [x] Added a respring prompt after Hide Home Bar finishes so users know when the home indicator will disappear.
- [x] Fixed a queue review crash when pending changes finish while the queue screen is refreshing.
- [x] Reduced Dynamic Stage Lite picker startup work to avoid SpringBoard resprings on large app libraries.

### v1.2.16 - 2026-06-09

- [x] Prevented overlapping tweak actions from interfering with Apply Tweaks and direct controls.
- [x] Fixed Dynamic Stage Lite sidebar interference with the main tweak UI.

### v1.2.15 - 2026-06-09

- [x] Fixed Double Tap to Lock triggering while entering a Lock Screen passcode.
- [x] Added App Switcher Grid as a Beta tweak.
- [x] Replaced the installer contact button with Signal group and GitHub Issues links.
- [x] Removed the standalone Cyanide Themer listing in favor of SnowBoard Lite.
- [x] Let active Location Simulator target changes use parked kernel recovery before refreshing.
- [x] Kept OTA Block behind kernel recovery before editing launchd job state.
- [x] Kept Call Recording Sound behind kernel recovery before writing CallServices files.
- [x] Kept Watch Pairing override behind kernel recovery before writing NanoRegistry files.

### v1.2.14 - 2026-06-09

- [x] Fixed Dynamic Stage Lite visibility for paid users.
- [x] Fixed LiveWP video selection from Files and added Photos video selection.
- [x] Let active LiveWP users change videos from the installer without deactivating the wallpaper first.
- [x] Prevented LiveWP activation until a valid video has been selected.

### v1.2.13 - 2026-06-08

- [x] Moved Location Simulator to Beta and into the public app tree so it is available without enabling Experimental Tweaks.
- [x] Moved Call Recording Sound to Beta and into the public app tree so it is available without enabling Experimental Tweaks.

### v1.2.12 - 2026-06-08

- [x] Fixed Location Simulator exact coordinate entry so pasted decimal pairs and compass-suffix coordinates are normalized correctly.

### v1.2.11 - 2026-06-07

- [x] Added an optional simulator build path that uses a simulator XPF dylib without changing the normal device IPA build.
- [x] Added a StatBar option to show only live network upload and download speed.
- [x] Fixed the installer queue popup crash on iPadOS when the tab bar is attached after launch.
- [x] Fixed StatBar landscape placement on iPad by sizing the overlay from SpringBoard's active window bounds.
- [x] Fixed custom theme bundle-ID PNGs not preloading for apps that are only visible inside folders.
- [x] Prevented Dynamic Stage Lite and Cyanide Themer live icon repair from running together to avoid SpringBoard resprings.

### v1.2.10 - 2026-06-05

- [x] Updated the Cyanide Signal group invite link.

### v1.2.9 - 2026-06-05

- [x] Fixed NiceBar Lite weather slots by restoring the location-based weather picker, cache, and live refresh flow.

### v1.2.8 - 2026-06-05

- [x] Fixed LiveWP disappearing after leaving Cyanide and aligned NSBar/NiceBar Lite refresh loops with screen wake and sleep state.

### v1.2.7 - 2026-06-05

- [x] Fixed the Installer queue popup overlapping the bottom tab bar on iOS 18.

### v1.2.6 - 2026-06-05

- [x] Fixed LiveWP video changes stopping after one run and SnowBoard Lite icon themes drawing over rounded icon corners.

### v1.2.5 - 2026-06-05

- [x] Replaced the first-launch log collection notice with a Cyanide Signal group invite for feedback, feature requests, and support.
- [x] Added NSBar, NiceBar Lite, SnowBoard Lite, and LiveWP ports from d1y/cyanide-ios, with Settings controls and Installer package credits.
- [x] Allowed public Cyanide checkouts to build without optional experimental tweak sources.

### v1.2.4 - 2026-06-03

- [x] Added a StatBar refresh-rate setting and reduced battery use from repeated temperature polling.
- [x] Fixed Installer queue edge cases so no-op applies finish cleanly and pending activations are remembered after reopening Cyanide.

### v1.2.3 - 2026-06-03

- [x] Improved Gravity Lite startup on iOS 17 by using the faster live-icon capture path.
- [x] Fixed a recent tweak startup regression that could hang while opening the SpringBoard injection channel on A16+ iPhones.
- [x] Fixed Installer package state so successfully applied SpringBoard tweaks no longer appear stuck as activation pending.

### v1.2.2 - 2026-06-03

- [x] Fixed kernel panic on A16+/M-series iPads by guarding the t1sz_boot override so the PAC mask uses the correct value.

### v1.2.1 - 2026-06-03

- [x] Added Drag Coefficient tweak — custom SpringBoard animation speed multiplier ported from kolbicz/DarkSword-Tweaks, with a 5–200% slider (50% = 2× faster, 100% = stock).

### v1.2.0 - 2026-06-03

- [x] Added Gravity Lite with home screen and dock icon physics, tilt control, widget support, and iOS 18/26 compatibility.
- [x] Polished installer, settings, and log presentation with clearer status text, cleaner startup branding, and a maintained release-notes workflow.
- [x] Improved tweak activation and cleanup so unchanged tweaks are not reapplied unnecessarily and SpringBoard-backed tweaks deactivate more reliably.

### v1.1.22 - 2026-06-02

- [x] Reduced flicker when Dynamic Stage windows resize by staging new scene hosts and retiring old hosts after the remote layer has populated.
- [x] Added stronger transition shielding around Dynamic Stage app open, close, and apply paths.
- [x] Tracked DarkSword toggle apply results independently in Settings.
- [x] Improved Disable App Library handling with an iOS 17 fallback path.
- [x] Refined installer queue, badges, and activity status UI.
- [x] Tightened Log tab typography for dense verbose traces.
- [x] Updated the release script to capture dirty submodule changes before committing and tagging the parent release.
