from gemini_webapi.constants import Model

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 11435

# Throttling: minimum seconds between Gemini requests
MIN_REQUEST_INTERVAL = 2.0

# Map OpenAI model names to gemini_webapi Model enum values.
# Unknown names fall through to Model.from_name() for forward-compatibility.
MODEL_MAP: dict[str, Model] = {
    "gemini-3.0-flash": Model.G_3_0_FLASH,
    "gemini-3.0-pro": Model.G_3_0_PRO,
    "gemini-3.0-flash-thinking": Model.G_3_0_FLASH_THINKING,
    # Convenience aliases so users can leave "gpt-4o" in their settings
    "gpt-4o": Model.G_3_0_FLASH,
    "gpt-4o-mini": Model.G_3_0_FLASH,
}

# Models advertised by GET /v1/models
AVAILABLE_MODELS = [
    "gemini-3.0-flash",
    "gemini-3.0-pro",
    "gemini-3.0-flash-thinking",
]


def resolve_model(name: str) -> Model:
    """Resolve an OpenAI-style model name to a gemini_webapi Model."""
    if name in MODEL_MAP:
        return MODEL_MAP[name]
    return Model.from_name(name)
