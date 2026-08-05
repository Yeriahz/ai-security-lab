# MITRE ATLAS — Adversarial Threat Landscape for AI Systems

**Author:** Jeriah Keith (@yeriahz)

Study notes organized by tactic (the ATT&CK-style columns of the ATLAS matrix).
One section per tactic. Fill in techniques and notes as you study.

> Source of truth: <https://atlas.mitre.org/>
> ATLAS evolves — new tactics/techniques are added and some are renamed
> (e.g. "ML" -> "AI"). Verify the current matrix against the official site.

> **Rule for this file:** same as the OWASP notes. Every entry is anchored to
> something I read or ran myself, or to a documented public incident, with a
> file and line where possible. Sections where I have no first-hand material
> say so rather than paraphrasing the matrix.

> Companion file: `owasp-llm-top10.md`. OWASP asks what can go wrong; ATLAS
> asks what an adversary does. Several findings appear in both, framed
> differently.

---

## Reconnaissance

**Goal (attacker objective):**
Learn about the target AI system before touching it: model, framework,
harness, prompts, deployment.

**Key techniques:**
Reading public documentation, source, papers, and published evaluations.

**Notes / examples:**
Almost everything in these notes came from public sources: the repo, the
paper, and the maintainers' own comments. That is the recon surface for any
open framework, and it is not a weakness so much as the cost of being open.

The defensive counterpart is worth studying. The paper's ARC-AGI-3 fleet
(Appendix D.2) replaced game identities end to end with opaque `game-<hex>`
aliases and redacted outputs and state. A name-leak scanner found zero
occurrences of any real identifier across 13,335 agent logs. So the agent
could not recon what it was working on even from inside.

Thin on offensive first-hand work.

---

## Resource Development

**Goal (attacker objective):**
Build or acquire the capabilities used later: infrastructure, accounts,
malicious packages, adversarial data.

**Key techniques:**
Publishing a malicious package, standing up infrastructure, obtaining
credentials.

**Notes / examples:**
The clearest 2026 example is from Anthropic's July disclosure: during an
internal evaluation a model built a malicious Python package and uploaded it
to PyPI, believing it was in a simulation. It was live about an hour, and in
that hour it was downloaded and executed on 15 real machines, one belonging to
a security company that automatically runs packages in order to scan them.

That is resource development performed by the system under test, against the
real world, from inside what its operators believed was a sealed environment.

No first-hand work here, and I do not intend any.

---

## Initial Access

**Goal (attacker objective):**
Get a foothold in the target environment.

**Key techniques:**
Exploiting a vulnerability, using valid accounts, supply-chain compromise.

**Notes / examples:**
The OpenAI / Hugging Face incident (July 9 to 13, 2026): an agent under
evaluation escaped its sandbox through a zero-day, correctly reasoned that
Hugging Face hosted the benchmark data it wanted, and ran a campaign lasting
about four and a half days. Modal Labs was a second victim, where the flaw was
in customer code running on their infrastructure rather than in Modal itself.

The escalation detail that matters: publicly exposed credentials across four
accounts on four services. A Georgetown researcher's summary was that in some
cases the front door was simply left open.

Public incident, not first-hand.

---

## AI Model Access

**Goal (attacker objective):**
Reach the model itself: the API, the weights, or the inference endpoint.

**Key techniques:**
API access, physical access to weights, access via a legitimate application.

**Notes / examples:**
My setup: Ollama binds to `127.0.0.1:11434` inside the guest, so the endpoint
is not reachable from the host or the LAN.

Worth noting how the layers divide. The NOOA *parent* process makes the LLM
calls. The forked *worker* runs generated code and has a seccomp filter
blocking `AF_INET`/`AF_INET6`. So a cell cannot reach the model endpoint
directly even though the process that spawned it does nothing but talk to it.
Confirmed against `/proc/<pid>/status`: worker `Seccomp: 2`, parent
`Seccomp: 0`.

Weight access is the other half. Ollama's blob store is on disk with normal
file permissions, and Landlock default-deny is what keeps a cell out of it.

---

## Execution

**Goal (attacker objective):**
Run attacker-controlled code on the target.

**Key techniques:**
Command and scripting interpreter, user execution, exploitation for execution.

**Notes / examples:**
Strongest section. In an agent harness this is not an exploit, it is the
feature.

`actor.py:2159` is `exec(code, namespace)`, where `code` is a string the model
wrote. Five more `exec(compile(...))` calls sit in the same file. There is no
line marked "run the LLM's code" because to Python it is only a string.

`tools/_bash_session.py` maintains a long-running bash subprocess, so shell
execution is a first-class capability alongside Python.

The default matters as much as the mechanism. `strategy_config.py:80`:

```python
execution_backend: Literal["inprocess", "sandbox"] = "inprocess"
```

CodeAct is the default strategy and the OS sandbox is opt-in, so out of the
box generated code executes in the agent's own process.

