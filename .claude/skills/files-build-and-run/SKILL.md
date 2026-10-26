---
name: files-build-and-run
description: "Build, package, install and launch the Files app (WinUI 3 / MSIX) from source on Windows. Use when asked to build, install, run, deploy, launch or debug Files locally - including Chinese requests like 安装/构建/启动/部署/打包 Files - or to set up a build machine (.NET 10 SDK, Windows SDK, Windows App Runtime, signing cert), or to troubleshoot the MSIX build/install/launch flow (cswinrt 'Could not find the Windows SDK in the registry', '0x800B0109' untrusted root certificate, '0x80073CFB' package conflict, WMC0110/WMC0001 XAML errors)."
---

# 在 Windows 上从源码构建、安装并启动 Files

Files 是 **WinUI 3 / MSIX 打包应用**。因此：

> **不能**直接运行 `bin\...\Files.exe`——它没有包身份（package identity），
> `Windows.Storage.ApplicationData.Current` 会抛异常。必须先生成 `.msix`、安装到系统、再从已安装位置启动。

## 一条命令（推荐）

仓库自带幂等脚本 `.claude/skills/files-build-and-run/scripts/build-and-run.ps1`，
按「自检 → 打包 → 安装 → 启动 → 验证」顺序跑，已满足的条件自动跳过。

**必须用 Windows PowerShell 5.1**（`Appx` 模块在 PowerShell 7 中不存在）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.claude\skills\files-build-and-run\scripts\build-and-run.ps1 `
    -InstallMissingSdk `
    -InstallMissingRuntime `
    -InstallMissingWindowsSdk `
    -ElevateIfNeeded `
    -ScreenshotPath "$env:TEMP\files-launch.png"
```

脚本会自动向上查找 `Files.slnx` 定位仓库根目录，不需要传 `-RepoRoot`。

| 参数 | 作用 | 什么时候用 |
| --- | --- | --- |
| `-InstallMissingSdk` | 缺 .NET 10 SDK 时用 winget 装 | 新机器 |
| `-InstallMissingRuntime` | 缺 Windows App Runtime 时按用户装（免管理员） | 新机器 |
| `-InstallMissingWindowsSdk` | 缺 Windows SDK 时用 winget 装（约 1 GB，需管理员） | 新机器 |
| `-ElevateIfNeeded` | 证书未被本机信任时弹 UAC 提权 | 新机器（需人工点一次「是」） |
| `-SkipLaunch` | 只构建安装，不启动 | CI / 批量构建 |
| `-ScreenshotPath <path>` | 启动后输出桌面截图 | 验证 UI 是否渲染 |
| `-RepoRoot <path>` | 指定仓库根目录 | 脚本被复制到别处时 |

退出码：`0` 成功；`2` 仓库路径不对；`3` 缺少前置依赖；`4` 证书未受信任；`5` 还原失败；
`6` 构建失败；`7` 未产出 MSIX；`8` 安装失败；`9` 包未注册；`10` 启动后没有窗口。

## 前置环境（先探测，再动手）

不要假设环境状态——每一步都先跑探测命令。

| 组件 | 要求 | 探测命令 |
| --- | --- | --- |
| 操作系统 | Windows 10 2004 (19041) 以上 | `(Get-CimInstance Win32_OperatingSystem).Caption` |
| .NET SDK | 10.x（`global.json` 要求 ≥ 10.0.102，`rollForward=latestMajor`） | `dotnet --list-sdks` |
| **Windows SDK** | **10.0.26100（必需）** | `Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots'` |
| Windows App Runtime | 2.x ≥ 2.5.1（与 `Microsoft.WindowsAppSDK` 一致） | `Get-AppxPackage -Name 'Microsoft.WindowsAppRuntime.2*'` |
| 网络 | `api.nuget.org`、`pkgs.dev.azure.com`（Toolkit Labs 源） | `Test-NetConnection` |
| 管理员权限 | 仅「证书入信任」「装 SDK」两步需要 | 见下 |

### 为什么 Windows SDK 是必需的

`cswinrt.exe`（C#/WinRT 投影生成器）要读注册表
`HKLM\SOFTWARE\Microsoft\Windows Kits\Installed Roots` 的 `KitsRoot10`，据此定位 SDK 的
`UnionMetadata` / `References` 下的 `.winmd`。缺它会报：

