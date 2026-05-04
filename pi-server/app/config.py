from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="LL_", env_file=".env", extra="ignore")

    host: str = "0.0.0.0"
    port: int = 8080

    # When True, replace whisper + gemma with stubs so the server runs end-to-end
    # without model files. Used for laptop dev and CI smoke tests.
    fake: bool = False
    fake_caption_interval_s: float = 3.0

    data_dir: Path = Path("./data")
    models_dir: Path = Path("./models")

    whisper_model: str = "ggml-tiny.en.bin"
    whisper_step_ms: int = 4000
    whisper_length_ms: int = 8000
    whisper_threads: int = 4

    # Translation/generation backend: "ollama" (default) or "llamacpp".
    # Both speak Gemma 4 E2B; ollama is the easy default that uses the
    # local Ollama daemon's HTTP API. llamacpp uses llama-cpp-python
    # against a raw GGUF file in models_dir for users who want fine-grained
    # control (custom samplers, thread pinning, etc).
    backend: str = "ollama"

    # Ollama backend
    ollama_url: str = "http://127.0.0.1:11434"
    ollama_model: str = "gemma4:e2b"
    # Generation latency on Pi 5 is ~6 tok/s for E2B Q4_K_M, so a 60-token
    # translation needs ~10s. Cold-start adds ~85s to the first call.
    ollama_timeout_s: float = 180.0
    # Keep model resident across calls. "24h" practically never unloads during
    # a class; "10m" idles after 10 min. Negative integers also mean "forever"
    # but pydantic settings serializes that awkwardly to Ollama's parser.
    ollama_keep_alive: str = "24h"

    # llama.cpp backend
    gemma_model: str = "gemma-4-E2B-it-Q4_K_M.gguf"
    gemma_ctx: int = 4096
    gemma_threads: int = 4

    sample_rate: int = 16000
    channels: int = 1

    supported_languages: list[str] = [
        "ar",  # Arabic
        "uk",  # Ukrainian
        "es",  # Spanish
        "zh",  # Mandarin
        "fr",  # French
        "ps",  # Pashto
        "fa",  # Farsi
    ]


settings = Settings()
settings.data_dir.mkdir(parents=True, exist_ok=True)
settings.models_dir.mkdir(parents=True, exist_ok=True)
