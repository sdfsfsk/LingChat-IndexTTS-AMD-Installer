# LingChat IndexTTS-AMD 安装器

这是 LingChat 内置 IndexTTS2 的公开资源安装器，面向 Windows 11 + AMD Radeon 显卡。

仓库只包含安装与校验脚本，不包含模型权重、第三方运行库或任何私人音色。安装时会从官方来源下载：

- Python 3.10.11：`python.org`
- AMD ROCm PyTorch：`repo.amd.com`
- IndexTTS2 模型：`IndexTeam/IndexTTS-2`

## 下载

[下载最新安装包](https://github.com/sdfsfsk/LingChat-IndexTTS-AMD-Installer/releases/latest)

## 快速安装

1. 安装包含“IndexTTS-AMD（内置）”功能的 LingChat。
2. 下载本仓库，双击 `完整安装-AMD.bat`。
3. 按提示选择 LingChat 的安装目录，等待运行时和模型下载完成。
4. 在 LingChat 的角色语音设置中选择 `IndexTTS-AMD（内置）`。
5. 在高级设置的音色管理中上传你有权使用的参考音频。

也可以在命令行中明确指定目录：

```bat
完整安装-AMD.bat "D:\Apps\LingChat"
```

安装目标采用相对布局，不绑定盘符：

```text
LingChat\
└─ bin\
   ├─ engine\
   │  └─ runtime\
   └─ data\
      └─ third_party\
         └─ IndexTTS-AMD\
            ├─ checkpoints\
            ├─ voices\
            └─ install-manifest.json
```

## 分开安装

只下载或修复官方模型：

```bat
仅下载模型.bat "D:\Apps\LingChat"
```

只建立 AMD 运行时：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Runtime.ps1 `
  -LingChatPath "D:\Apps\LingChat"
```

安装完成后重新校验：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Verify-Installation.ps1 `
  -LingChatPath "D:\Apps\LingChat"
```

## 显卡与运行时

默认 AMD wheel 通道是 `gfx120X-all`，已在 Radeon RX 9070 XT 上验证。其他受支持架构可手动传入 AMD 官方 wheel 索引：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Runtime.ps1 `
  -LingChatPath "D:\Apps\LingChat" `
  -AmdWheelIndex "https://repo.amd.com/rocm/whl/gfx110X-all"
```

运行时安装器使用与 LingChat 内嵌接口匹配的 Python 3.10，并安装 AMD ROCm 7.13 预览版 PyTorch。请先安装与该 ROCm 版本及显卡匹配的 AMD 驱动。非 `gfx120X` 架构没有在本仓库维护者的机器上验证。

## 下载体积与断点续传

- IndexTTS2 官方模型约 5.9 GB。
- AMD Python 运行时安装后通常超过 6 GB。
- 建议至少预留 20 GB 可用空间。
- 模型下载通过 Windows 自带的 `curl.exe` 断点续传。
- 每个 Hugging Face LFS 文件会按官方 SHA-256 校验。
- 下载被中断时，重新运行同一个脚本即可继续。

## 音色隐私

本仓库不会提供、上传或收集派蒙等私人参考音频。请只上传你拥有授权的 WAV、MP3、FLAC、M4A 或 OGG 文件。音色文件保存在本机 LingChat 数据目录中。

## 常见问题

### LingChat 一直停在 TTS 初始化

运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Verify-Installation.ps1
```

重点检查：

- `engine\runtime\python310.dll` 是否存在；
- `torch.cuda.is_available()` 是否为 `True`；
- `checkpoints\gpt.pth`、`s2mel.pth`、`config.yaml` 是否完整；
- 高级设置中是否至少上传了一个音色。

### 模型下载失败

保留 `.part` 文件并重新运行，脚本会断点续传。若网络无法访问 Hugging Face，可以稍后重试；不要从不明网盘获取被修改过的权重。

### 为什么不把模型放到 GitHub Release

官方模型本身接近 6 GB，并受 IndexTTS 独立模型协议约束。本安装器直接下载官方版本、记录具体提交号并验证哈希，能避免二次分发和来源不明。

## 许可证

本仓库中的安装脚本采用 MIT License。IndexTTS2、模型权重、Python、PyTorch 与 AMD ROCm 均使用各自的许可证；详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
