#!/usr/bin/env python3
"""Local stand-in for an LLM provider's chat endpoint, for the SwiftUI
demo when no real OpenAI/Anthropic credentials are configured.

Responds with a real OpenAI chat.completion JSON shape (including
usage/cached tokens), so the demo exercises the OkOvia SDK's actual
interception + parsing code path end to end - only the network
endpoint is local. Point real intercept_hosts at api.openai.com /
api.anthropic.com in production; this is a development convenience
(see LLMProvider.forRequest in the SDK).

Usage: python3 mock-llm-server.py [port]  (default port: 8899)
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)

        body = {
            "id": "chatcmpl-demo000000000000000",
            "object": "chat.completion",
            "model": "gpt-4.1-mock",
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": "Hello from the Viking demo mock provider."},
                    "finish_reason": "stop",
                }
            ],
            "usage": {
                "prompt_tokens": 128,
                "completion_tokens": 42,
                "total_tokens": 170,
                "prompt_tokens_details": {"cached_tokens": 32},
            },
        }
        payload = json.dumps(body).encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
    server = HTTPServer(("127.0.0.1", port), Handler)
    print(f"Mock LLM provider listening on http://127.0.0.1:{port}/v1/chat/completions")
    server.serve_forever()
