# -*- coding: utf-8 -*-
"""
AMD ROCm 适配补丁：index-tts 上游源码部分（幂等）。

对上游 index-tts（锁定提交 4f8792ff120cd3ea470dd511e997a17c86cddd10）的
indextts/infer_v2.py 与 indextts/infer_v2_5.py 做两组修改：

1. 保存音频由 torchaudio.save（torchaudio 2.11 起依赖 torchcodec，
   Windows ROCm 版不可用）改为 soundfile 写 16-bit PCM。
2. 性能补丁：新增 use_vocoder_fp16（BigVGAN 半精度）、
   diffusion_steps / inference_cfg_rate 变为可调参数、
   num_beams=1 时不再传 length_penalty。

补丁按精确字符串匹配，上游提交锁定所以锚点稳定；匹配不到会报错而非静默跳过。
已打补丁的文件会自动跳过（幂等），重复执行安全。

用法：
    python scripts\\Apply-RepoAmdCompat.py <repo 目录>   # 目录下应有 indextts\\infer_v2*.py
"""
import os
import sys

# ---- 两个文件共用的补丁对 ----

_SIG_V2 = (
    "            use_qwen_emo=True, aux_paths=None\n"
    "    ):",
    "            use_qwen_emo=True, aux_paths=None, use_vocoder_fp16=False\n"
    "    ):",
)

_SIG_V25 = (
    "            use_cuda_kernel=None,use_deepspeed=False, use_accel=False, use_torch_compile=False, use_qwen_emo=False\n"
    "    ):",
    "            use_cuda_kernel=None,use_deepspeed=False, use_accel=False, use_torch_compile=False, use_qwen_emo=False,\n"
    "            use_vocoder_fp16=False\n"
    "    ):",
)

_DTYPE_V2 = (
    "        self.dtype = torch.float16 if self.use_fp16 else None\n"
    "        self.stop_mel_token",
    "        self.dtype = torch.float16 if self.use_fp16 else None\n"
    "        self.use_vocoder_fp16 = use_vocoder_fp16 and str(self.device).startswith(\"cuda\")\n"
    "        self.stop_mel_token",
)

_DTYPE_V25 = (
    "        self.dtype = torch.bfloat16 if self.use_bf16 else None\n"
    "        self.stop_mel_token",
    "        self.dtype = torch.bfloat16 if self.use_bf16 else None\n"
    "        self.use_vocoder_fp16 = use_vocoder_fp16 and str(self.device).startswith(\"cuda\")\n"
    "        self.stop_mel_token",
)

_BIGVGAN_HALF = (
    "        self.bigvgan.remove_weight_norm()\n"
    "        self.bigvgan.eval()",
    "        self.bigvgan.remove_weight_norm()\n"
    "        if self.use_vocoder_fp16:\n"
    "            self.bigvgan = self.bigvgan.half()\n"
    "            print(\">> BigVGAN vocoder using FP16\")\n"
    "        self.bigvgan.eval()",
)

_DIFFUSION_PARAMS = (
    "        max_mel_tokens = generation_kwargs.pop(\"max_mel_tokens\", 1500)\n"
    "        sampling_rate = 22050",
    "        max_mel_tokens = generation_kwargs.pop(\"max_mel_tokens\", 1500)\n"
    "        diffusion_steps = max(1, int(generation_kwargs.pop(\"diffusion_steps\", 25)))\n"
    "        inference_cfg_rate = float(generation_kwargs.pop(\"inference_cfg_rate\", 0.7))\n"
    "        sampling_rate = 22050",
)

_BEAM_KWARGS = (
    "        has_warned = False\n"
    "        silence = None # for stream_return",
    "        has_warned = False\n"
    "        beam_kwargs = {\"length_penalty\": length_penalty} if num_beams > 1 else {}\n"
    "        silence = None # for stream_return",
)

_LENGTH_PENALTY = (
    "                        num_return_sequences=autoregressive_batch_size,\n"
    "                        length_penalty=length_penalty,\n"
    "                        num_beams=num_beams,\n"
    "                        repetition_penalty=repetition_penalty,\n"
    "                        max_generate_length=max_mel_tokens,\n"
    "                        **generation_kwargs",
    "                        num_return_sequences=autoregressive_batch_size,\n"
    "                        num_beams=num_beams,\n"
    "                        repetition_penalty=repetition_penalty,\n"
    "                        max_generate_length=max_mel_tokens,\n"
    "                        **beam_kwargs,\n"
    "                        **generation_kwargs",
)