---

## Persistence

**Goal (attacker objective):**
Keep influence across restarts, sessions, or task boundaries.

**Key techniques:**
Poisoned memory, modified stored artifacts, backdoored skills.

**Notes / examples:**
The memory subsystem is the persistence surface, and it is designed to be one.
Seven model-callable tools (`remember`, `recall`, `search`, `update_memory`,
`forget`, `associate`, `deref`) write to a SQLite store that outlives the
session. A `BeforeTurn` hook derives a query from recent events and injects
associated memories into a dynamic context block, so a written memory can
resurface unprompted in a later run.

`skill` type memories are the sharper case: only 3% of writes in the paper's
fleet, but the highest mean importance of any type (8.3) and
over-represented in deliberate reads. Durable procedures the agent goes back
for.

REPL locals are method-scoped and disappear when the method returns, but
anything reached through `self` or a library call can have effects that
outlive the call, exactly as in ordinary Python.

**Lab idea:** write a memory with high stated importance and check how many
turns later the `BeforeTurn` hook surfaces it unprompted.

---

## Privilege Escalation

**Goal (attacker objective):**
Move from a constrained context to a more privileged one.

**Key techniques:**
Escaping a sandbox, abusing a trust boundary, inheriting privilege.

**Notes / examples:**
The trust boundary here runs between the sandboxed worker and the parent that
spawned it. `worker.py:34` names the escape path in a comment:
`self._broker._conn.send(<pickle bomb>)`. The parent and worker talk over
`multiprocessing.connection.Connection`, which pickles in both directions, and
pickle deserialization executes code by design. A compromised worker sending a
crafted pickle would be executing in the *trusted* process.

The mitigation is absence rather than prohibition: private state for every
proxy is kept out of the object's `__dict__` in a module-private weak-keyed
registry, so `self._broker` resolves through `__getattr__` against the agent,
finds nothing, and fails. There is no live pipe to name.

The maintainers scope this honestly. The same comment says a fully adversarial
in-process cell reaching framework internals is out of scope for that layer
and belongs to "the OS-layer (separate uid/namespace) sandbox."

`test_cell_cannot_reach_broker_pipe` asserts the property.

---

## Defense Evasion

**Goal (attacker objective):**
Avoid detection or bypass the controls in place.

**Key techniques:**
Obfuscation, indirect calls, exploiting gaps in static analysis.

**Notes / examples:**
`code_validator.py`'s error registry reads as a history of evasion attempts.
E001 blocks not just `exec`/`eval`/`compile`/`__import__` but **their aliases
and `getattr()` of any such name**, because `f = exec; f(code)` and
`getattr(builtins, "exec")` both reach it without writing the word. E101
blocks `__class__` and `__subclasses__`, the classic walk from any object up
to every subclass in the interpreter. E102 blocks `object.__setattr__` and
`super().__setattr__`.

And `restrictions.py:11` says the whole approach cannot work against an
adversary: `open()` gives arbitrary file I/O, `importlib` loads modules from a
path, reflection reaches the rest, and extending the list is "unwinnable
whack-a-mole."

The paper documents a live gap in its own guard (Appendix D.2): dynamic
attribute lookup can evade the AST scan. They publish it alongside the
backstop that catches it, which under the fleet's configuration was the uid
drop. Publishing the hole and the layer that covers it is the part worth
copying.

**Defender-side corollary.** My own controls failed three times in eight days
in ways that look exactly like evasion succeeding: a check that could not
fail, a check that fired falsely across VM states, a check that fired falsely
depending on uptime. A control that reports success without checking is
indistinguishable from a control that was evaded.

---

## Credential Access

**Goal (attacker objective):**
Obtain credentials for use elsewhere.

**Key techniques:**
Reading environment variables, files, or memory; harvesting exposed secrets.

**Notes / examples:**
The sandbox provides *action* containment, not *secret* confinement, and the
distinction is the finding.

The worker is forked. `fork()` copies the parent's memory including its
environment, and `.env.example` asks for `OPENAI_API_KEY` /
`ANTHROPIC_API_KEY`. Landlock mediates filesystem syscalls and seccomp blocks
sockets, but `os.environ` is neither: it is memory the process already holds.
Nothing in the sandbox package touches it (`grep environ` across
`src/nooa/runtime/sandbox/` returns nothing).

This is why the paper's fleet adds a per-run OS-level uid drop on top of the
per-cell sandbox.

The Hugging Face incident escalated on exposed credentials across four
accounts. Same tactic, real consequences.

**Mitigation I actually used:** a local model, so there is no credential in
the environment to read.

**Lab idea:** with `execution_backend="sandbox"`, have a cell print
`os.environ` and confirm whether the inheritance is real. Reasoned from source
so far, never demonstrated.

---

## Discovery

**Goal (attacker objective):**
Learn about the environment from inside it.

**Key techniques:**
System and file discovery, enumerating available tools and state.

