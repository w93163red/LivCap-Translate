#!/bin/bash
cd "$(dirname "$0")"
uv run python -m gemini_proxy.server "$@"
