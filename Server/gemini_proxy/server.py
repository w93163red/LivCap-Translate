"""
Gemini-to-OpenAI proxy server.

Accepts OpenAI-compatible /v1/chat/completions requests and forwards them
to Google Gemini via gemini_webapi (cookie-based, no API key needed).
"""

import argparse
import asyncio
import json
import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

from gemini_webapi import GeminiClient
from gemini_webapi.exceptions import (
    APIError,
    AuthError,
    GeminiError,
    ModelInvalid,
    TemporarilyBlocked,
    TimeoutError as GeminiTimeoutError,
    UsageLimitExceeded,
)

from .config import AVAILABLE_MODELS, DEFAULT_HOST, DEFAULT_PORT, MIN_REQUEST_INTERVAL, resolve_model
from .models import (
    ChatCompletionChunk,
    ChatCompletionChoice,
    ChatCompletionMessage,
    ChatCompletionRequest,
    ChatCompletionResponse,
    DeltaMessage,
    ErrorDetail,
    ErrorResponse,
    ModelInfo,
    ModelListResponse,
    StreamChoice,
)

logger = logging.getLogger("gemini_proxy")


# ---------------------------------------------------------------------------
# Singleton Gemini client wrapper
# ---------------------------------------------------------------------------

class GeminiClientManager:
    """Manages a single GeminiClient instance with throttling and auto-recovery."""

    def __init__(self):
        self._client: GeminiClient | None = None
        self._last_request_time: float = 0.0
        self._init_lock = asyncio.Lock()

    @property
    def ready(self) -> bool:
        return self._client is not None and self._client._running

    async def start(self):
        """Initialize the client once at startup."""
        async with self._init_lock:
            if self.ready:
                return
            logger.info("Initializing Gemini client (extracting cookies from browser)...")
            self._client = GeminiClient()
            await self._client.init(auto_close=False, auto_refresh=True)
            logger.info("Gemini client ready.")

    async def stop(self):
        """Shut down the client."""
        if self._client:
            logger.info("Shutting down Gemini client...")
            await self._client.close()
            self._client = None

    async def _ensure_client(self):
        """Re-init client if it was closed by gemini_webapi's internal error handling."""
        if not self.ready:
            async with self._init_lock:
                if not self.ready:
                    logger.info("Client was closed, re-initializing...")
                    if self._client:
                        try:
                            await self._client.close()
                        except Exception:
                            pass
                    self._client = GeminiClient()
                    await self._client.init(auto_close=False, auto_refresh=True)
                    logger.info("Client re-initialized.")

    async def _throttle(self):
        """Enforce minimum interval between requests."""
        now = time.monotonic()
        elapsed = now - self._last_request_time
        if elapsed < MIN_REQUEST_INTERVAL:
            wait = MIN_REQUEST_INTERVAL - elapsed
            logger.debug(f"Throttling: waiting {wait:.1f}s before next request")
            await asyncio.sleep(wait)
        self._last_request_time = time.monotonic()

    async def generate(self, prompt: str, model):
        """Non-streaming generation with throttling."""
        await self._throttle()
        await self._ensure_client()
        return await self._client.generate_content(prompt, model=model)

    async def generate_stream(self, prompt: str, model):
        """Streaming generation with throttling."""
        await self._throttle()
        await self._ensure_client()
        async for output in self._client.generate_content_stream(prompt, model=model):
            yield output


_manager = GeminiClientManager()


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    await _manager.start()
    yield
    await _manager.stop()


