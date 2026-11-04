# jarvis_voice.py - Asistente de voz de Jarvis (OpenJarvis + Whisper + voz local o ElevenLabs).
#
# Proceso en segundo plano que lanza Jarvis.ps1 con el Python del entorno propio de la herramienta.
# Espera el evento de Windows "PcToolkit.Jarvis.Listen" (lo activa el atajo del gestor) y entonces:
#   escucha el micro hasta que te callas -> lo transcribe con Whisper (en la gráfica si hay NVIDIA) ->
#   se lo pasa al modelo de Ollama con OpenJarvis -> lo lee con la voz elegida (local o ElevenLabs).
# Mientras hablas ya va cargando el modelo de Ollama, por si se había dormido.
# Si el atajo llega mientras habla, se calla. El estado se deja en status.json para el gestor.
#
# Uso:
#   pythonw jarvis_voice.py --data <carpeta de datos> --parent <PID del lanzador>
#   pythonw jarvis_voice.py --data <carpeta de datos> --say "texto"      (probar la voz y salir)

from __future__ import annotations

import argparse
import ctypes
import glob
import io
import json
import logging
import os
import re
import subprocess
import sys
import threading
import time
from ctypes import wintypes
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import local_voices  # noqa: E402

DEFAULT_TTS_MODEL = "eleven_multilingual_v2"
OLLAMA_URL = "http://127.0.0.1:11434"
NUM_CTX = 4096                               # el mismo al precargar y al preguntar: si cambia, Ollama recarga el modelo
HISTORY_TURNS = 4                            # pares pregunta/respuesta que recuerda
HISTORY_MINUTES = 5                          # tras este rato sin hablar, empieza de cero

SYSTEM_PROMPT = (
    "Eres Jarvis, el asistente de voz del ordenador de {user}. Hablas en castellano de España, con un tono "
    "cercano, seguro y con un punto de humor elegante. Tus respuestas se leen en voz alta: sé muy breve (una o "
    "dos frases salvo que te pidan más; a un saludo, responde con un saludo corto), no uses listas, tablas, "
    "emojis, Markdown ni enlaces, y escribe los números y las siglas como se pronuncian. Si no sabes algo o "
    "necesitarías internet, dilo con naturalidad. Fecha y hora actuales: {now}."
)

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.CreateEventW.restype = wintypes.HANDLE
kernel32.CreateEventW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR]
kernel32.CreateMutexW.restype = wintypes.HANDLE
kernel32.CreateMutexW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.WaitForSingleObject.restype = wintypes.DWORD
kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
WAIT_OBJECT_0, WAIT_TIMEOUT, SYNCHRONIZE, ERROR_ALREADY_EXISTS = 0, 0x102, 0x00100000, 183

log = logging.getLogger("jarvis")


# --- Configuración (config.json de la herramienta, la escribe el gestor) ---

class DataBlob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def unprotect(hex_text: str) -> str:
    """Descifra lo que guarda ConvertFrom-SecureString (DPAPI del usuario actual, en hexadecimal)."""
    raw = bytes.fromhex(hex_text)
    buf = ctypes.create_string_buffer(raw, len(raw))
    blob_in, blob_out = DataBlob(len(raw), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))), DataBlob()
    if not ctypes.windll.crypt32.CryptUnprotectData(ctypes.byref(blob_in), None, None, None, None, 0,
                                                    ctypes.byref(blob_out)):
        raise OSError("No se pudo descifrar la clave de ElevenLabs")
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData).decode("utf-16-le")
    finally:
        ctypes.windll.kernel32.LocalFree(blob_out.pbData)


class Settings:
    def __init__(self, data: Path) -> None:
        self.data = data
        self.voices_dir = data / "voices"
        self.path = data / "config.json"
        self.stamp = None
        self.values: dict = {}
        self.failed_voices: set = set()   # voces de ElevenLabs que han fallado (no se reintentan)

    def get(self) -> dict:
        try:
            stamp = self.path.stat().st_mtime_ns
        except OSError:
            stamp = None
        if stamp != self.stamp:
            self.stamp = stamp
            self.failed_voices.clear()   # al cambiar la clave o la voz se vuelve a probar
            try:
                self.values = json.loads(self.path.read_text(encoding="utf-8-sig")) if stamp else {}
            except Exception:
                log.exception("config.json no se puede leer")
                self.values = {}
        return self.values

    def voice(self) -> str:
        return self.get().get("Voice") or local_voices.DEFAULT_LOCAL_VOICE

    def api_key(self) -> str:
        enc = self.get().get("ApiKey") or ""
        if not enc:
            return ""
        try:
            return unprotect(enc).strip()
        except Exception:
            log.exception("Clave de ElevenLabs ilegible")
            return ""


