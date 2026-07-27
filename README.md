# AI Security Lab

A local study and lab environment for AI / LLM security research.

## Folder layout

| Folder           | Purpose                                                             |
|------------------|--------------------------------------------------------------------|
| `frameworks/`    | Reference material — OWASP LLM Top 10, MITRE ATLAS notes, etc.      |
| `labs/`          | Hands-on exercises and practical labs.                             |
| `notes/`         | Personal writeups and study notes (markdown).                      |
| `tools/`         | Cloned repos and helper scripts.                                  |
| `local-models/`  | Open-weight models downloaded for local testing (git-ignored).    |
| `venv/`          | Python virtual environment (git-ignored).                         |

## Requirements

- **Python 3.14** (installed per-user)
- **git**

## Setting up the Python environment

The virtual environment already exists at `venv/`. To use it:

### Activate (PowerShell)

```powershell
.\venv\Scripts\Activate.ps1
```

> If you get an execution-policy error the first time, allow scripts for your
> user (this is a per-user setting, not system-wide):
>
> ```powershell
> Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
> ```

### Activate (Command Prompt / cmd.exe)

```bat
venv\Scripts\activate.bat
```

### Deactivate (any shell)

```powershell
deactivate
```

## Installing dependencies

Once the venv is activated:

```powershell
pip install -r requirements.txt
```

Current baseline packages (see `requirements.txt`):

- `requests` — HTTP client
- `python-dotenv` — load secrets from a `.env` file
- `jupyter` — notebooks for interactive experiments

> Heavy ML packages (PyTorch, transformers, etc.) are intentionally **not**
> included yet. Add them deliberately once you've picked CPU vs GPU builds —
> and note that brand-new Python releases sometimes lag on prebuilt wheels.

## Secrets

Store API keys and secrets in a `.env` file at the project root. It is
git-ignored by default. Load them in Python with:

```python
from dotenv import load_dotenv
import os

load_dotenv()
api_key = os.getenv("MY_API_KEY")
```

## Reference material

- **OWASP LLM Top 10** — see `notes/owasp-llm-top10.md`
- **MITRE ATLAS** — see `notes/mitre-atlas.md`
