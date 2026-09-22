"""Local override of the bundled ``zai`` provider profile.

Closes two z.ai rejections that the bundled stack cannot recover from. Both come
back as HTTP 400 with error code 1210 and the same misleading message:

    "This model always engages in thinking and cannot be disabled;
     please use low, high, or max"

1. **Thinking cannot be disabled on GLM-5.3.** When a turn hits thinking-only
   truncation, ``turn_truncation.py`` sets ``_ephemeral_reasoning_off`` so the
   continuation does not re-burn the reasoning budget. The bundled profile turns
   that into ``extra_body.thinking = {"type": "disabled"}``, which GLM-5.3
   rejects outright.

   Hermes *has* a recovery for exactly this (``turn_recovery.py`` →
   ``FailoverReason.reasoning_mandatory``), but it only fires on the literal
   string ``"reasoning is mandatory"`` — the Nous Portal / OpenRouter wording
   (``error_classifier.py``). z.ai phrases it differently, so the match fails,
   the error is classified as a non-retryable ``format_error``, and the turn
   dies. Rather than teach the classifier a new phrase (which would mean editing
   the image), this drops the disable before it is ever sent: omitting the field
   leaves the server default, which is thinking ON — the same end state the
   upstream recovery aims for.

2. **``reasoning_effort: medium`` is rejected on the standard endpoint.**
   ``agent/reasoning_effort.py`` declares ``GLM53_EFFORTS`` as
   low/medium/high/max, verified — per its own comment — against
   ``api.z.ai/api/coding/paas/v4``. On ``api.z.ai/api/paas/v4`` only low, high
   and max are accepted (probed live: medium and minimal both 400). The clamp
   below applies only off the coding endpoint, so upstream's vocabulary stays
   intact where it is correct.

Implemented by wrapping the registered profile's bound method rather than
subclassing it. The bundled profile keeps ownership of ``env_vars``, ``aliases``,
``base_url``, ``fallback_models`` and ``default_aux_model``, so none of that can
drift out of sync on upgrade — and if upstream fixes either bug, this degrades
to a no-op instead of fighting it.

Loaded from ``$HERMES_HOME/plugins/model-providers/zai/``; user plugins are
discovered after bundled ones and ``register_provider`` is last-writer-wins.
"""

from __future__ import annotations

# GLM-5.3 always reasons; spellings seen across relays.
_ALWAYS_THINKING = ("glm-5.3", "glm-5-3", "glm-5p3")
# What api.z.ai/api/paas/v4 actually accepts for those models.
_STANDARD_EFFORTS = ("low", "high", "max")
# Nearest ACCEPTED level, never escalating (mirrors clamp_effort semantics).
_DOWNGRADE = {"minimal": "low", "medium": "low", "xhigh": "max", "ultra": "max"}


def _always_thinking(model) -> bool:
    m = str(model or "").strip().lower()
    return any(tok in m for tok in _ALWAYS_THINKING)


def _is_coding_endpoint(base_url) -> bool:
    """True only for the coding-plan endpoint, where medium is genuinely valid.

    An unknown base_url counts as standard: the chat transport may pass None
    (the client already holds the URL), and this profile's own default is the
    standard endpoint — so the guard should apply unless we positively know
    otherwise.
    """
    return "coding" in str(base_url or "").lower()


def _install() -> None:
    from providers import get_provider_profile, register_provider

    profile = get_provider_profile("zai")
    if profile is None or getattr(profile, "_local_1210_guard", False):
        return

    inner = profile.build_api_kwargs_extras  # bound -> no recursion

    def guarded(*, reasoning_config=None, model=None, base_url=None, **context):
        extra_body, top_level = inner(
            reasoning_config=reasoning_config, model=model, base_url=base_url, **context
        )
        # Copy: the bundled method may hand back a shared dict.
        extra_body = dict(extra_body or {})
        top_level = dict(top_level or {})

        if not _always_thinking(model):
            return extra_body, top_level

        thinking = extra_body.get("thinking")
        if isinstance(thinking, dict) and thinking.get("type") == "disabled":
            extra_body.pop("thinking", None)

        if not _is_coding_endpoint(base_url):
            effort = top_level.get("reasoning_effort")
            if isinstance(effort, str) and effort.strip().lower() not in _STANDARD_EFFORTS:
                mapped = _DOWNGRADE.get(effort.strip().lower())
                if mapped:
                    top_level["reasoning_effort"] = mapped
                else:
                    top_level.pop("reasoning_effort", None)

        return extra_body, top_level

    profile.build_api_kwargs_extras = guarded
    profile._local_1210_guard = True
    register_provider(profile)


try:
    _install()
except Exception:  # never let a user plugin break provider discovery
    import logging

    logging.getLogger(__name__).warning(
        "zai 1210 guard failed to install; falling back to bundled behavior", exc_info=True
    )