```
error : Could not find the Windows SDK in the registry
error MSB3073: 命令"...\cswinrt.exe" @"...\cswinrt.rsp"已退出，代码为 1。
```

NuGet 包 `Microsoft.Windows.SDK.NET.Ref` 虽然带了各契约的 `.winmd`，但**不包含** SDK 的
安装目录结构，注册表里没有 `KitsRoot10` 一样会失败。

```powershell
winget install --id Microsoft.WindowsSDK.10.0.26100 --source winget -e
```

> 版本与 `Directory.Build.props` 的 `WindowsSdkPackageVersion`（10.0.26100.67-preview）对齐。
> 安装器会静默下载约 1 GB 的组件，全程需要几分钟并弹 UAC。
> 日志在 `%TEMP%\windowssdk\` 下。

### Windows App Runtime 版本号陷阱

必须按**包名**筛 `'Microsoft.WindowsAppRuntime.2*'`。1.x 的运行时版本号是
`4000.x` / `8000.x`，直接比较版本号会把 1.x 误判为满足 2.5.1。

## 手工流程（脚本不可用时）

### 1. 信任签名证书（唯一需要提权的一步）

MSIX 必须签名，且 `Package.appxmanifest` 里 `Publisher="CN=Files"`，所以证书主题必须是 `CN=Files`。

用 .NET API 生成（不依赖 `Cert:` 驱动器——部分精简版 Windows 缺 `Microsoft.PowerShell.Security` 模块）：

```powershell
$ErrorActionPreference = 'Stop'
$dest = "$env:TEMP\FilesApp_SelfSigned.pfx"
$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 2048
$req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
    'CN=Files', $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$eku = New-Object System.Security.Cryptography.OidCollection
