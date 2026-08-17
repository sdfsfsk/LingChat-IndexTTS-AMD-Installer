# 第三方组件说明

本仓库只对自身编写的安装脚本与服务端脚本授予 MIT License，不改变任何第三方项目的许可证。

## IndexTTS（index-tts）

- 源码：<https://github.com/index-tts/index-tts>
- IndexTTS-2.5 模型：<https://huggingface.co/IndexTeam/IndexTTS-2.5>
- 旧版 IndexTTS-2 模型：<https://huggingface.co/IndexTeam/IndexTTS-2>
- 许可证：以官方源码仓库和模型仓库中的最新许可证文件为准。

安装器不会把 index-tts 源码或权重提交到 GitHub：安装时从官方仓库下载锁定提交的源码快照，并在本机应用 AMD 适配补丁（见 `scripts/Apply-*.py`）；模型则从官方模型仓库下载。下载模型即表示使用者自行阅读并接受其适用协议。

## AMD ROCm 与 PyTorch

- Windows 安装文档：<https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/install/installryz/windows/install-pytorch.html>
- ROCm wheel 索引：<https://repo.amd.com/rocm/whl/>

脚本从 AMD 官方 wheel 索引安装面向所选 GPU 架构的 PyTorch/ROCm 包。相关二进制、商标与许可证归各自权利人所有。

## Python

- 官网：<https://www.python.org/>
- Python 3.10.11 嵌入式包：<https://www.python.org/ftp/python/3.10.11/>

脚本从 Python 官方站点下载嵌入式包，并按固定 SHA-256 校验。

## PyPI 依赖

其余 Python 依赖（fastapi、uvicorn、tiktoken、openai-whisper、fugashi、unidic-lite、transformers 等，见 `requirements-runtime.txt` 与安装脚本）均从 PyPI 官方索引按锁定版本安装，各自使用其原始许可证。

## 用户音色

本仓库不附带任何角色、游戏、动画或真人音色。使用者必须确保参考音频的采集、训练、克隆和发布行为符合当地法律以及音频权利人的许可。