_VOCODER_INPUT = (
    "                    wav = self.bigvgan(vc_target.float()).squeeze().unsqueeze(0)",
    "                    vocoder_input = vc_target.half() if self.use_vocoder_fp16 else vc_target.float()\n"
    "                    wav = self.bigvgan(vocoder_input).squeeze().unsqueeze(0)",
)

_SAVEFILE_SAVE = (
    "            torchaudio.save(output_path, wav.type(torch.int16), sampling_rate)",
    "            # AMD ROCm 适配补丁：torchaudio 2.11 的 save 依赖 torchcodec，\n"
    "            # 改用 soundfile 直接写 16-bit PCM wav（wav 已是 int16 量程，行为等价）\n"
    "            import soundfile as sf\n"
    "            wav_np = wav.squeeze(0).numpy().astype(\"int16\")\n"
    "            sf.write(output_path, wav_np, sampling_rate, subtype=\"PCM_16\")",
)

# ---- infer_v2.py 专有 ----

_V2_DROP_HARDCODED = (
    "                    diffusion_steps = 25\n"
    "                    inference_cfg_rate = 0.7\n"
    "                    latent = self.s2mel.models['gpt_layer'](latent)",
    "                    latent = self.s2mel.models['gpt_layer'](latent)",
)

# ---- infer_v2_5.py 专有 ----

_V25_STREAM_SAVE = (
    "                    torchaudio.save(output_path, wav, sampling_rate)",
    "                    # AMD ROCm 适配补丁：torchaudio 2.11 的 save 依赖 torchcodec，\n"
    "                    # 改用 soundfile 直接写 16-bit PCM wav（wav 已是 int16 量程，行为等价）\n"
    "                    import soundfile as sf\n"
    "                    sf.write(output_path, wav.squeeze(0).numpy().astype(\"int16\"), sampling_rate, subtype=\"PCM_16\")",
)

_V25_DROP_HARDCODED = (
    "                    diffusion_steps = 25\n"
    "                    inference_cfg_rate = 0.7\n"
    "                    S_infer = self.semantic_codec.decode(codes)",
    "                    S_infer = self.semantic_codec.decode(codes)",
)

PAIRS = {
    "infer_v2.py": [
        _SIG_V2,
        _DTYPE_V2,
        _BIGVGAN_HALF,
        _DIFFUSION_PARAMS,
        _BEAM_KWARGS,
        _LENGTH_PENALTY,
        _V2_DROP_HARDCODED,
        _VOCODER_INPUT,
        _SAVEFILE_SAVE,
    ],
    "infer_v2_5.py": [
        _SIG_V25,
        _DTYPE_V25,
        _BIGVGAN_HALF,
        _V25_STREAM_SAVE,
        _DIFFUSION_PARAMS,
        _BEAM_KWARGS,
        _LENGTH_PENALTY,
        _V25_DROP_HARDCODED,
        _VOCODER_INPUT,
        _SAVEFILE_SAVE,
    ],
}


def apply_pairs(path, pairs):
    with open(path, "r", encoding="utf-8", newline="") as f:
        content = f.read()
    # 统一为 LF 匹配（git 工作区可能迁出为 CRLF），写回一律 LF
    content = content.replace("\r\n", "\n")
    changed = False
    for index, pair in enumerate(pairs, start=1):
        old, new = pair
        if old in content:
            content = content.replace(old, new, 1)
            changed = True
            continue
        if new in content:
            print(f"[skip] {os.path.basename(path)} 第 {index} 处已是补丁后内容")
            continue
        raise RuntimeError(
            f"补丁锚点未找到：{path} 第 {index} 处。"
            "上游源码可能不是锁定的提交。"
        )
    if changed:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
    print(f"[ok] {path}")
    return changed


def main():
    if len(sys.argv) != 2:
        raise SystemExit("用法：python Apply-RepoAmdCompat.py <repo 目录>")
    repo_dir = os.path.abspath(sys.argv[1])
    for name, pairs in PAIRS.items():
        path = os.path.join(repo_dir, "indextts", name)
        if not os.path.isfile(path):
            raise RuntimeError(f"目标文件不存在：{path}（请先拉取上游源码）")
        apply_pairs(path, pairs)
    print("AMD 上游源码兼容补丁完成。")


if __name__ == "__main__":
    main()
