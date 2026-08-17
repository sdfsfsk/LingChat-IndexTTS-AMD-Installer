# -*- coding: utf-8 -*-
"""
AMD ROCm 适配补丁：site-packages 部分（幂等）。

TheRock Windows 版 ROCm PyTorch 没有编译分布式 C 后端
（缺少 torch._C._distributed_c10d / dist.ReduceOp），
以下两个第三方包在 import 或定义默认值时会直接引用它们，需要打补丁：

1. transformers/modeling_utils.py
   顶层 ``import torch.distributed.tensor`` 加 try/except（单卡推理不需要 DTensor/TP）。
2. audiotools/ml/decorators.py
   ``dist.ReduceOp.AVG`` 默认值加保护（仅影响训练 DDP 路径，推理不会执行 all_reduce）。

对应依赖版本由 requirements-runtime.txt 锁定（transformers==4.52.1、
descript-audiotools==0.7.2），补丁按精确字符串匹配；匹配不到会报错而非静默跳过。

用法：由安装好的嵌入式 Python 执行：
    runtime\\python.exe scripts\\Apply-AmdCompatPatches.py [site-packages 目录]
不带参数时自动使用当前解释器旁的 Lib\\site-packages。
"""
import os
import sys

TRANSFORMERS_PAIR = (
    # old
    "import torch\n"
    "import torch.distributed.tensor\n"
    "from huggingface_hub import split_torch_state_dict_into_shards",
    # new
    "import torch\n"
    "\n"
    "try:\n"
    "    import torch.distributed.tensor  # noqa: F401\n"
    "except (ImportError, ModuleNotFoundError):\n"
    "    # TheRock Windows ROCm 版 torch 未编译分布式组件（无 torch._C._distributed_c10d），\n"
    "    # 单卡推理不需要 DTensor/TP，跳过即可。\n"
    "    pass\n"
    "\n"
    "from huggingface_hub import split_torch_state_dict_into_shards",
)

AUDIOTOOLS_PAIRS = [
    (
        "import torch.distributed as dist\n"
        "from rich import box",
        "import torch.distributed as dist\n"
        "\n"
        "try:\n"
        "    _REDUCE_OP_AVG = dist.ReduceOp.AVG\n"
        "except AttributeError:\n"
        "    # TheRock Windows ROCm 版 torch 无分布式 C 后端（无 ReduceOp）。\n"
        "    # 推理路径下 ddp_active 恒为 False，all_reduce 不会执行，仅需让默认值可定义。\n"
        "    _REDUCE_OP_AVG = None\n"
        "from rich import box",
    ),
    (
        "        op: dist.ReduceOp = dist.ReduceOp.AVG,",
        "        op: \"dist.ReduceOp\" = _REDUCE_OP_AVG,",
    ),
]


def apply_pairs(path, pairs):
    with open(path, "r", encoding="utf-8", newline="") as f:
        content = f.read()
    # 统一为 LF 匹配（pip 安装的文件可能带 CRLF），写回一律 LF
    content = content.replace("\r\n", "\n")
    changed = False
    for index, (old, new) in enumerate(pairs, start=1):
        if old in content:
            content = content.replace(old, new, 1)
            changed = True
            continue
        if new in content:
            print(f"[skip] {os.path.basename(path)} 第 {index} 处已是补丁后内容")
            continue
        raise RuntimeError(
            f"补丁锚点未找到：{path} 第 {index} 处。"
            "依赖版本可能与 requirements-runtime.txt 锁定版本不一致。"
        )
    if changed:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
    print(f"[ok] {path}")
    return changed


def main():
    if len(sys.argv) > 1:
        site_packages = os.path.abspath(sys.argv[1])
    else:
        site_packages = os.path.join(os.path.dirname(sys.executable), "Lib", "site-packages")

    targets = [
        (
            os.path.join(site_packages, "transformers", "modeling_utils.py"),
            [TRANSFORMERS_PAIR],
        ),
        (
            os.path.join(site_packages, "audiotools", "ml", "decorators.py"),
            AUDIOTOOLS_PAIRS,
        ),
    ]
    for path, pairs in targets:
        if not os.path.isfile(path):
            raise RuntimeError(f"目标文件不存在：{path}（请先安装 Python 依赖）")
        apply_pairs(path, pairs)
    print("AMD site-packages 兼容补丁完成。")


if __name__ == "__main__":
    main()