app = FastAPI(title="Gemini-to-OpenAI Proxy", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def messages_to_prompt(messages: list) -> str:
    """Concatenate OpenAI messages into a single Gemini prompt string."""
    parts: list[str] = []
    for msg in messages:
        parts.append(msg.content)
    return "\n\n".join(parts)


def error_response(status: int, message: str, error_type: str = "server_error", code: str | None = None) -> JSONResponse:
    return JSONResponse(
        status_code=status,
        content=ErrorResponse(
            error=ErrorDetail(message=message, type=error_type, code=code)
        ).model_dump(),
    )


def handle_gemini_exception(exc: Exception) -> JSONResponse:
    """Map gemini_webapi exceptions to OpenAI-style error responses."""
    if isinstance(exc, AuthError):
        return error_response(401, f"Gemini authentication failed: {exc}", "authentication_error", "auth_error")
    if isinstance(exc, (UsageLimitExceeded, TemporarilyBlocked)):
        return error_response(429, f"Gemini rate limit: {exc}", "rate_limit_error", "rate_limit")
    if isinstance(exc, ModelInvalid):
        return error_response(400, f"Invalid model: {exc}", "invalid_request_error", "model_invalid")
    if isinstance(exc, GeminiTimeoutError):
        return error_response(502, f"Gemini timeout: {exc}", "upstream_error", "timeout")
    if isinstance(exc, (GeminiError, APIError)):
        return error_response(502, f"Gemini error: {exc}", "upstream_error", "gemini_error")
    return error_response(502, f"Unexpected error: {exc}", "upstream_error")


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    return {"status": "ok", "client_ready": _manager.ready}


@app.get("/v1/models")
@app.get("/models")
async def list_models():
    return ModelListResponse(
        data=[ModelInfo(id=m) for m in AVAILABLE_MODELS]
    ).model_dump()


async def _handle_chat(request_body: ChatCompletionRequest):
    """Shared handler for both route paths."""
    try:
        model = resolve_model(request_body.model)
    except (ValueError, KeyError) as exc:
        return error_response(400, str(exc), "invalid_request_error", "invalid_model")

    prompt = messages_to_prompt(request_body.messages)

    if request_body.stream:
        return StreamingResponse(
            _stream_response(prompt, model, request_body.model),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )

    # Non-streaming
    try:
        output = await _manager.generate(prompt, model=model)
        text = output.text or ""
        return ChatCompletionResponse(
            model=request_body.model,
            choices=[
                ChatCompletionChoice(
                    message=ChatCompletionMessage(content=text)
                )
            ],
        ).model_dump()
    except Exception as exc:
        return handle_gemini_exception(exc)


async def _stream_response(prompt: str, model, model_name: str):
    """Yield SSE events from Gemini streaming output."""
    try:
        # Send initial role chunk
        chunk = ChatCompletionChunk(
            model=model_name,
            choices=[StreamChoice(delta=DeltaMessage(role="assistant"))],
        )
        yield f"data: {json.dumps(chunk.model_dump())}\n\n"

        async for output in _manager.generate_stream(prompt, model=model):
            delta_text = output.text_delta
            if delta_text:
                chunk = ChatCompletionChunk(
                    model=model_name,
                    choices=[StreamChoice(delta=DeltaMessage(content=delta_text))],
                )
                yield f"data: {json.dumps(chunk.model_dump())}\n\n"

        # Send finish chunk
        chunk = ChatCompletionChunk(
            model=model_name,
            choices=[StreamChoice(delta=DeltaMessage(), finish_reason="stop")],
        )
        yield f"data: {json.dumps(chunk.model_dump())}\n\n"
        yield "data: [DONE]\n\n"

    except Exception as exc:
        logger.error(f"Stream error: {exc}")
        err = ErrorResponse(
            error=ErrorDetail(message=str(exc), type="upstream_error")
        )
        yield f"data: {json.dumps(err.model_dump())}\n\n"
        yield "data: [DONE]\n\n"


@app.post("/v1/chat/completions")
@app.post("/chat/completions")
async def chat_completions(request: Request):
    try:
        body = await request.json()
        req = ChatCompletionRequest(**body)
    except Exception as exc:
        return error_response(400, f"Invalid request body: {exc}", "invalid_request_error")
    return await _handle_chat(req)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Gemini-to-OpenAI proxy server")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"Bind host (default: {DEFAULT_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Bind port (default: {DEFAULT_PORT})")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    import uvicorn
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