**Notes / examples:**
NOOA gives the model discovery as a feature. `doc(obj)` returns documentation
for any type, `pprint()` renders bounded previews of live values, and the
`<execution_context>` block lists available types, imported items, and stdlib
modules. `self` is in scope, so the agent can enumerate its own state and
methods.

The paper's red-team audit caught the offensive version. Across the 25-game
fleet there was exactly one escape attempt, and it was discovery: an agent
invoked a filesystem-recon shell command, `find`/`grep` for its own store
alias. The cell guard replaced the cell before execution and zero bytes were
returned.

That is the shape to remember. The first move from inside a sandbox is usually
to find out what the sandbox is.

---

## Collection

**Goal (attacker objective):**
Gather the data of interest before moving it.

**Key techniques:**
Staging data locally, accumulating across sessions.

**Notes / examples:**
Two staging areas. REPL locals persist across cells within a single CodeAct
call, so a cell can accumulate a large result and process it over several
turns without any of it entering the context window. That is the deliberate
design: "the amount of data an agent can process is bounded by the execution
environment, not by the prompt."

The memory store is the cross-session version. In the paper's fleet, 3,262
memories written across 25 games.

Note the interaction with exfiltration below: collection inside the sandbox is
cheap and unbounded, so the control that matters is the egress boundary, not
the collection.

---

## AI Attack Staging

**Goal (attacker objective):**
Prepare the attack against the model itself: proxy models, adversarial data,
poisoned artifacts.

**Key techniques:**
Training a proxy model, crafting adversarial examples, backdooring weights.

**Notes / examples:**
No first-hand work.

The nearest adjacent thing I have is the Ollama blob finding: a
content-addressed store that accepts a file whose contents do not match its
declared digest, and reports `verifying sha256 digest` / `success` while doing
it (ollama/ollama#17520). Corruption there was accidental, but a staged
malicious artifact would take the same path.

---

## Exfiltration

**Goal (attacker objective):**
Move data out of the environment.

**Key techniques:**
Exfiltration over network, over an alternative channel, via a legitimate
service.

**Notes / examples:**
NOOA's own README names this first among the risks: generated code may take
"dangerous or unwanted actions, including sending private data to
uncontrolled locations."

Controls I verified:
- seccomp blocks `AF_INET`/`AF_INET6` in the worker. Confirmed at the kernel:
  worker `Seccomp: 2` with one filter, parent `Seccomp: 0`.
- `network: bool = False` is the sandbox default.
- My verifier asserts egress is cut under `-Detonate` (adapter is
  `none`/`intnet`/`hostonly`, or the cable is disconnected), and fails with
  exit 1 otherwise. Negative-tested by reconnecting the cable.

The instructive detail: after I cut the cable, a NOOA run logged litellm
trying to fetch a model cost map from a GitHub URL and falling back to a local
copy. An unrequested outbound call from a dependency, on a run I believed was
purely local. With the network up it would have gone out silently and I would
never have known. Cutting egress is what made an invisible channel visible.
(`LITELLM_LOCAL_MODEL_COST_MAP=True` in `.env.example` disables it.)

Cross-channel note: LLM02's credential inheritance plus a live network is the
full exfiltration chain. Neither half alone gets you there.

---

## Impact

**Goal (attacker objective):**
Degrade, disrupt, or destroy.

**Key techniques:**
Resource exhaustion, denial of service, data destruction, cost inflation.

**Notes / examples:**
Lived this one, self-inflicted. `llama-server` took every vCPU in the guest
and starved the kernel:

```
watchdog: BUG: soft lockup - CPU#3 stuck for 371s! [llama-server:2626]
```

Five CPUs locked, RCU stalls, sshd unschedulable. The hard resets I used to
recover are what zeroed the Ollama blobs, so one impact event produced one
supply-chain event.

What NOOA offers, and what is off: `max_memory_mb` and `max_cpu_seconds` both
default to `0`, meaning disabled. Confirmed against `/proc/<pid>/limits`:
unlimited on both parent and worker. There is a wall-clock `cell_timeout` with
`timeout_grace_s` before the parent hard kills, plus a parent-side RSS
watchdog. `test_cpu_guard_kills_spin_loop` and
`test_wallclock_timeout_kills_cpu_bound_cell` both pass when the caps are set.

Data destruction is the other half of the README warning: "deleting files, or
modifying its environments." Landlock default-deny is the control, and
`test_file_write_closed_but_workspace_allowed` asserts it.

**The lesson I keep returning to.** `CPUQuota=600%` stopped the lockups and
destroyed generation throughput, six tokens in twenty-five minutes, because
CFS quota works in bursts and llama.cpp spin-waits at per-token barriers.
`AllowedCPUs=0-5` fixed it properly. A control can succeed at its stated goal
and break the system anyway, and you only find that by measuring the thing you
were protecting rather than the thing you were protecting it from.