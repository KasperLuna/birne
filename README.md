# birne 🍐

On-device embedding daemon for macOS. Surfaces Apple's `NLContextualEmbedding` (BERT-based, 768-dim on macOS) via an **OpenAI-compatible `/v1/embeddings` HTTP API** — zero external dependencies, zero network calls, zero API keys.

The embedding counterpart to [apfel](https://github.com/Arthur-Ficial/apfel).

---

## Requirements

- macOS 14+ (Sonoma) on Apple Silicon or Intel
- Xcode Command Line Tools (`xcode-select --install`)
- No Apple Intelligence required

## Install

```sh
git clone https://github.com/you/birne
cd birne
make install          # builds release + copies to /usr/local/bin
```

## Usage

### One-shot embedding

```sh
# Plain output — space-separated floats (pipe-friendly)
birne embed "Hello world"

# JSON output
birne embed -o json "Hello world"

# Pipe input
echo "Hello world" | birne

# Specific language / script
birne embed --language fr "Bonjour le monde"
birne embed --script cyrillic "Привет мир"
birne embed --script cjk "こんにちは"
```

### HTTP daemon (OpenAI-compatible)

```sh
birne --serve                     # port 11435
birne --serve --port 8080         # custom port
birne --serve --quiet             # suppress logs
```

### Background service (launchd)

```sh
# Install and start
cp com.birne.daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.birne.daemon.plist

# Stop
launchctl unload ~/Library/LaunchAgents/com.birne.daemon.plist

# Logs
tail -f /tmp/birne.err
```

### Model info & asset preparation

```sh
birne info                        # show model metadata (JSON)
birne prepare                     # pre-download latin model assets
birne prepare --script cyrillic   # pre-download cyrillic assets
```

---

## API

### `POST /v1/embeddings`

OpenAI-compatible. Drop in any OpenAI embeddings client.

**Request**
```json
{
  "model": "birne-latin",
  "input": "Hello world"
}
```

Or batch:
```json
{
  "model": "birne-latin",
  "input": ["Hello world", "How are you?"]
}
```

**Response**
```json
{
  "object": "list",
  "data": [
    {
      "object": "embedding",
      "index": 0,
      "embedding": [0.012, -0.034, ...]
    }
  ],
  "model": "birne-latin",
  "usage": {
    "prompt_tokens": 3,
    "total_tokens": 3
  }
}
```

### `GET /v1/models`

Lists available models: `birne-latin`, `birne-cyrillic`, `birne-cjk`.

### `GET /health`

Returns `{"status":"ok","service":"birne"}`.

---

## Using with Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:11435/v1", api_key="birne")

resp = client.embeddings.create(
    model="birne-latin",
    input=["Hello world", "Semantic search is great"]
)

vec = resp.data[0].embedding   # list[float], 768-dim on macOS
```

## Using with curl

```sh
curl -s http://localhost:11435/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"birne-latin","input":"Hello world"}' | jq '.data[0].embedding | length'
# 768
```

---

## Models

| Model | Script | Languages | Dimension |
|---|---|---|---|
| `birne-latin` | Latin | en, es, fr, de, it, pt, nl, + 13 more | 768 |
| `birne-cyrillic` | Cyrillic | ru, uk, bg, sr | 768 |
| `birne-cjk` | CJK | zh, ja, ko | 768 |

Assets are downloaded from Apple's system asset catalog on first use (~100 MB each). They may already be present if other apps have used the NaturalLanguage framework.

---

## Design

- **Zero external dependencies** — only `NaturalLanguage.framework` (ships with macOS 14+) and POSIX sockets
- **Actor-isolated engine** — one loaded model per script, shared across concurrent requests
- **Mean-pooling** — token vectors are averaged into a single sentence vector using the Accelerate-friendly float reduction
- **OpenAI wire format** — works with any OpenAI-compatible client
- **Port 11435** — one above apfel (11434/11438) to avoid conflicts

## Related

- [apfel](https://github.com/Arthur-Ficial/apfel) — on-device LLM daemon (FoundationModels)
- [NaturalLanguageEmbeddings](https://github.com/buh/NaturalLanguageEmbeddings) — Swift package wrapping the same API with semantic search utilities
