# local_voices.py - Voces locales de Jarvis: gratis, sin internet y con acento de España.
#   piper:<modelo>[#<hablante>]   Piper (rhasspy/piper-voices, es_ES)
#   kokoro:<voz>                  Kokoro en ONNX (kokoro-onnx)
# Los modelos los descarga install.ps1 en <datos>\voices. También registra la voz como backend
# "pctoolkit_local" de OpenJarvis para que "jarvis chat --voice" (chat.py) hable igual.

from __future__ import annotations

import io
import wave
from pathlib import Path

DEFAULT_LOCAL_VOICE = "piper:es_ES-davefx-medium"
_cache: dict = {}


def is_local(voice_id: str) -> bool:
    return voice_id.startswith(("piper:", "kokoro:"))


def synthesize(voice_id: str, text: str, voices_dir: Path, speed: float = 1.0):
    """Devuelve (audio float32 mono, frecuencia)."""
    import numpy as np

    engine, _, name = voice_id.partition(":")
    if engine == "piper":
        from piper import PiperVoice, SynthesisConfig
        model, _, speaker = name.partition("#")
        key = ("piper", model)
        if key not in _cache:
            _cache[key] = PiperVoice.load(str(voices_dir / "piper" / f"{model}.onnx"))
        voice = _cache[key]
        cfg = SynthesisConfig(speaker_id=int(speaker) if speaker else None, length_scale=1.0 / max(0.5, speed))
        chunks = [c.audio_int16_array for c in voice.synthesize(text, syn_config=cfg)]
        audio = np.concatenate(chunks).astype("float32") / 32768.0 if chunks else np.zeros(1, "float32")
        return audio, voice.config.sample_rate
    if engine == "kokoro":
        from kokoro_onnx import Kokoro
        if "kokoro" not in _cache:
            folder = voices_dir / "kokoro"
            _cache["kokoro"] = Kokoro(str(folder / "kokoro-v1.0.onnx"), str(folder / "voices-v1.0.bin"))
        audio, sr = _cache["kokoro"].create(text, voice=name, speed=speed, lang="es")
        return audio.astype("float32"), sr
    raise ValueError(f"Voz local desconocida: {voice_id}")


def to_wav(audio, sr: int) -> bytes:
    import numpy as np
    pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm)
    return buf.getvalue()


def register_openjarvis_backend(voices_dir: Path) -> None:
    """Backend de TTS "pctoolkit_local" para OpenJarvis (lo usa el chat de voz)."""
    from openjarvis.core.registry import TTSRegistry
    from openjarvis.speech.tts import TTSBackend, TTSResult

    if TTSRegistry.contains("pctoolkit_local"):
        return

    class LocalTTS(TTSBackend):
        backend_id = "pctoolkit_local"

        def synthesize(self, text, *, voice_id="", speed=1.0, output_format="wav"):
            voice = voice_id if is_local(voice_id) else DEFAULT_LOCAL_VOICE
            audio, sr = synthesize(voice, text, voices_dir, speed)
            return TTSResult(audio=to_wav(audio, sr), format="wav", voice_id=voice, sample_rate=sr,
                             metadata={"backend": "pctoolkit_local"})

        def available_voices(self):
            return [DEFAULT_LOCAL_VOICE]

        def health(self):
            return True

    TTSRegistry.register("pctoolkit_local")(LocalTTS)
