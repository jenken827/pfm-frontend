# 云坞（CloudDock）

pfm 的 Flutter 客户端（Android / iOS / Windows / macOS / Linux / Web），以及随客户端分发的
BLAKE3 原生加速库。

后端在 [`pfm`](https://github.com/jenken827/pfm)（Go，REST/JSON）；应用侧 protobuf 数据结构
在 [`pfm-proto`](https://github.com/jenken827/pfm-proto)，以 `package:pfm_proto` 的形式依赖。

```
lib/            # 应用代码（blocs / pages / router / api / models …）
  api/          # HTTP 客户端与 protojson 编解码
  blocs/        # flutter_bloc 状态
  pages/        # 页面
native/         # BLAKE3 的 Rust 实现（dart:ffi 加速，可选）
test/           # widget / 单元测试
android|ios|macos|linux|windows|web   # 各平台工程
dev.sh          # 依赖 / 运行 / 构建 / 发布统一入口
```

## 依赖

| 组件 | 要求 |
|---|---|
| Flutter / Dart | Flutter 3.47+，Dart `^3.13.0`（统一用 `puro` 管理 SDK 版本） |
| pfm-proto | 按 git tag 取（`pubspec.yaml` 里的 `git: ref:`），不用 clone |
| Rust + Android NDK | 可选，只影响上传哈希吞吐（缺了就退回纯 Dart BLAKE3） |

```bash
puro flutter pub get          # 或 ./dev.sh get
```

## 常用命令

```bash
./dev.sh get              # 拉依赖
./dev.sh gen-l10n         # 生成 l10n
./dev.sh build_runner     # 生成路由 / Hive 适配器等 *.g.dart
./dev.sh analyze          # 静态检查（必须 No issues found）
./dev.sh run              # 跑起来（可指定设备）
./dev.sh build android    # 构建 APK；产物另拷一份到 release/
./dev.sh native android   # 可选：构建 BLAKE3 原生库（host / android / android-multi）
./dev.sh all              # 依赖 → 代码生成 → 分析 → 构建
```

`build` / `all` 会自动把 `pubspec.yaml` 的版本号补成「语义版本 + 日期构建号」，并把交付包按
`pfm_<版本>_<YYYYMMDD>-<短commit8>_<平台>.<扩展名>` 拷到 `release/`（该目录不进版本控制）。

### Android 发布签名

release 包要用固定的签名密钥签，否则已安装的手机会因为签名不同而覆盖安装失败。构建前把
`key.properties` 与对应的 keystore 放到 `android/` 下（两者都在 `.gitignore` 里，**不要提交**）：

```
android/key.properties      # storePassword / keyPassword / keyAlias / storeFile
android/pfm-release.jks     # 具体文件名由 key.properties 的 storeFile 决定
```

缺 `key.properties` 时 `./dev.sh build android` 会直接报错退出（`build.gradle.kts` 在缺文件时
会退回 debug 签名，构建能成功但装不上）。

### 发布（GitHub Actions）

`.github/workflows/ci.yml` 管每次 push / PR 的 analyze + test；`.github/workflows/release.yml`
管发布：**推一个 `v<版本>` tag 就构建 Android + Windows 并建 GitHub Release**。

```bash
# pubspec.yaml 里 version 是 1.2.3，tag 就必须是 v1.2.3
git tag v1.2.3 && git push origin v1.2.3
```

产物（`checksums.txt` 里带 SHA-256）：

```
pfm_<版本>_<YYYYMMDD>-<短commit8>_arm64-v8a.apk          # Android，arm64 手机直接装
pfm_<版本>_<YYYYMMDD>-<短commit8>_windows-x64-setup.exe  # Windows 安装包（双击安装，装到当前用户目录）
pfm_<版本>_<YYYYMMDD>-<短commit8>_windows-x64.zip        # Windows 便携版，解压后跑 Release/clouddock.exe
```

要点：

- Windows 产物有两个：`setup.exe` 是安装包（单文件、免管理员权限），`zip` 是便携版；
  安装包脚本在 `windows/installer/clouddock.iss`。
- tag 与 `pubspec.yaml` 的版本对不上会直接失败；版本号里的 `+<构建号>` 由 CI 用当天日期填，
  与 `./dev.sh` 一致。
- Android 用仓库 Secret 里的发布密钥签名，**缺 Secret 就失败**（不会退回 debug 签名）；构建后
  还会核对 `apksigner` 打出的证书 SHA-256，对不上就中断。
- 需要两个 Secret：`ANDROID_KEYSTORE_BASE64`（`base64 -w0 pfm-release.jks` 的结果）与
  `ANDROID_KEYSTORE_PASSWORD`（keystore 口令）。

## 与后端 / proto 的关系

- 接口字段名以 **protojson** 为准（`driver_id` ↔ `driverId`），新增或改动页面时先 `curl` 一遍
  真实接口，再写视图与测试。
- 生成的 Dart 代码来自 `pfm_proto` 包（`package:pfm_proto/native/...`），**不要**在本仓库里
  放 proto 源或手写生成代码；改协议去 `pfm-proto` 仓库，然后升级本仓库的依赖。
- 后端知识（架构、接口约定、部署）见 `pfm` 仓库的 README。

## 许可

AGPL-3.0（见 `pfm` 仓库的 LICENSE）。
