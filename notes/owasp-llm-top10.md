# OWASP Top 10 for LLM Applications (2025)

**Author:** Jeriah Keith (@yeriahz)

Study notes. One section per risk. Fill in as you go.

> Source of truth: <https://genai.owasp.org/llm-top-10/>
> The list is versioned — verify IDs/names against the official page, since
> they have changed between releases (e.g. the 2023 vs 2025 lists differ).

> **Rule for this file:** every entry is anchored to something I read or ran
> myself, with a file and line where possible. If I have no first-hand
> material for a section, it says so rather than paraphrasing the framework.

---

## LLM01 — Prompt Injection

**What it is:**
Attacker-controlled text reaches the model's context and is treated as
instruction rather than data.

**How the attack works:**
The model has no structural boundary between the system prompt, the task, and
the content it is asked to process. Anything rendered into context competes
for the model's attention on equal footing.

**Example / scenario:**
NOOA renders three regions into context each turn (`sec 3.2` of the paper):
static blocks, event history, and dynamic blocks re-evaluated per turn. A
CodeAct method receives arguments as live Python objects but the harness
renders a bounded *preview* of each into the prompt. So attacker-controlled
data inside an argument does enter the context window, just truncated.

**Mitigations:**
None of the layers I read treat this as solvable at the text level. NOOA's
answer is downstream: whatever the model decides to do, the OS sandbox limits
what that decision can reach.

**Lab ideas:**
- Pass an argument whose content contains instruction-shaped text and see
  whether the bounded preview carries it into context intact.
- Check whether `pprint()` truncation can be used to hide content in the
  elided middle while the head and tail look benign.

**Notes:**
Not yet exercised. This is the largest gap in my first-hand coverage.

---

## LLM02 — Sensitive Information Disclosure

**What it is:**
The model, or code it writes, reaches data it should not have.

**How the attack works:**
Two distinct paths I have seen. Data the model can read directly, and data
the *process* can read because it inherited it.

**Example / scenario:**
*Process inheritance.* NOOA's sandbox worker is forked
(`sandbox/config.py`, start method is `fork` only). `fork()` copies the
parent's memory, including its environment. `.env.example` in the repo asks
for `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`. Landlock confines the filesystem
and seccomp blocks sockets, but neither touches `os.environ`, which is just
memory the process already holds.

`worker.py:34` is explicit that a fully adversarial in-process cell reaching
framework internals is out of scope for that layer, and hands it to "the
OS-layer (separate uid/namespace) sandbox." The paper's ARC-AGI-3 fleet
(Appendix D.2) runs exactly that: a per-run OS-level uid drop.

*Cross-agent memory.* `nooa-memory` scopes reads by owner when several agents
share one SQLite store. Spreading activation over the memory graph gates on
the same owner check (`retrieval.py:245`, `_visible` at `:258`), and the
`continue` fires before the next hop's frontier is written, so a foreign
memory cannot relay activation between two visible ones.

**Mitigations:**
- The one I actually used: run a local model, so no credential exists in the
  environment to leak. Ollama bound to guest-local `127.0.0.1:11434`.
- A separate uid or namespace per run, which is what the framework itself
  recommends and what the paper's fleet deployed.

**Lab ideas:**
- With `execution_backend="sandbox"`, have a cell read `os.environ` and print
  it. Confirm whether the fork inheritance is real in practice.
- Repeat with a uid drop in place and see what changes.

