# DiuBangNASClient for Windows

> 本项目基于 [DianDanHuaJuan/DiuBangNASClient](https://github.com/DianDanHuaJuan/DiuBangNASClient)（Flutter Android 客户端，MIT 许可）移植开发，增加了 Windows 桌面端支持。
> 配套服务端：[DiuBangNASServer_Windows](https://github.com/DianDanHuaJuan/DiuBangNASServer_Windows) · [diubangNASServer_Android](https://github.com/DianDanHuaJuan/diubangNASServer_Android)。
> Windows 适配中的 mDNS、托盘、SQLite FFI、Inno Setup 打包等做法参考了 DiuBangNASServer_Windows。原项目版权归原作者所有，详见 [LICENSE](LICENSE)。

局域网 NAS 客户端（Flutter，支持 Android 与 Windows）：支持 mDNS 服务发现、WebDAV 文件访问、媒体预览、定时备份，以及通过 NAS 中转的设备间文件互传。

**许可证：** [MIT](LICENSE) · **版本：** 1.0.1

## 功能特性

- 通过 mDNS 自动发现局域网内的 NAS 服务器
- 控制面 Basic Auth 认证；通过 WebDAV 协议进行文件读写
- 浏览、上传、下载、预览照片和视频
- 定时备份与手动备份到 NAS 服务端
- 设备间文件互传（以 NAS 服务端 为中转）

## 环境要求

- Flutter SDK，兼容 **Dart ^3.10.7**（见 `pubspec.yaml`）
- Android 工具链，或 Windows 10/11 x64 + Visual Studio 2022（含「使用 C++ 的桌面开发」）
- 一台兼容的 NAS 服务器（提供控制面 API 以及 WebDAV 文件访问）

## 快速开始

1. 从 GitHub 克隆仓库：

   ```bash
   git clone https://github.com/DianDanHuaJuan/DiuBangNASClient.git
   cd DiuBangNASClient
   ```

2. 安装依赖：

   ```bash
   flutter pub get
   ```

3. 构建 Debug APK（推荐）：

   ```bash
   flutter build apk --debug
   ```

   输出文件：`build/app/outputs/flutter-apk/app-debug.apk`

   如需直接在已连接的 Android 设备或模拟器上调试运行，可额外使用：

   ```bash
   flutter run
   ```

   `flutter run` 依赖 ADB 和可用设备。

## 构建发布版本

1. 如需产出可分发的正式安装包，请自行生成或使用你自己的 Android 签名密钥库，并复制 `android/key.properties.example` 为 `android/key.properties` 后填入本机配置。

2. 构建：

   ```bash
   flutter build apk --release
   ```

   如果未提供 `android/key.properties`，当前项目会回退为使用 debug 签名完成 release 构建；这只适合本地测试，不适合对外分发或上架。

   输出文件：`build/app/outputs/flutter-apk/diubang_nasclient_<版本号>.apk`（`applicationId`: `com.diubang.nasclient`）。

### 构建网络说明

若 Gradle 依赖下载失败或很慢，可在 `android/gradle.properties` 将 `localProxyEnabled` 改为 `true`，并把 `localProxyPort` 设为 Clash 等的 **HTTP/mixed** 端口（勿填 SOCKS）。构建日志出现 `[localProxy] enabled …` 即表示生效。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## Windows 版

- 安装：从 Actions 构建产物或 Releases 下载 `DiuBangNASClient-Setup-<版本>.exe` 运行即可；也提供免安装 zip。
- 本地构建：

  ```powershell
  flutter pub get
  flutter build windows --release
  .\packaging\windows\collect_vc_runtime.ps1 -ReleaseDir build\windows\x64\runner\Release
  & "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" packaging\windows\diubang_nasclient.iss
  ```

- 与安卓版的差异：
  - 备份对象为你选择的本地文件夹（递归扫描图片和视频），而不是相册。
  - 定时备份由应用内调度执行；关闭窗口会最小化到托盘，可在托盘菜单开启开机自启。
  - 配对时可粘贴配对码，或选择二维码截图识别（Windows 无摄像头扫码）。
  - 下载的图片/视频保存到「图片\铥棒文件」，其他文件保存到「下载\铥棒文件」。
- 推送 `v*` 标签会自动发布 Release。

## 贡献

详见 [CONTRIBUTING.md](CONTRIBUTING.md)。提交 Pull Request 前请确保 `flutter analyze` 和 `flutter test` 通过。

## 更新日志

详见 [CHANGELOG.md](CHANGELOG.md)。

## 第三方代码

- [`third_party/extended_video_player_android`](third_party/extended_video_player_android) — 内置的视频播放器插件分支（上游许可证见该目录下的 `LICENSE` 文件）。

## 安全

详见 [SECURITY.md](SECURITY.md)。切勿提交生产凭据、签名密钥库或私有签名文件。
