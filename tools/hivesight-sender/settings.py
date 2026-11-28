"""The sender's settings tree, apart from GStreamer and the network: setting
one value or many, and what a voice preset comes to. Kept in a module of its
own so the tests can run it without the sender's libraries."""
from __future__ import annotations


def set_path(tree, path, value):
    *parents, leaf = path.split(".")
    node = tree
    for key in parents:
        node = node[key]
    if leaf not in node:
        raise KeyError(path)
    old = node[leaf]
    # Coerce to the existing type so a slider's "0.5" string can't sneak in.
    if isinstance(old, bool):
        value = bool(value)
    elif isinstance(old, (int, float)) and not isinstance(value, bool):
        value = type(old)(float(value)) if isinstance(old, float) else int(round(float(value)))
    node[leaf] = value
    return value


def set_many(tree, values):
    """Set every path in [values] (a dict of dotted path to value), skipping
    any that's unknown or can't be made the right type: (the values as set,
    the paths skipped)."""
    done, skipped = {}, []
    if not isinstance(values, dict):
        return done, skipped
    for path, value in values.items():
        try:
            done[path] = set_path(tree, str(path), value)
        except (KeyError, TypeError, ValueError):
            skipped.append(str(path))
    return done, skipped


def preset_values(preset, default_voice, mic_keys):
    """What a voice preset comes to: every effect the preset doesn't mention
    at its default (so one preset's ring or chorus doesn't carry into the
    next), the preset's own on top. The mic's own settings aren't part of it."""
    out = {k: v for k, v in default_voice.items() if k not in mic_keys}
    for k, v in preset.items():
        if k in default_voice and k not in mic_keys:
            out[k] = v
    return out


def resolved_presets(presets, default_voice, mic_keys):
    return {name: preset_values(p, default_voice, mic_keys) for name, p in presets.items()}
