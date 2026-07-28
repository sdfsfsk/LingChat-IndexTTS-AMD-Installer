# 第三方组件说明

本仓库只对自身编写的安装脚本授予 MIT License，不改变任何第三方项目的许可证。

## IndexTTS2

- 源码：<https://github.com/index-tts/index-tts>
- 模型：<https://huggingface.co/IndexTeam/IndexTTS-2>
- 许可证：以官方源码仓库和模型仓库中的最新许可证文件为准。

安装器不会将 IndexTTS2 权重提交到 GitHub，而是从官方模型仓库下载 `IndexTeam/IndexTTS-2`。下载模型即表示使用者自行阅读并接受其适用协议。

## AMD ROCm 与 PyTorch

- Windows 安装文档：<https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/install/installryz/windows/install-pytorch.html>
- ROCm wheel 索引：<https://repo.amd.com/rocm/whl/>

脚本从 AMD 官方 wheel 索引安装面向所选 GPU 架构的 PyTorch/ROCm 包。相关二进制、商标与许可证归各自权利人所有。

## Python

- 官网：<https://www.python.org/>
- Python 3.10.11 文件目录：<https://www.python.org/ftp/python/3.10.11/>

脚本从 Python 官方站点下载并校验 Windows 64 位安装程序的数字签名。

## 用户音色

本仓库不附带任何角色、游戏、动画或真人音色。使用者必须确保参考音频的采集、训练、克隆和发布行为符合当地法律以及音频权利人的许可。