**Notes:**
This one is mine end to end. Wrote the three-node relay regression test for
the memory half (NVIDIA-NeMo/labs-OO-Agents#73, merged). The environment
inheritance I reasoned to from the source and never demonstrated, which is the
honest limit on that half.

---

## LLM03 — Supply Chain

**What it is:**
Compromise or corruption of the artifacts a system depends on: model weights,
packages, CI actions.

**How the attack works:**
Trust a name instead of verifying content, and anyone who controls the name
controls what you run.

**Example / scenario:**
*The one I found.* Ollama stores model data in a content-addressed store where
every filename **is** the SHA256 of that file's contents. It never re-hashes.
A blob zeroed by an interrupted write kept its name and size, and every
subsequent `ollama pull` printed `verifying sha256 digest` and `success` while
leaving it in place. Filed as ollama/ollama#17520. Root cause traced by
another contributor: `pullWithTransfer` in `server/images.go` delegates to
`x/transfer/download.go`, which decides a blob is already present on **file
size alone** and never calls the existing `verifyBlob()`. The legacy path did
call it. So this is a regression, not an omission.

*A defense working.* `uv.lock` in the NOOA repo is 467KB of pinned versions
and hashes. `uv sync` installs exactly what the maintainers tested. Without it
you get whatever is current today.

*A control I ran into from the wrong side.* NVIDIA's GitHub org enforces an
Actions allowlist. Their `gitleaks` action was not on it, so CI failed at
startup on every open PR for two days, including mine. Note how much of that
allowlist is full commit SHAs rather than tags: `@v2` is mutable and can be
repointed, a SHA cannot.

*Format-level.* Safetensors exists because the pickle model format could
execute code on load. Same idea one layer down: make the artifact incapable of
carrying the payload.

**Mitigations:**
- Verify content against the digest, especially on the cache-hit path, which
  is where the check gets skipped.
- Pin to immutable identifiers (SHA, lockfile) rather than mutable names.
- Formats that cannot execute.

**Lab ideas:**
- Run the whole-store integrity sweep against any content-addressed cache:
  `sha256sum sha256-* | while read h f; do [ "$h" = "${f#sha256-}" ] || echo "CORRUPT: $f"; done`
- Check whether pip/uv verify hashes on a cache hit or only on download.

**Notes:**
Strongest section. Three separate incidents in one week, and the one I
reported had a PR against it within a day.

---

## LLM04 — Data and Model Poisoning

**What it is:**
Deliberately corrupting training data, fine-tunes, or model artifacts.

**How the attack works:**
Get bad data or a bad artifact accepted as legitimate.

**Example / scenario:**
No first-hand poisoning work. But the Ollama finding above is the *mechanism*
a model-file poisoner would need: the store accepts a blob whose contents do
not match its declared digest, and reports success. Corruption there was
accidental. The path an attacker would use is the same one.

**Mitigations:**
Same as LLM03: verify the artifact against its digest at load, not only at
download.

**Lab ideas:**
- Replace a model layer blob with a different valid GGUF of matching size and
  see whether anything notices before inference.

**Notes:**
Adjacent coverage only. Do not overclaim this section.

---

## LLM05 — Improper Output Handling

**What it is:**
Treating model output as trusted input to something downstream.

**How the attack works:**
The model emits a string; something executes, renders, or queries with it.

**Example / scenario:**
This is the whole of CodeAct. `actor.py:2159` is `exec(code, namespace)`,
where `code` is a string the model wrote. Five more `exec(compile(...))` calls
sit in the same file. There is no line that says "run the LLM's code" because
to Python it is only a string, and Python has no way to know where it came
from.

`code_validator.py` inspects the AST first and its error registry is a
compressed history of Python sandbox escapes: E001 blocks `exec`/`eval`/
`compile`/`__import__` **and their aliases and `getattr()` of any such name**,
E101 blocks `__class__`/`__subclasses__` (the classic walk from any object to
every subclass in the interpreter), E102 blocks `object.__setattr__` and
`super().__setattr__`.

And then `restrictions.py:11` says plainly that none of it contains anything:
`open()` gives arbitrary file I/O, `importlib` loads modules straight from a
path, reflection reaches the rest, and extending the deny-list is "unwinnable
whack-a-mole."

**Mitigations:**
Per the framework's own docs: OS-level isolation. The validator's job is to
stop generated code freezing the event loop and to catch common mistakes, not
to contain an adversary.

**Lab ideas:**
- With the sandbox off, write a cell that reaches a file outside the workspace
  via `open()`. It should succeed, because the validator permits it by design.
- Turn the sandbox on and repeat. Landlock should refuse it. This is the
  layering claim, and it is what
  `test_filesystem_guard_inside_cell` already asserts.

**Notes:**
The honesty of `restrictions.py:11` is the best security writing I have read
in a codebase. Documenting why your own control is insufficient is rarer than
the control itself.

---

## LLM06 — Excessive Agency

**What it is:**
Giving the model more capability, permission, or autonomy than the task needs.

**How the attack works:**
The blast radius of a bad decision is whatever the agent was allowed to touch.

**Example / scenario:**
`strategy_config.py:80`:

```python
execution_backend: Literal["inprocess", "sandbox"] = "inprocess"
```

CodeAct is the **default** strategy for any generation method, and the OS
sandbox is **opt-in**. So a plain agent, written from the quickstart, executes
model-written Python in the agent's own process unless you say otherwise. I
ran that way for days before I checked.

Capability inventory available to a cell: a persistent bash subprocess
(`tools/_bash_session.py`), `self` and everything on it, imports, and the
ability to define a new `@strategy`-decorated function and fan it out with
`asyncio.gather`, spawning subagents.

**Mitigations:**
- `execution_backend="sandbox"`, which is one line and off by default.
- The VM, which is what the README actually tells you to build.
- Cut network before running anything untrusted. My verifier asserts this
  under `-Detonate`.

**Lab ideas:**
- Diff what a cell can reach with `execution_backend` set each way.
- Time how long it takes a fresh reader of the docs to discover the default.
  Mine was about two weeks.

**Notes:**
The gap between "the framework has a sandbox" and "the sandbox is running"
is the single most useful thing I learned this month.

---

## LLM07 — System Prompt Leakage

**What it is:**
Secrets or logic embedded in the system prompt becoming visible to the user
or the model's output.

**How the attack works:**
Ask for it, or get the model to summarize its own instructions.

**Example / scenario:**
NOOA renders `<system_prompt>` and a `doc(self)` view of the agent API into a
cacheable static prefix visible every turn (Appendix B of the paper shows the
full region verbatim). `self.context` and `self.events` are model-callable
APIs, so an agent can query its own context, though they are omitted from
`doc(self)` by default until the developer opts in per instance.

**Mitigations:**
Do not put secrets in the prompt. The framework's own position is that
durable state belongs on the object, not in the conversation.

**Lab ideas:**
- Ask an agent to print its own system prompt and see what comes back.
- Check whether `self.events.query()` can reach the static prefix or only the
  event history.

**Notes:**
Thin. I have read the mechanism but not tested extraction.

---

## LLM08 — Vector and Embedding Weaknesses

**What it is:**
Attacks on the retrieval layer: poisoned embeddings, cross-tenant leakage,
retrieval manipulation.

**How the attack works:**
Retrieval decides what the model sees. Influence retrieval and you influence
the model without touching the prompt.

**Example / scenario:**
`nooa-memory` is one SQLite file with derived, interchangeable vector indexes
(numpy, sqlite-vec, or Chroma). Retrieval unions embedding and keyword
candidates, ranks by ACT-R activation (relevance, recency, importance), then
propagates activation over a typed graph.

The cross-tenant question: when several agents share one store, can one
agent's memories influence another's ranking? I answered this for the
Agent Memory Atlas (issue #1 there, credited in their published report). They
cannot. `_visible()` is called in the innermost loop of `_spread()` so it runs
for every edge at every hop, and the `continue` fires before the next
frontier is written.

The important subtlety: this property is **not observable through the public
`recall()` API**. A relay target owned by a third party is gated on its own
merits; one owned by the reader is retrieved directly regardless of the graph.
What a relay changes is *activation*, and therefore ranking, which only exists
inside `_spread`. A security property that can only be asserted against a
private function is a fact about the design, not a compromise in the test.

**Mitigations:**
Gate the traversal frontier, not just the returned rows. Most systems that
claim scope enforcement only filter what they return, which still requires
reading the foreign node in order to drop it.

**Lab ideas:**
- Check the `activation_floor` margin. At `per_hop_decay = 0.6` and
  associative `type_w = 0.6`, a two-hop contribution is `0.07776` against a
  floor of `0.05`. Drop the edge weight to 0.8 and it becomes `0.0498` and is
  discarded before visibility is ever consulted. A test using a lower weight
  would pass for the wrong reason.

**Notes:**
My merged test for this is
`test_spread_does_not_relay_through_foreign_memories` in
`packages/nooa-memory/tests/memory/test_memory_owner.py`.

---

## LLM09 — Misinformation

**What it is:**
The model produces confident output that is wrong, and something downstream
acts on it.

**How the attack works:**
Fluency is not accuracy, and nothing in the pipeline distinguishes them.

**Example / scenario:**
Weak first-hand coverage. The closest thing I have: NOOA validates the return
value against the method's type annotation and re-prompts on failure, which
catches *shape* but says nothing about truth. A 1.7B model satisfied the
`-> str` contract for me with a paraphrase rather than the sentiment analysis
the docstring asked for. Valid, useless.

**Mitigations:**
Typed returns and postconditions catch structure. Correctness needs a
deterministic check outside the model, which is Principle 3 in the paper:
exact rules, arithmetic, parsing, and state transitions belong in
deterministic methods.

**Lab ideas:**
- Write a postcondition that checks a factual property of the return, not
  just its type, and see how the retry loop behaves.

**Notes:**
Underdeveloped. Least first-hand material of any section.

---

## LLM10 — Unbounded Consumption

**What it is:**
An agent consuming resources without limit: CPU, memory, tokens, cost.

**How the attack works:**
A loop, a runaway allocation, or a task that never terminates.

**Example / scenario:**
*My own machine, not an attack.* `llama-server` took every vCPU in the guest
and starved the kernel itself. The console eventually said so:

```
watchdog: BUG: soft lockup - CPU#3 stuck for 371s! [llama-server:2626]
```

Five CPUs locked, RCU stalls, and sshd could not be scheduled, which is why
sessions authenticated and then hung. The hard resets I did to recover are
what zeroed the Ollama blobs in LLM03. One resource problem created one
supply-chain problem.

*The fix that made it worse.* I capped the service with `CPUQuota=600%`. The
lockups stopped and generation collapsed to six tokens in twenty-five minutes,
because CFS quota works in bursts and llama.cpp's threads spin-wait at
per-token synchronization barriers. `AllowedCPUs=0-5` pins the service to six
cores with no throttling and restored normal speed. Same intent, opposite
outcome.

*What NOOA offers.* `sandbox/config.py` has `max_memory_mb` and
`max_cpu_seconds`, both defaulting to `0`, which means disabled. There is also
a wall-clock `cell_timeout` with a `timeout_grace_s` before the parent hard
kills, and a parent-side RSS watchdog. So a fresh sandbox blocks the network
and confines the filesystem but does not bound memory or CPU until you ask.
I confirmed this against `/proc/<pid>/limits`: unlimited on both parent and
worker, which is the config working as specified.

**Mitigations:**
- Continuous limits (cpuset) over bursty ones (quota) for workloads with
  internal synchronization.
- Set the caps. They exist and are off.
- Wall-clock timeout as the backstop for anything the resource caps miss.

**Lab ideas:**
- `max_cpu_seconds=1` plus a `while True: pass` cell.
  `test_cpu_guard_kills_spin_loop` already does this; run it and watch.
- Compare `CPUQuota` against `AllowedCPUs` on a token-generation workload and
  record the numbers.

**Notes:**
The CPUQuota episode is the one I keep coming back to: a control that
succeeded at its stated goal (the kernel stopped starving) and destroyed the
thing it was protecting. You find that failure the same way you find a control
that does nothing, by measuring the thing you were protecting rather than the
thing you were protecting it from.