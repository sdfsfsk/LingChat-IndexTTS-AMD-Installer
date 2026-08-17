# LingChat IndexTTS-AMD 安装器

这是为 [LingChat](https://github.com/sdfsfsk/LingChat) 准备的 **IndexTTS-AMD 独立服务器**安装器，面向 Windows 11 + AMD Radeon 显卡，默认安装 **IndexTTS-2.5**（中/英/日/西/阿多语言）。

服务器以独立进程运行（FastAPI，`127.0.0.1` 本地回环），LingChat 通过内置的 `indextts2` HTTP 适配器调用它。

仓库只包含安装与校验脚本，不包含模型权重、第三方运行库或任何私人音色。安装时会从官方来源下载：

- Python 3.10.11 嵌入式包：`python.org`
- AMD ROCm PyTorch：`repo.amd.com`
- index-tts 上游源码（锁定提交，安装时应用 AMD 适配补丁）：`github.com/index-tts/index-tts`
- IndexTTS-2.5 模型：`IndexTeam/IndexTTS-2.5`（可选旧版 `IndexTeam/IndexTTS-2` 回退）

## 下载

下载最新安装包（Code → Download ZIP，或 Releases 中的打包）。

## 快速安装

1. 安装 LingChat（0.5.0 及以上）。
2. 下载本仓库，双击 `完整安装-AMD.bat`。
3. 按提示选择 LingChat 的安装目录，等待运行时、服务端和模型下载完成。
4. 双击安装产物里的 `启动-IndexTTS-AMD.bat` 启动服务器（见下文目录布局）。
5. 在 LingChat 全局设置中确认 `tts.indextts_api_url` 为
   `http://127.0.0.1:9880/voice/indextts/presets`（**必须是包含路径的完整地址**）。
6. 角色设置中选择 `tts_type: indextts2`，`voice_lang` 按需选 `zh` / `ja` / `en` 等。
7. 把你有权使用的参考音频（wav/mp3/flac/ogg）放进 `voices` 目录即成为音色预设（按文件名排序，序号即预设 id，从 0 开始）。

也可以在命令行中明确指定目录：

```bat
完整安装-AMD.bat "D:\Apps\LingChat"
```

安装目标采用相对布局，不绑定盘符，整体自包含：

```
LingChat\
└─ bin\
   └─ data\
      └─ third_party\
         └─ IndexTTS-AMD\
            ├─ runtime\            # 嵌入式 Python 3.10 + ROCm torch + 全部依赖
            ├─ repo\indextts\      # 上游源码（锁定提交 + AMD 补丁）
            ├─ checkpoints-2.5\    # IndexTTS-2.5 官方权重（默认）
            ├─ checkpoints\        # 旧版 IndexTTS-2 权重（可选回退）
            ├─ voices\             # 音色预设
            ├─ server_indextts.py  # FastAPI 服务
            ├─ 启动-IndexTTS-AMD.bat / 停止-IndexTTS-AMD.bat
            └─ install-manifest-*.json
```

## 启动与停止

- 启动：双击 `启动-IndexTTS-AMD.bat`，默认监听 `127.0.0.1:9880`（与 LingChat 默认端口一致）
- 首次启动会自动下载缺失的辅助模型（BigVGAN、w2v-bert-2.0 等，数 GB），耐心等一次即可
- 健康检查：浏览器打开 `http://127.0.0.1:9880/health`
- 重复启动会先按端口清理旧实例（仅当命令行确认是本目录的 `server_indextts.py`，不会误杀别的程序）
- 换端口：先 `set INDEXTTS_PORT=新端口` 再运行启动脚本，并同步修改 LingChat 里的 `tts.indextts_api_url`
- 停止：双击 `停止-IndexTTS-AMD.bat`，或直接关掉命令行窗口

## 模型版本与回退

默认安装 IndexTTS-2.5。如需旧版 IndexTTS-2 作为回退：

```bat
仅下载模型.bat "D:\Apps\LingChat" 2
```

两个版本都装时，默认使用 2.5；在启动前 `set INDEXTTS_VERSION=2` 即可切回旧版。

## 分开安装

只下载或修复官方模型（默认 2.5）：

```bat
仅下载模型.bat "D:\Apps\LingChat"
```

只建立 AMD 运行时：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Runtime.ps1 `
  -LingChatPath "D:\Apps\LingChat"
```

只重装/更新服务端源码与脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Server.ps1 `
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

运行时为嵌入式 Python 3.10，安装 AMD ROCm 7.13 PyTorch（torch 2.11）。请先安装与该 ROCm 版本及显卡匹配的 AMD 驱动。非 `gfx120X` 架构没有在本仓库维护者的机器上验证。

## 下载体积与断点续传

- IndexTTS-2.5 官方模型约 5.5 GB。
- AMD Python 运行时安装后通常超过 6 GB。
- 首次启动下载的辅助模型约 2~3 GB。
- 建议至少预留 25 GB 可用空间。
- 模型下载通过 Windows 自带的 `curl.exe` 断点续传。
- 每个 Hugging Face LFS 文件会按官方 SHA-256 校验。
- 下载被中断时，重新运行同一个脚本即可继续。

## 情绪控制

LingChat 每次对话会带上中文情绪标签（`emo_id`），服务端按启动环境变量 `INDEXTTS_EMO_MODE` 映射：

- `qwen`（默认）：标签扩写成情绪描述，交给官方 Qwen3-0.6B 情感模型理解出向量（结果缓存，命中零开销）。
- `blend`：标签查表手工混合向量（快，无额外推理）。
- `auto`：不看标签，Qwen 直接分析本句文本情绪。

也支持请求直接传 `vec1`~`vec8` 原始向量（优先级最高）。

## AMD 适配补丁清单（安装时自动应用）

1. `runtime\Lib\site-packages\transformers\modeling_utils.py`：`import torch.distributed.tensor` 加 try/except（TheRock Windows 版无分布式 C 后端）。
2. `runtime\Lib\site-packages\audiotools\ml\decorators.py`：`dist.ReduceOp.AVG` 默认值加保护（同上原因，仅影响训练 DDP 路径）。
3. `repo\indextts\infer_v2.py` 与 `infer_v2_5.py`：保存音频由 `torchaudio.save`（2.11 起依赖 torchcodec）改为 `soundfile` 写 16-bit PCM；另有性能补丁（BigVGAN FP16、`diffusion_steps`/`inference_cfg_rate` 可调、`num_beams=1` 时不传 length_penalty）。

补丁脚本为 `scripts/Apply-AmdCompatPatches.py` 与 `scripts/Apply-RepoAmdCompat.py`，幂等，可按需重复执行。

## 音色隐私

本仓库不会提供、上传或收集任何私人参考音频。请只上传你拥有授权的 WAV、MP3、FLAC、M4A 或 OGG 文件。音色文件保存在本机 LingChat 数据目录中。

## 常见问题

### LingChat 提示 TTS 断开 / 没有声音

1. 确认服务器已启动：浏览器打开 `http://127.0.0.1:9880/health`。
2. 确认 LingChat 全局设置 `tts.indextts_api_url` 是**完整地址**（含 `/voice/indextts/presets`），端口与服务器一致。
3. 打开服务器目录看 `server.log` 的报错。

### 启动闪退或报错

运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Verify-Installation.ps1
```

重点检查：

- `runtime\python.exe` 是否存在；
- `torch.cuda.is_available()` 是否为 `True`；
- `checkpoints-2.5\gpt.pth`、`s2mel.pth`、`config.yaml` 是否完整；
- `voices` 目录是否至少有一个音色文件。

### 模型下载失败

保留 `.part` 文件并重新运行，脚本会断点续传。GitHub 源码快照偶发 429 限流，稍后重试即可。若网络无法访问 Hugging Face，可以稍后重试；不要从不明网盘获取被修改过的权重。

### 为什么不把模型放到 GitHub Release

官方模型本身超过 5 GB，并受 IndexTTS 独立模型协议约束。本安装器直接下载官方版本、记录具体提交号并验证哈希，能避免二次分发和来源不明。

### 旧版内嵌（0.4.x）安装怎么办

内嵌版已停止维护。新版安装器会把独立服务器装到 `bin\data\third_party\IndexTTS-AMD\`，不再使用旧的 `bin\engine\` 目录；确认新服务器可用后，旧目录可以手动删除。

## 许可证

本仓库中的安装脚本与服务端脚本采用 MIT License。IndexTTS2/2.5、模型权重、Python、PyTorch 与 AMD ROCm 均使用各自的许可证；详见 THIRD_PARTY_NOTICES.md。
