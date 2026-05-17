from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="LL_", env_file=".env", extra="ignore")

    host: str = "0.0.0.0"
    port: int = 8080

    fake: bool = False
    fake_caption_interval_s: float = 3.0

    data_dir: Path = Path("./data")
    models_dir: Path = Path("./models")

    whisper_model: str = "ggml-tiny.en.bin"
    whisper_step_ms: int = 4000
    whisper_length_ms: int = 8000
    whisper_threads: int = 4

    backend: str = "ollama"

    ollama_url: str = "http://127.0.0.1:11434"
    ollama_model: str = "gemma4:e2b"
    ollama_timeout_s: float = 180.0
    ollama_keep_alive: str = "24h"

    gemma_model: str = "gemma-4-E2B-it-Q4_K_M.gguf"
    gemma_ctx: int = 4096
    gemma_threads: int = 4

    gemma_litertlm: str = "gemma-4-E2B-it.litertlm"

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