$eku.Add((New-Object System.Security.Cryptography.Oid('1.3.6.1.5.5.7.3.3')))
$req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension($eku, $false)))
$req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension($false, $false, 0, $true)))
$cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(3))
[System.IO.File]::WriteAllBytes($dest, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12))
[System.IO.File]::WriteAllBytes("$env:TEMP\FilesApp_SelfSigned.cer", $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
```

加入**本机**（`LocalMachine`）Root 存储——包部署由系统服务完成，只信任用户级 Root 会失败，
报 `0x800B0109`（找不到可信根证书）：

```powershell
certutil -addstore -f Root "$env:TEMP\FilesApp_SelfSigned.cer"   # 需要管理员
```

`-f` 用于跳过「是否信任该证书」弹窗。

### 2. 还原（只需一次）

```powershell
dotnet restore Files.slnx
```

必须还原**整个解决方案**：`Files.App` 构建时会联动编译 `Files.App.Server`，
该项目的 `project.assets.json` 缺失会报 `NETSDK1004`。

> 还原时 C++ 项目（`.vcxproj`）报 `NU1503` 是**正常现象**——这些原生项目不支持 NuGet 方式还原，
> 且主应用不依赖它们的编译产物。

### 3. 构建 + 打包 MSIX

```powershell
dotnet build src/Files.App/Files.App.csproj -c Debug -p:Platform=x64 `
  -p:AppxBundle=Never `
  -p:GenerateAppxPackageOnBuild=true `
  -p:UapAppxPackageBuildMode=SideloadOnly `
  -p:AppxPackageSigningEnabled=true `
  -p:PackageCertificateKeyFile="$env:TEMP\FilesApp_SelfSigned.pfx" `
  -p:PackageCertificatePassword="" `
  -p:PublishAot=false -p:SelfContained=false -p:PublishReadyToRun=false `
  -v:quiet -clp:ErrorsOnly
```

- `-p:PublishAot=false -p:SelfContained=false -p:PublishReadyToRun=false`：仓库自带的
  `win-x64.pubxml` 开了 **NativeAOT**，而 AOT 依赖 C++ 链接器，缺「桌面开发 C++」工作负载会报
  `Platform linker not found`。本地调试关掉这三个开关走 IL 版即可。
- 产物：`src\Files.App\AppPackages\Files.App_<版本>_x64_Debug_Test\Files.App_<版本>_x64_Debug.msix`。
  版本号随仓库变化，**不要写死路径**，现场取最新的：

  ```powershell
  Get-ChildItem src\Files.App\AppPackages -Filter *.msix -Recurse |
      Where-Object { $_.FullName -notmatch '\\Dependencies\\' } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
  ```

### 4. 安装

重新构建后包内容哈希会变，Windows 不允许直接覆盖同标识的已安装包（报 `0x80073CFB`），
所以**先卸载再装**：

```powershell
Get-AppxPackage -Name FilesDev | Remove-AppxPackage -PreserveApplicationData
Add-AppxPackage -Path "<上面查到的 msix 路径>" -ErrorAction Stop
Get-AppxPackage -Name FilesDev | Select-Object Name, Version, Status   # Status 应为 Ok
```

### 5. 启动并验证

```powershell
files-dev.exe
```

（也可从开始菜单搜「Files - Dev」。）

**成功判据**：进程 `Files` 的窗口标题为 `主页 - Files` / `Home - Files`。
仅「进程存在」不算成功——启动闪屏的窗口标题恰好也是 `Files`，别误判。

```powershell
Get-Process -Name Files | Select-Object Id, MainWindowTitle
```

应用启动需要十几秒，第一次更慢。

## 绝对不要做的事

| 不要做 | 原因 |
| --- | --- |
| 用 VS 2022 的 `msbuild.exe` 构建 | MSBuild 17.14 < 18.0，.NET 10 SDK 直接报错 |
| 用 `dotnet publish` 打包 | 会因 `Files.App.Server` winmd 路径问题失败（`MSB3030` / `NETSDK1032`） |
| 直接运行 `bin\...\Files.exe` | 缺包身份，`ApplicationData.Current` 会抛异常 |
| 用 `explorer.exe shell:AppsFolder\<AUMID>` 启动 | 实测不会激活应用，只会打开「应用程序」目录 |
| 改 `global.json` 迁就本机 SDK 版本 | 属于改动仓库配置，且会掩盖真实的版本要求 |
| 反复重跑完整构建来「碰运气」 | 构建耗时数分钟；先看 `-clp:ErrorsOnly` 的错误输出定位问题 |
| 把 `bin`/`obj` 下的生成文件读进上下文 | 体积大且无信息量 |
| 用 `PrintWindow` 抓取窗口内容 | WinUI 3 走 DirectComposition 渲染，截出来是全黑；用桌面截图 |

## 上游源码 bug：`IsGrouped` / `ResetGroups` 不存在

**这是仓库代码本身编译不过，不是环境问题。**

commit `1258eb7ad`（*Feature: Added support for reordering sidebar items (#18951)*）给基类
`BulkConcurrentObservableCollection<T>` 加了 `Move()`，其中调用了 `IsGrouped` 和 `ResetGroups`——
但这两个成员**只定义在派生类** `GroupableBulkConcurrentObservableCollection<T>` 里，
C# 不允许基类访问派生类成员：

```
src\Files.App\Utils\Storage\Collection\BulkConcurrentObservableCollection.cs(304,8):
  error CS0103: 当前上下文中不存在名称"IsGrouped"
```

截至 2026-10 上游 `files-community/Files` 的 `main` 仍停在该提交，**尚未修复**。

补丁在 `references/upstream-fix.patch`（沿用基类已有的 `protected virtual` 钩子风格）：

```powershell
git apply .\.claude\skills\files-build-and-run\references\upstream-fix.patch
```

上游修好后即可丢弃这个补丁。

> **级联错误警告**：改完之后 XAML 编译器会连带报几十条
> `WMC0001: Unknown type 'ResourceString'`、`WMC0110: Unknown target type`。
> 那些同样是**级联错误**——`Files.App` 的 C# 编译失败，XAML 编译器就看不到本程序集里的类型。
> 先修好 `CS0103`，其余会一起消失。**不要去改 XAML。**

## 常见故障排查

| 报错 | 原因 | 处理 |
| --- | --- | --- |
| `A compatible .NET SDK was not found. Requested SDK version: 10.0.102` | 没装 .NET 10 SDK | `winget install --id Microsoft.DotNet.SDK.10 --source winget -e` |
| `Version 10.0.403 of the .NET SDK requires at least version 18.0.0 of MSBuild` | 用 VS 2022 的 `msbuild.exe` 构建 | 改用 `dotnet build`，或装 VS 2026 |
| `NETSDK1004: 找不到资产文件 ...Files.App.Server\obj\project.assets.json` | 没还原整个解决方案 | `dotnet restore Files.slnx` |
| `error : Could not find the Windows SDK in the registry` | 没装 Windows SDK | 见上文「为什么 Windows SDK 是必需的」 |
| `XamlCompiler error WMC0110 / WMC0001` | 上一条 cswinrt 失败或 `CS0103` 的级联错误 | 装好 SDK、修好 `CS0103`，不要改 XAML |
| `error CS0103: ... "IsGrouped"` | 上游源码 bug | 应用 `references/upstream-fix.patch` |
| `Platform linker not found ... Desktop Development for C++ workload` | 开了 NativeAOT 但缺 MSVC | 加 `-p:PublishAot=false -p:SelfContained=false` |
| `0x800B0109 ... 找不到可信根证书` | 签名证书未被信任 | 加到 **LocalMachine**\Root，需管理员 |
| `0x80073CFB ... 提供的包与已安装包冲突` | 重建后包哈希变了 | 先 `Remove-AppxPackage` 再 `Add-AppxPackage` |
| `无法加载文件 ...Appx ... 0x80131539` | 用了 pwsh / PowerShell 7 | 改用 `powershell.exe`（5.1） |
| `在此系统上禁止运行脚本` | 执行策略限制 | 加 `-ExecutionPolicy Bypass` |
| `MSB3030: 无法复制文件 ...Files.App.Server.winmd` | 用了 `dotnet publish` | 改用 `dotnet build` |
| 打包成功但找不到 `.msix` | 输出目录不是 `bin` | 在 `src\Files.App\AppPackages\` 下找 |
| 还原报 `NU1101` / `NU1301`，提到 `CommunityToolkit.Labs` | Toolkit Labs 源不可达 | 检查代理/防火墙；`nuget.config` 里该源必须保留 |
| 还原报找不到 `SevenZipSharp` / `LibGit2Sharp` | 本地源 `src/Files.App/Assets/Libraries\` 缺失 | 用完整仓库，不要只拷 `src` |
| `Cert:` 驱动器 / `Get-AuthenticodeSignature` 不可用 | 缺 `Microsoft.PowerShell.Security` 模块 | 用本文的 .NET API 方案生成证书 |
| 「设为默认应用」「打开/保存对话框」不可用 | C++ 项目未编译 | 需装「桌面开发 C++」工作负载并编译 `src\Files.App.Launcher` |

## 调试

- **不用 VS**：VS 2022 无法构建本项目，可改用 VS 2026，或在 IDE 里附加到 `Files.exe` 进程。
- **附加调试**：先 `files-dev.exe` 启动应用，再让调试器附加到进程 `Files`。
- **查看日志**：`%LOCALAPPDATA%\Packages\FilesDev_ykqwq8d6ps0ag\LocalState\logs\`。

## 日常开发循环

```powershell
# 1) 重新构建 + 打包
dotnet build src/Files.App/Files.App.csproj -c Debug -p:Platform=x64 `
  -p:AppxBundle=Never -p:GenerateAppxPackageOnBuild=true `
  -p:UapAppxPackageBuildMode=SideloadOnly -p:AppxPackageSigningEnabled=true `
  -p:PackageCertificateKeyFile="$env:TEMP\FilesApp_SelfSigned.pfx" `
  -p:PackageCertificatePassword="" `
  -p:PublishAot=false -p:SelfContained=false -p:PublishReadyToRun=false `
  -v:quiet -clp:ErrorsOnly

# 2) 覆盖安装（先卸载旧注册，否则报 0x80073CFB）
Get-AppxPackage -Name FilesDev | Remove-AppxPackage -PreserveApplicationData
Add-AppxPackage -Path "<新的 msix 路径>" -ErrorAction Stop

# 3) 启动
files-dev.exe
```

> 已安装包在 `C:\Program Files\WindowsApps\...`，受系统保护，**不能**直接替换里面的 dll，
> 必须走第 2 步重新 `Add-AppxPackage`。
> 重装前先 `Stop-Process` 停掉 `Files`，否则文件占用会导致安装失败。