# --- Estado para el gestor (status.json) ---

class Status:
    def __init__(self, data: Path) -> None:
        self.path = data / "status.json"
        self.values = {"State": "starting", "Question": "", "Answer": "", "Error": ""}

    def set(self, state: str, **fields) -> None:
        self.values.update(fields, State=state, Time=time.strftime("%Y-%m-%dT%H:%M:%S"))
        tmp = self.path.with_suffix(".tmp")
        try:
            tmp.write_text(json.dumps(self.values, ensure_ascii=False), encoding="utf-8")
            os.replace(tmp, self.path)
        except OSError:
            pass


# --- Audio ---

def tone(freqs, ms=110, volume=0.18):
    """Pitido corto (al empezar a escuchar o si no se ha entendido nada)."""
    import numpy as np
    import sounddevice as sd
    sr = 24000
    parts = []
    for f in freqs:
        t = np.arange(int(sr * ms / 1000)) / sr
        fade = np.minimum(1, np.minimum(t, t[::-1]) * 80)
        parts.append(np.sin(2 * np.pi * f * t) * fade * volume)
    sd.play(np.concatenate(parts).astype("float32"), sr)
    sd.wait()


class Player:
    """Reproduce audio y permite cortarlo desde otro hilo."""

    def __init__(self) -> None:
        self.stop_flag = threading.Event()
        self.proc: subprocess.Popen | None = None

    def stop(self) -> None:
        self.stop_flag.set()
        try:
            import sounddevice as sd
            sd.stop()
        except Exception:
            pass
        if self.proc and self.proc.poll() is None:
            self.proc.kill()

    def play(self, data, sr: int) -> None:
        import sounddevice as sd
        if self.stop_flag.is_set():
            return
        sd.play(data, sr)
        end = time.time() + len(data) / sr + 1
        while time.time() < end and not self.stop_flag.is_set():
            time.sleep(0.05)
        sd.stop()

    def say_windows(self, text: str) -> None:
        """Último recurso: la voz de Windows (en español si hay alguna instalada)."""
        script = (
            "Add-Type -AssemblyName System.Speech; $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
            "$v = $s.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -like 'es-*' } | Select-Object -First 1; "
            "if ($v) { $s.SelectVoice($v.VoiceInfo.Name) }; $s.Speak([Console]::In.ReadToEnd())"
        )
        self.proc = subprocess.Popen(
            ["powershell.exe", "-NoProfile", "-Command", script], stdin=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        self.proc.communicate(text.encode("utf-8", "ignore"))


def synthesize_elevenlabs(text: str, voice: str, settings: Settings):
    """Voz de ElevenLabs con el backend de OpenJarvis. Devuelve (audio, frecuencia)."""
    import soundfile as sf
    from openjarvis.speech.elevenlabs_tts import ElevenLabsTTSBackend

    key = settings.api_key()
    if not key:
        raise RuntimeError("falta la clave de ElevenLabs")
    tts = ElevenLabsTTSBackend(api_key=key, model=settings.get().get("TtsModel") or DEFAULT_TTS_MODEL, voice_id=voice)
    wav = tts.synthesize(text, voice_id=voice, output_format="wav").audio
    data, sr = sf.read(io.BytesIO(wav), dtype="float32")
    return data, sr


def speak(text: str, settings: Settings, player: Player) -> None:
    """Voz elegida -> si es de ElevenLabs y falla, la local por defecto -> la de Windows."""
    voice = settings.voice()
    candidates = []
    if not local_voices.is_local(voice) and voice not in settings.failed_voices:
        candidates.append(voice)
    candidates.append(voice if local_voices.is_local(voice) else local_voices.DEFAULT_LOCAL_VOICE)
    for v in candidates:
        try:
            t = time.time()
            if local_voices.is_local(v):
                audio, sr = local_voices.synthesize(v, text, settings.voices_dir)
            else:
                audio, sr = synthesize_elevenlabs(text, v, settings)
            log.info("Voz %s: %.1f s", v, time.time() - t)
            player.play(audio, sr)
            return
        except Exception as exc:
            if not local_voices.is_local(v):
                settings.failed_voices.add(v)
                hint = " (las voces de la biblioteca de ElevenLabs necesitan un plan de pago)" if "402" in str(exc) else ""
                log.warning("La voz %s ha fallado: %s%s. Se usa la voz local.", v, exc, hint)
            else:
                log.exception("La voz local %s ha fallado", v)
    player.say_windows(text)


# --- Reconocimiento de voz (Whisper) ---

# Frases que Whisper se inventa con ruido o silencio (vienen de los subtítulos con los que se entrenó)
HALLUCINATIONS = re.compile(
    r"amara\.org|subt[ií]tul|suscr[ií]bete|gracias por ver|gracias por su atenci[oó]n|^\W*(gracias|m[uú]sica)\W*$",
    re.I,
)


def add_cuda_dlls() -> None:
    """cuBLAS y cuDNN instalados con pip (nvidia-*-cu12): sin instalar CUDA en Windows."""
    for d in glob.glob(os.path.join(sys.prefix, "Lib", "site-packages", "nvidia", "*", "bin")):
        os.add_dll_directory(d)
        os.environ["PATH"] = d + os.pathsep + os.environ.get("PATH", "")


def load_whisper(size: str):
    from faster_whisper import WhisperModel
    import numpy as np
    add_cuda_dlls()
    try:
        model = WhisperModel(size, device="cuda", compute_type="float16")
        list(model.transcribe(np.zeros(16000, "float32"), language="es")[0])   # la primera vez tarda: ahora
        log.info("Whisper %s en la gráfica", size)
        return model
    except Exception as exc:
        log.info("Whisper %s en el procesador (%s)", size, str(exc).splitlines()[0][:120] if str(exc) else type(exc).__name__)
        return WhisperModel(size, device="cpu", compute_type="int8")


def transcribe(model, wav: bytes) -> str:
    """Whisper con detector de voz (VAD): ignora el ruido y los silencios en vez de inventar texto."""
    import tempfile
    fd, path = tempfile.mkstemp(suffix=".wav")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(wav)
        segments, _ = model.transcribe(path, language="es", vad_filter=True, beam_size=5,
                                       condition_on_previous_text=False, initial_prompt="Jarvis.")
        text = " ".join(s.text.strip() for s in segments if s.no_speech_prob < 0.6).strip()
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    return "" if HALLUCINATIONS.search(text) else text


# --- Conversación ---

def clean_answer(text: str) -> str:
    text = re.sub(r"<think>.*?</think>", "", text or "", flags=re.S)
    text = re.sub(r"[*_#`>|]+", "", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    return re.sub(r"\s+", " ", text).strip()


class Assistant:
    def __init__(self, data: Path) -> None:
        self.settings = Settings(data)
        self.status = Status(data)
        self.player = Player()
        self.busy = threading.Lock()
        self.history: list = []
        self.last_turn = 0.0
        self.whisper = None
        self.engine = None

    def load(self) -> None:
        self.status.set("starting")
        self.whisper = load_whisper(self.settings.get().get("SttModel") or "small")
        voice = self.settings.voice()
        try:   # carga la voz local (la elegida o la de respaldo) para que la primera respuesta no espere
            local_voices.synthesize(voice if local_voices.is_local(voice) else local_voices.DEFAULT_LOCAL_VOICE,
                                    "Hola.", self.settings.voices_dir)
        except Exception:
            log.exception("No se pudo cargar la voz local")
        self.connect_engine()
        self.status.set("idle", Error="" if self.engine else "Ollama no responde")
        log.info("Listo. Modelo: %s · voz: %s", self.model(), self.settings.voice())

    def connect_engine(self) -> None:
        from openjarvis.core.config import load_config
        from openjarvis.engine import get_engine
        try:
            found = get_engine(load_config(), "ollama")
            self.engine = found[1] if found else None
        except Exception:
            log.exception("No se pudo conectar con Ollama")
            self.engine = None

    def model(self) -> str:
        return self.settings.get().get("Model") or "qwen3:8b"

    def warm_model(self) -> None:
        """Carga el modelo en Ollama (si se había dormido) mientras el usuario habla."""
        def run():
            try:
                import httpx
                httpx.post(f"{OLLAMA_URL}/api/generate", json={"model": self.model(), "keep_alive": "10m", "options": {"num_ctx": NUM_CTX}}, timeout=60)
            except Exception:
                pass
        threading.Thread(target=run, daemon=True).start()

    def on_hotkey(self) -> None:
        state = self.status.values.get("State")
        if state == "speaking":
            self.player.stop()
            return
        if not self.busy.acquire(blocking=False):
            return   # ya está escuchando o pensando
        self.warm_model()
        threading.Thread(target=self.turn, daemon=True).start()

    def turn(self) -> None:
        try:
            self.player = Player()
            self._turn()
        except Exception as exc:
            log.exception("Error en la conversación")
            self.status.set("idle", Error=str(exc))
        finally:
            if self.status.values.get("State") != "idle":
                self.status.set("idle")
            self.busy.release()

    def _turn(self) -> None:
        from openjarvis.core.types import Message, Role
        from openjarvis.speech.voice_io import record_until_silence

        self.status.set("listening", Error="")
        tone([660, 990])
        cfg = self.settings.get()
        wav = record_until_silence(silence_threshold=int(cfg.get("MicThreshold") or 500),
                                   silence_seconds=0.8, startup_silence_seconds=6, max_seconds=40)
        self.status.set("thinking")
        t = time.time()
        question = transcribe(self.whisper, wav)
        t_stt = time.time() - t
        if len(re.sub(r"\W", "", question)) < 2:
            log.info("No se ha entendido nada")
            tone([520, 360])
            return
        log.info("Tú: %s", question)
        self.status.set("thinking", Question=question, Answer="")

        if time.time() - self.last_turn > HISTORY_MINUTES * 60:
            self.history = []
        if self.engine is None:
            self.connect_engine()
        t = time.time()
        if self.engine is None:
            answer = "No consigo hablar con Ollama. Comprueba que está abierto."
        else:
            prompt = SYSTEM_PROMPT.format(user=os.environ.get("USERNAME", "su dueño"),
                                          now=time.strftime("%A %d/%m/%Y %H:%M"))
            messages = [Message(role=Role.SYSTEM, content=prompt), *self.history,
                        Message(role=Role.USER, content=question)]
            try:
                result = self.engine.generate(messages, model=self.model(), temperature=0.6, max_tokens=300,
                                              num_ctx=NUM_CTX)
                answer = clean_answer(result.get("content", "")) or "Me he quedado en blanco, ¿me lo repites?"
            except Exception as exc:
                log.exception("El modelo ha fallado")
                self.engine = None
                answer = f"El modelo {self.model()} no responde. Revisa Ollama."
                self.status.values["Error"] = str(exc)
            self.history = (self.history + [Message(role=Role.USER, content=question),
                                            Message(role=Role.ASSISTANT, content=answer)])[-HISTORY_TURNS * 2:]
        self.last_turn = time.time()
        log.info("Jarvis: %s  (Whisper %.1f s · modelo %.1f s)", answer, t_stt, time.time() - t)
        self.status.set("speaking", Answer=answer)
        speak(answer, self.settings, self.player)


# --- Arranque ---

def setup_logging(data: Path) -> None:
    path = data / "Jarvis.log"
    try:
        if path.exists() and path.stat().st_size > 200_000:
            path.write_text("", encoding="utf-8")
    except OSError:
        pass
    handler = logging.FileHandler(path, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s  %(message)s", "%Y-%m-%d %H:%M:%S"))
    log.addHandler(handler)
    log.setLevel(logging.INFO)


def parent_alive(handle) -> bool:
    return not handle or kernel32.WaitForSingleObject(handle, 0) == WAIT_TIMEOUT


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--parent", type=int, default=0)
    ap.add_argument("--say")
    args = ap.parse_args()
    data = Path(args.data)
    data.mkdir(parents=True, exist_ok=True)
    setup_logging(data)

    if args.say:
        speak(args.say, Settings(data), Player())
        return 0

    kernel32.CreateMutexW(None, True, "PcToolkit.Jarvis")
    if ctypes.get_last_error() == ERROR_ALREADY_EXISTS:
        return 0
    event = kernel32.CreateEventW(None, False, False, "PcToolkit.Jarvis.Listen")
    parent = kernel32.OpenProcess(SYNCHRONIZE, False, args.parent) if args.parent else None

    assistant = Assistant(data)
    try:
        assistant.load()
    except Exception as exc:
        log.exception("No se pudo arrancar")
        assistant.status.set("error", Error=str(exc))
        return 1

    while parent_alive(parent):
        if kernel32.WaitForSingleObject(event, 1000) == WAIT_OBJECT_0:
            assistant.on_hotkey()
    log.info("El lanzador se ha cerrado: fin")
    assistant.status.set("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
