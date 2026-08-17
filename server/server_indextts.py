# -*- coding: utf-8 -*-
"""
IndexTTS2 FastAPI 服务（AMD ROCm 原生版）

实现 LingChat Rust 后端内置 indextts2 适配器的契约：
  GET /voice/indextts/presets?id=&emo_control_method=&emo_id=&vec1..vec8=&
      emo_weight=&stream=&max_text_tokens_per_segment=&quick_token=&lang=&
      audio_format=&_verify=&text=
  返回 wav 音频字节流（audio/wav）

适配器源码：LingChat-tauri-source-rust/src-tauri/src/ai_service/tts/adapters/indextts.rs
"""
import os
import sys
import re
import time
import io
import json
import inspect
import logging
import threading
import traceback

ROOT = os.path.dirname(os.path.abspath(__file__))
# 以源码方式使用仓库内的 indextts 包（不做 pip install，避免覆盖 ROCm 版 torch）
sys.path.insert(0, os.path.join(ROOT, "repo"))

# 关键日志同时写控制台与 server.log（UTF-8 追加）
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.FileHandler(os.path.join(ROOT, "server.log"), encoding="utf-8", mode="a"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("indextts-server")

# 模型版本（INDEXTTS_VERSION）：
#   2.5 —— 默认，IndexTTS-2.5（checkpoints-2.5/，BF16，中日英等多语言，新增 lang 参数）
#   2   —— 旧版 IndexTTS-2（checkpoints/，FP16，仅中英文）
MODEL_VERSION = os.environ.get("INDEXTTS_VERSION", "2.5").strip()
if MODEL_VERSION not in {"2", "2.5"}:
    raise RuntimeError("INDEXTTS_VERSION 仅支持 2.5 或 2")
IS_V25 = MODEL_VERSION == "2.5"
DEFAULT_CHECKPOINTS = os.path.join(ROOT, "checkpoints-2.5" if IS_V25 else "checkpoints")
CHECKPOINTS = os.path.abspath(os.environ.get("INDEXTTS_CHECKPOINTS", DEFAULT_CHECKPOINTS))
VOICES_DIR = os.path.join(ROOT, "voices")
OUTPUTS_DIR = os.path.join(ROOT, "outputs")
CONFIG_YAML = os.path.join(CHECKPOINTS, "config.yaml")
PORT = int(os.environ.get("INDEXTTS_PORT", "23987"))
if not 1 <= PORT <= 65535:
    raise RuntimeError("INDEXTTS_PORT 必须在 1 到 65535 之间")
USE_FP16 = os.environ.get("INDEXTTS_FP16", "0") == "1"
USE_BF16 = os.environ.get("INDEXTTS_BF16", "1") == "1"  # IndexTTS-2.5 官方推荐 BF16
USE_VOCODER_FP16 = os.environ.get("INDEXTTS_VOCODER_FP16", "1") == "1"
NUM_BEAMS = max(1, int(os.environ.get("INDEXTTS_NUM_BEAMS", "1")))
DIFFUSION_STEPS = max(1, int(os.environ.get("INDEXTTS_DIFFUSION_STEPS", "16")))
INFERENCE_CFG_RATE = float(os.environ.get("INDEXTTS_INFERENCE_CFG_RATE", "0.7"))
QWEN_CACHE_PATH = os.path.join(ROOT, "qwen_emo_cache.json")

os.makedirs(VOICES_DIR, exist_ok=True)
os.makedirs(OUTPUTS_DIR, exist_ok=True)

from fastapi import FastAPI, Query, Response
from fastapi.responses import JSONResponse
import uvicorn
import soundfile as sf

_gpu_lock = threading.Lock()

# IndexTTS2 情绪向量维度顺序（见 repo/indextts/infer_v2.py QwenEmotion.desired_vector_order）
# [高兴 happy, 愤怒 angry, 悲伤 sad, 恐惧 afraid, 反感 disgusted, 低落 melancholic, 惊讶 surprised, 自然 calm]
# 覆盖 LingChat 19 情绪标签（prompt.rs）：慌张、担心、尴尬、紧张、高兴、自信、害怕、害羞、
# 认真、生气、无语、厌恶、疑惑、难为情、惊讶、情动、哭泣、调皮、平静
#
# 自然化设计：真实说话的情绪是"混合且含蓄"的，不用 one-hot（单维 1.0 会显得端着/夸张）。
# 每个标签 = 主情绪 0.45~0.7 + 1~2 个辅助情绪 0.05~0.25，经官方 bias 与 emo_weight(0.6)
# 缩放后听感更接近人话。想整体更淡/更浓：调启动环境变量 INDEXTTS_EMO_SCALE（默认 1.0）。
def _v(happy=0.0, angry=0.0, sad=0.0, afraid=0.0, disgusted=0.0, melancholic=0.0,
       surprised=0.0, calm=0.0):
    return [happy, angry, sad, afraid, disgusted, melancholic, surprised, calm]


EMO_LABEL_TO_VEC = {
    # --- 喜悦系 ---
    "高兴": _v(happy=0.65, surprised=0.1), "开心": _v(happy=0.65, surprised=0.1),
    "喜悦": _v(happy=0.65, surprised=0.1), "快乐": _v(happy=0.65, surprised=0.1),
    "愉快": _v(happy=0.6, calm=0.1), "幸福": _v(happy=0.6, calm=0.15),
    "兴奋": _v(happy=0.7, surprised=0.15), "期待": _v(happy=0.55, surprised=0.1),
    "调皮": _v(happy=0.55, surprised=0.15, calm=0.05),
    "情动": _v(happy=0.5, calm=0.15, melancholic=0.05),
    # --- 愤怒系 ---
    "生气": _v(angry=0.65, disgusted=0.15), "愤怒": _v(angry=0.7, disgusted=0.1),
    "恼火": _v(angry=0.6, disgusted=0.15), "气愤": _v(angry=0.65, disgusted=0.1),
    "暴怒": _v(angry=0.75, surprised=0.05),
    # --- 悲伤系 ---
    "难过": _v(sad=0.6, melancholic=0.2), "悲伤": _v(sad=0.65, melancholic=0.15),
    "伤心": _v(sad=0.65, melancholic=0.15), "哭泣": _v(sad=0.7, melancholic=0.15),
    "委屈": _v(sad=0.55, melancholic=0.2, afraid=0.05), "伤感": _v(sad=0.55, melancholic=0.25),
    "低落": _v(melancholic=0.6, sad=0.15), "忧郁": _v(melancholic=0.65, sad=0.1),
    "沮丧": _v(melancholic=0.6, sad=0.15), "失落": _v(melancholic=0.6, sad=0.15),
    "消沉": _v(melancholic=0.65, sad=0.1),
    # --- 恐惧系 ---
    "害怕": _v(afraid=0.65, surprised=0.15), "恐惧": _v(afraid=0.7, surprised=0.1),
    "紧张": _v(afraid=0.5, surprised=0.15, calm=0.1), "不安": _v(afraid=0.5, melancholic=0.15),
    "慌张": _v(afraid=0.55, surprised=0.25), "惊慌": _v(afraid=0.6, surprised=0.25),
    "担心": _v(afraid=0.45, melancholic=0.2),
    # --- 厌恶系 ---
    "厌恶": _v(disgusted=0.65, angry=0.1), "反感": _v(disgusted=0.65, angry=0.1),
    "恶心": _v(disgusted=0.7, angry=0.05), "嫌弃": _v(disgusted=0.6, angry=0.1),
    "讨厌": _v(disgusted=0.55, angry=0.15),
    # --- 惊讶系 ---
    "惊讶": _v(surprised=0.65, happy=0.05), "吃惊": _v(surprised=0.65, happy=0.05),
    "震惊": _v(surprised=0.7, afraid=0.1), "诧异": _v(surprised=0.6, afraid=0.05),
    "意外": _v(surprised=0.6, happy=0.05),
    # --- 平静/含蓄系（多以自然为主，掺一点辅助色）---
    "平静": _v(calm=0.6), "自然": _v(calm=0.6), "正常": _v(calm=0.6),
    "冷静": _v(calm=0.65), "淡定": _v(calm=0.6, happy=0.05),
    "无语": _v(calm=0.5, melancholic=0.1), "无奈": _v(calm=0.5, melancholic=0.15),
    "尴尬": _v(calm=0.45, happy=0.15, afraid=0.1),
    "自信": _v(calm=0.55, happy=0.2),
    "害羞": _v(calm=0.45, happy=0.2, afraid=0.1),
    "难为情": _v(calm=0.45, happy=0.15, afraid=0.1),
    "认真": _v(calm=0.6),
    "疑惑": _v(calm=0.45, surprised=0.2),
}

# 旧接口兼容（不再使用）：标签 -> 维度序号
EMO_LABEL_TO_INDEX = {}

# 情绪整体强度缩放（1.0 = 不改；0.8 更含蓄，1.2 更浓）
EMO_SCALE = float(os.environ.get("INDEXTTS_EMO_SCALE", "1.0"))

# 情绪模式（INDEXTTS_EMO_MODE）：
#   blend —— 默认，上表手工调配的混合向量（快，无额外推理）
#   qwen  —— 标签扩写成情绪描述，交给官方 Qwen3-0.6B 情感模型自动理解出向量（更细腻，+0.1~0.5s）
#   auto  —— 不看标签，直接让 Qwen 分析本句文本的情绪（情绪跟随内容，+0.1~0.5s）
EMO_MODE = os.environ.get("INDEXTTS_EMO_MODE", "blend").lower()
if EMO_MODE not in {"blend", "qwen", "auto"}:
    raise RuntimeError("INDEXTTS_EMO_MODE 仅支持 blend、qwen 或 auto")

SUPPORTED_LANGS_V25 = {"zh", "en", "ja", "es", "ar"}
SUPPORTED_LANGS_V2 = {"zh", "en"}

# qwen 模式：19 情绪标签 -> 自然语言情绪描述（未列出的同义词直接用标签原文）
LABEL_EMO_TEXT = {
    "高兴": "开心愉快，语气轻快",
    "调皮": "俏皮调侃，带着笑意",
    "情动": "温柔动情，略带羞怯",
    "生气": "生气恼火，语气激动",
    "哭泣": "委屈地哭着，带着哭腔",
    "害怕": "害怕不安，声音发紧",
    "紧张": "紧张局促，声音发紧",
    "慌张": "慌张失措，语速偏快",
    "担心": "担心忧虑，语气放轻",
    "尴尬": "尴尬窘迫，支支吾吾",
    "自信": "自信从容，语气坚定",
    "害羞": "害羞腼腆，声音变软",
    "认真": "认真专注，语气平稳",
    "无语": "无奈无语，语气平淡",
    "厌恶": "厌恶嫌弃，语气冷淡",
    "疑惑": "疑惑不解，带着疑问",
    "难为情": "难为情，不好意思，声音发虚",
    "惊讶": "惊讶诧异，音调抬高",
    "平静": "平静自然，语气舒缓",
}

# Qwen 情绪向量缓存：同一描述/文本只需推理一次，并持久化到磁盘供下次启动复用。
def _load_qwen_cache():
    try:
        with open(QWEN_CACHE_PATH, "r", encoding="utf-8") as f:
            raw = json.load(f)
        return {
            str(key): [float(value) for value in values]
            for key, values in raw.items()
            if isinstance(values, list) and len(values) == 8
        }
    except (OSError, ValueError, TypeError):
        return {}


def _save_qwen_cache():
    tmp_path = QWEN_CACHE_PATH + ".tmp"
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(_qwen_vec_cache, f, ensure_ascii=False, indent=2)
        os.replace(tmp_path, QWEN_CACHE_PATH)
    except OSError as exc:
        log.warning(f">> [server] 保存 Qwen 情绪缓存失败: {exc}")


_qwen_vec_cache = _load_qwen_cache()


def qwen_emo_vector(key: str):
    """按描述文本缓存 Qwen 情感模型的输出向量（与 infer(use_emo_text=True) 行为一致）。"""
    vec = _qwen_vec_cache.get(key)
    if vec is None:
        # Qwen 与主 TTS 共用同一块 GPU；缓存未命中时必须串行，避免并发抢占拖慢整批语音。
        with _gpu_lock:
            vec = _qwen_vec_cache.get(key)
            if vec is None:
                emo_dict = tts.qwen_emo.inference(key)
                vec = list(emo_dict.values())
                _qwen_vec_cache[key] = vec
                _save_qwen_cache()
                log.info(f">> [server] Qwen 情绪向量已缓存: '{key[:24]}' -> "
                         f"{[round(v, 3) for v in vec]}")
    else:
        vec = list(vec)
    return vec

log.info(f">> [server] 正在加载 IndexTTS-{MODEL_VERSION} 模型（AMD ROCm 原生模式）...")
_load_t0 = time.perf_counter()
if IS_V25:
    from indextts.infer_v2_5 import IndexTTS2  # noqa: E402
else:
    from indextts.infer_v2 import IndexTTS2  # noqa: E402

# 安装器会为 AMD 性能参数打补丁；直接复制本服务端到官方仓库时则自动回退
# 到上游默认推理参数，避免 use_vocoder_fp16 或 diffusion_steps 导致启动/推理失败。
SUPPORTS_AMD_TUNING = "use_vocoder_fp16" in inspect.signature(IndexTTS2.__init__).parameters

# use_cuda_kernel=False：Windows ROCm 无法编译 BigVGAN 的 CUDA 核，走 torch 原生回退
# use_deepspeed / use_accel / use_torch_compile：均为 NVIDIA/编译链路专用，全部关闭
_common_kwargs = dict(
    cfg_path=CONFIG_YAML,
    model_dir=CHECKPOINTS,
    use_cuda_kernel=False,
    use_deepspeed=False,
    use_accel=False,
    use_torch_compile=False,
)
if SUPPORTS_AMD_TUNING:
    _common_kwargs["use_vocoder_fp16"] = USE_VOCODER_FP16
if IS_V25:
    # 2.5 用 BF16；仅 qwen/auto 情绪模式才加载 Qwen3-0.6B（省约 1.1GB 显存）
    tts = IndexTTS2(use_bf16=USE_BF16, use_qwen_emo=EMO_MODE in ("qwen", "auto"), **_common_kwargs)
else:
    tts = IndexTTS2(use_fp16=USE_FP16, **_common_kwargs)
log.info(f">> [server] 模型加载完成，耗时 {time.perf_counter() - _load_t0:.1f}s，设备: {tts.device}")

app = FastAPI(title="IndexTTS2 AMD Server for LingChat")


def list_presets():
    """voices/ 目录里的 wav 文件即音色预设，按文件名排序，序号即预设 id。"""
    files = [f for f in sorted(os.listdir(VOICES_DIR)) if f.lower().endswith((".wav", ".mp3", ".flac", ".ogg"))]
    return [os.path.join(VOICES_DIR, f) for f in files]


def resolve_emo_vector(emo_id: str, vecs):
    """按优先级决定情绪向量：显式 vec1-8 > emo_id 中文标签 > None（跟随音色参考）。"""
    if any(abs(v) > 1e-6 for v in vecs):
        vec = tts.normalize_emo_vec(list(vecs), apply_bias=True)
        return vec, f"raw:{vecs}"
    label = (emo_id or "").strip()
    label = re.sub(r"[【】\[\]\s]", "", label)
    if label and label in EMO_LABEL_TO_VEC:
        vec = list(EMO_LABEL_TO_VEC[label])
        if EMO_SCALE != 1.0:
            vec = [v * EMO_SCALE for v in vec]
        vec = tts.normalize_emo_vec(vec, apply_bias=True)
        return vec, f"label:{label}"
    if label:
        log.warning(f">> [server] 未识别的情绪标签 '{label}'，回退为跟随音色参考")
    return None, "none"


@app.get("/health")
def health():
    return {
        "status": "ok",
        "model_version": MODEL_VERSION,
        "device": str(tts.device),
        "checkpoints": os.path.basename(os.path.normpath(CHECKPOINTS)),
        "emotion_mode": EMO_MODE,
        "amd_tuning": SUPPORTS_AMD_TUNING,
        "presets": [os.path.basename(p) for p in list_presets()],
    }


@app.get("/voice/indextts/presets")
def voice_presets(
    id: int = Query(0),
    emo_control_method: str = Query("1"),
    emo_id: str = Query(""),
    vec1: float = Query(0.0), vec2: float = Query(0.0), vec3: float = Query(0.0),
    vec4: float = Query(0.0), vec5: float = Query(0.0), vec6: float = Query(0.0),
    vec7: float = Query(0.0), vec8: float = Query(0.0),
    emo_weight: float = Query(0.6),
    stream: str = Query("False"),
    max_text_tokens_per_segment: int = Query(120),
    quick_token: str = Query("0"),
    lang: str = Query("zh"),
    audio_format: str = Query("wav"),
    _verify: str = Query("0"),
    text: str = Query(""),
):
    text = (text or "").strip()
    if not text:
        return JSONResponse(status_code=400, content={"error": "text 参数为空"})

    presets = list_presets()
    if not presets:
        return JSONResponse(status_code=500, content={"error": "voices/ 目录下没有音色预设 wav"})
    if not 0 <= id < len(presets):
        return JSONResponse(
            status_code=400,
            content={"error": f"音色 id 超出范围：{id}，可用范围为 0..{len(presets) - 1}"},
        )
    spk = presets[id]

    request_lang = (lang or "zh").strip().lower()
    supported_langs = SUPPORTED_LANGS_V25 if IS_V25 else SUPPORTED_LANGS_V2
    if request_lang not in supported_langs:
        return JSONResponse(
            status_code=400,
            content={"error": f"IndexTTS-{MODEL_VERSION} 不支持语言 '{request_lang}'，可用值：{sorted(supported_langs)}"},
        )
    if (audio_format or "wav").strip().lower() != "wav":
        return JSONResponse(status_code=400, content={"error": "当前服务端仅支持 audio_format=wav"})

    emo_alpha = max(0.0, min(1.0, emo_weight))
    label = re.sub(r"[【】\[\]\s]", "", (emo_id or "").strip())
    raw_vecs = [vec1, vec2, vec3, vec4, vec5, vec6, vec7, vec8]

    infer_kwargs = {}
    if any(abs(v) > 1e-6 for v in raw_vecs) or EMO_MODE == "blend":
        # 显式向量 或 blend 模式：走手工混合向量
        emo_vector, emo_desc = resolve_emo_vector(emo_id, raw_vecs)
        infer_kwargs.update(emo_vector=emo_vector, use_emo_text=False)
    elif EMO_MODE == "qwen" and label:
        # qwen 模式：标签扩写成情绪描述，Qwen3-0.6B 自动理解出向量（结果缓存，命中零开销）
        emo_text = LABEL_EMO_TEXT.get(label, label)
        cached = emo_text in _qwen_vec_cache
        vec = qwen_emo_vector(emo_text)
        emo_desc = f"qwen:{emo_text}{'(cache)' if cached else ''}"
        infer_kwargs.update(emo_vector=vec, use_emo_text=False)
    elif EMO_MODE == "auto":
        # auto 模式：不看标签，Qwen 直接分析本句文本情绪（同样走缓存）
        cached = text in _qwen_vec_cache
        vec = qwen_emo_vector(text)
        emo_desc = f"qwen:auto{'(cache)' if cached else ''}"
        infer_kwargs.update(emo_vector=vec, use_emo_text=False)
    else:
        # 无标签：跟随音色参考
        emo_desc = "none"
        infer_kwargs.update(emo_vector=None, use_emo_text=False)

    request_t0 = time.perf_counter()
    try:
        queue_t0 = time.perf_counter()
        with _gpu_lock:
            queue_seconds = time.perf_counter() - queue_t0
            infer_t0 = time.perf_counter()
            infer_call = dict(
                spk_audio_prompt=spk,
                text=text,
                output_path=None,
                emo_alpha=emo_alpha,
                use_random=False,
                interval_silence=200,
                max_text_tokens_per_segment=int(max_text_tokens_per_segment),
                **infer_kwargs,
            )
            if SUPPORTS_AMD_TUNING:
                infer_call.update(
                    num_beams=NUM_BEAMS,
                    diffusion_steps=DIFFUSION_STEPS,
                    inference_cfg_rate=INFERENCE_CFG_RATE,
                )
            if IS_V25:
                infer_call["lang"] = request_lang
            result = tts.infer(**infer_call)
            infer_seconds = time.perf_counter() - infer_t0
        if result is None:
            raise RuntimeError("infer() 未返回音频")
        sampling_rate, wav_data = result
        wav_buffer = io.BytesIO()
        sf.write(wav_buffer, wav_data, sampling_rate, format="WAV", subtype="PCM_16")
        data = wav_buffer.getvalue()
        total_seconds = time.perf_counter() - request_t0
        log.info(f">> [server] 合成完成 id={id} emo={emo_desc} 文本[{text[:30]}] "
                 f"推理 {infer_seconds:.2f}s 排队 {queue_seconds:.2f}s 总计 {total_seconds:.2f}s")
        return Response(content=data, media_type="audio/wav")
    except Exception as e:
        log.exception(">> [server] 合成异常")
        return JSONResponse(status_code=500, content={"error": f"{type(e).__name__}: {e}"})


def main():
    presets = list_presets()
    log.info(f">> [server] 音色预设（id 顺序）: {[os.path.basename(p) for p in presets]}")
    log.info(f">> [server] 情绪模式: {EMO_MODE}（blend=混合向量 / qwen=标签描述→Qwen / auto=全文情绪分析），"
             f"EMO_SCALE={EMO_SCALE}")
    log.info(f">> [server] 加速参数: fp16={USE_FP16}, vocoder_fp16={USE_VOCODER_FP16}, "
             f"num_beams={NUM_BEAMS}, diffusion_steps={DIFFUSION_STEPS}, "
             f"amd_tuning={SUPPORTS_AMD_TUNING}, qwen_cache={len(_qwen_vec_cache)}")
    # 预热一次，避免首个请求过慢
    if presets:
        try:
            with _gpu_lock:
                warmup_call = dict(
                    spk_audio_prompt=presets[0],
                    text="预热。",
                    output_path=None,
                    max_text_tokens_per_segment=50,
                )
                if SUPPORTS_AMD_TUNING:
                    warmup_call.update(
                        num_beams=NUM_BEAMS,
                        diffusion_steps=DIFFUSION_STEPS,
                        inference_cfg_rate=INFERENCE_CFG_RATE,
                    )
                if IS_V25:
                    warmup_call["lang"] = "zh"
                tts.infer(**warmup_call)
            log.info(">> [server] 预热完成")
        except Exception as e:
            log.warning(f">> [server] 预热失败（不影响后续使用）: {e!r}")
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="info")


if __name__ == "__main__":
    main()



