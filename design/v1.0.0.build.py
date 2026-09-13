#!/usr/bin/env python3
"""Builds design/v1.0.0.pen (Pencil document, format 2.17).

The document is a full redesign of the MenuCue settings window: corrected information
architecture (4 groups / 10 panes) plus a redesigned layout for every pane, the trackpad
rule editor and the menu-bar popover.

Run:  python3 design/v1.0.0.build.py
Then: python3 design/v1.0.0.build.py --check     (layout audit + SVG render)
"""

from __future__ import annotations

import json
import math
import os
import re
import sys
from typing import Any

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_PEN = os.path.join(HERE, "v1.0.0.pen")
OUT_SVG_DIR = os.path.join(HERE, ".v1.0.0.preview")

# --------------------------------------------------------------------------------------
# Design tokens
# --------------------------------------------------------------------------------------

TOKENS: dict[str, dict[str, str]] = {
    "bg-canvas": {"type": "color", "value": "#101014"},
    "bg-window": {"type": "color", "value": "#1E1F24"},
    "bg-sidebar": {"type": "color", "value": "#191A1F"},
    "bg-card": {"type": "color", "value": "#26272D"},
    "bg-inset": {"type": "color", "value": "#1B1C21"},
    "bg-elevated": {"type": "color", "value": "#2F3037"},
    "bg-hover": {"type": "color", "value": "#33343B"},
    "accent": {"type": "color", "value": "#0A84FF"},
    "accent-soft": {"type": "color", "value": "#0A84FF26"},
    "accent-line": {"type": "color", "value": "#0A84FF66"},
    "text-primary": {"type": "color", "value": "#F5F5F7"},
    "text-secondary": {"type": "color", "value": "#A6A7AF"},
    "text-tertiary": {"type": "color", "value": "#90919A"},  # 4.75:1 on card, 4.2:1 on chips
    "separator": {"type": "color", "value": "#3A3B42"},
    "success": {"type": "color", "value": "#32D74B"},
    "warning": {"type": "color", "value": "#FFD60A"},
    "danger": {"type": "color", "value": "#FF453A"},
    "font-ui": {"type": "string", "value": "Inter"},
    "font-mono": {"type": "string", "value": "SF Mono"},
}

# Window geometry — mirrors SettingsWindowView's own frame(minWidth:idealWidth:minHeight:
# idealHeight:) so the mockups are the size the shipping window actually opens at.
WIN_W, WIN_H = 900, 680
SIDEBAR_W = 212
CONTENT_PAD_V, CONTENT_PAD_H = 18, 24
CONTENT_W = WIN_W - SIDEBAR_W - CONTENT_PAD_H * 2  # 640
FOLD_Y = WIN_H  # content bottom marker for panes taller than the window

# --------------------------------------------------------------------------------------
# Primitives
# --------------------------------------------------------------------------------------

_ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
_seq = 0
_used: set[str] = set()


def nid() -> str:
    """Pencil uses short random-looking ids; deterministic here so diffs stay readable."""
    global _seq
    while True:
        _seq += 1
        n = _seq
        chars = []
        for _ in range(5):
            chars.append(_ALPHABET[n % len(_ALPHABET)])
            n //= len(_ALPHABET)
        out = "".join(chars)
        if out not in _used:
            _used.add(out)
            return out


def frame(name: str, children: list[dict] | None = None, **props) -> dict:
    node: dict[str, Any] = {"type": "frame", "id": nid(), "name": name}
    node.update(props)
    if children is not None:
        node["children"] = [c for c in children if c is not None]
    return node


def V(name: str, children: list[dict] | None = None, **props) -> dict:
    """Vertical stack. `layout` is explicit because Pencil defaults to horizontal."""
    props.pop("layout", None)
    return frame(name, children, layout="vertical", **props)


def H(name: str, children: list[dict] | None = None, **props) -> dict:
    return frame(name, children, **props)


def text(
    content: str,
    size: int = 13,
    color: str = "$text-primary",
    weight: str = "normal",
    name: str = "t",
    **props,
) -> dict:
    node = {
        "type": "text",
        "id": nid(),
        "name": name,
        "fill": color,
        "content": content,
        "fontFamily": "$font-ui",
        "fontSize": size,
        "fontWeight": weight,
    }
    node.update(props)
    # A declared width narrower than the longest wrapped line would clip glyphs; grow to fit.
    w = node.get("width")
    if isinstance(w, (int, float)) and w > 0:
        longest = max((text_width(l, size) for l in wrap_lines(content, size, w)), default=0)
        if longest > w + 0.5:
            node["width"] = round(longest, 1)
    return node


def wrap(content: str, size: float = 13, color: str = "$text-tertiary",
         width: Any = "fill_container", **kw) -> dict:
    """Text that fills the row and wraps; `textGrowth: fixed-width` is what makes it wrap."""
    return text(content, size, color, textGrowth="fixed-width", width=width, **kw)


def icon(glyph: str, size: int = 15, color: str = "$text-secondary", name: str = "i") -> dict:
    return {
        "type": "icon",
        "id": nid(),
        "name": name,
        "width": size,
        "height": size,
        "icon": glyph,
        "library": "lucide",
        "fill": color,
    }


def ellipse(size: int, color: str, name: str = "dot") -> dict:
    return {"type": "ellipse", "id": nid(), "name": name, "fill": color, "width": size, "height": size}


def rect(width: Any, height: int, color: str, name: str = "r", **props) -> dict:
    node: dict[str, Any] = {
        "type": "rectangle",
        "id": nid(),
        "name": name,
        "width": width,
        "height": height,
        "fill": color,
    }
    node.update(props)
    return node


_REF_ALIAS = {"NAVITEM": "nav-item"}


def _child_ids(comp: dict) -> dict[str, str]:
    ids: dict[str, str] = {}

    def walk(n: dict) -> None:
        name = n.get("name")
        if name and name not in ids:
            ids[name] = n["id"]
        for c in n.get("children", []) or []:
            walk(c)

    walk(comp)
    return ids


def href(component_key: str, name: str, **props) -> dict:
    """Instance of a component. Pencil keys descendants overrides by child node id, so
    symbolic names (LABEL / ICON / VALUE) are resolved against the component definition."""
    key = _REF_ALIAS.get(component_key, component_key.lower().replace("_", "-"))
    comp = C[key]
    node: dict[str, Any] = {"type": "ref", "id": nid(), "ref": comp["id"], "name": name}
    node.update(props)
    if "descendants" in node:
        ids = _child_ids(comp)
        resolved: dict[str, Any] = {}
        for child_name, override in node["descendants"].items():
            if child_name not in ids:
                raise KeyError(f"component {key!r} has no child named {child_name!r}; "
                               f"available: {sorted(k for k in ids if k.isupper())}")
            resolved[ids[child_name]] = override
        node["descendants"] = resolved
    return node


def notes(note_id: str, x: int, y: int, content: str) -> dict:
    return {"type": "note", "id": note_id, "name": note_id, "x": x, "y": y, "width": 0, "height": 0,
            "content": content}


# --------------------------------------------------------------------------------------
# Component library (reusable leaves only — page composition stays inline so every pane is
# readable in the Pencil outline without chasing five levels of refs)
# --------------------------------------------------------------------------------------

C: dict[str, dict] = {}


def component(key: str, name: str, node: dict) -> dict:
    node["name"] = name
    node["reusable"] = True
    C[key] = node
    return node


def _toggle(key: str, on: bool, name: str) -> dict:
    return component(
        key,
        name,
        frame(
            name,
            [ellipse(16, "#FFFFFF", "knob")],
            width=36,
            height=20,
            fill="$accent" if on else "$bg-elevated",
            cornerRadius=10,
            padding=2,
            justifyContent="end" if on else "start",
            alignItems="center",
        ),
    )


def build_components() -> list[dict]:
    C.clear()
    out: list[dict] = []

    out.append(_toggle("toggle-on", True, "comp/toggle/on"))
    out.append(_toggle("toggle-off", False, "comp/toggle/off"))

    out.append(
        component(
            "checkbox-on",
            "comp/checkbox/on",
            H("comp/checkbox/on", [icon("check", 10, "#FFFFFF", "mark")],
              width=15, height=15, fill="$accent", cornerRadius=4,
              justifyContent="center", alignItems="center"),
        )
    )
    out.append(
        component(
            "checkbox-off",
            "comp/checkbox/off",
            H("comp/checkbox/off", [], width=15, height=15, fill="$bg-window",
              cornerRadius=4, stroke="$separator", strokeWidth=1),
        )
    )

    out.append(
        component(
            "badge",
            "comp/badge",
            H("comp/badge", [text("标签", 11, "$text-secondary", name="LABEL")],
              fill="$bg-elevated", cornerRadius=5, gap=4, padding=[3, 8], alignItems="center"),
        )
    )
    out.append(
        component(
            "status-chip",
            "comp/status-chip",
            H("comp/status-chip", [ellipse(7, "$success", "dot"), text("正常", 11, "$text-secondary", name="LABEL")],
              fill="$bg-card", cornerRadius=12, gap=6, padding=[4, 10], alignItems="center"),
        )
    )
    out.append(
        component(
            "btn-primary",
            "comp/btn/primary",
            H("comp/btn/primary", [text("按钮", 13, "#FFFFFF", name="LABEL")],
              fill="$accent", cornerRadius=7, gap=6, padding=[6, 14],
              justifyContent="center", alignItems="center"),
        )
    )
    out.append(
        component(
            "btn-secondary",
            "comp/btn/secondary",
            H("comp/btn/secondary", [text("按钮", 13, "$text-primary", name="LABEL")],
              fill="$bg-elevated", cornerRadius=7, gap=6, padding=[6, 14],
              justifyContent="center", alignItems="center"),
        )
    )
    out.append(
        component(
            "btn-danger",
            "comp/btn/danger",
            H("comp/btn/danger", [text("按钮", 13, "$danger", name="LABEL")],
              fill="$bg-card", cornerRadius=7, gap=6, padding=[6, 14],
              justifyContent="center", alignItems="center"),
        )
    )
    out.append(
        component(
            "btn-link",
            "comp/btn/link",
            H("comp/btn/link", [text("打开设置", 12, "$accent", name="LABEL")],
              gap=6, padding=[4, 0], alignItems="center"),
        )
    )
    out.append(
        component(
            "text-field",
            "comp/field/text",
            H("comp/field/text", [
                text("EEE MMM d", 13, "$text-primary", name="VALUE",
                     fontFamily="$font-mono", width=120, textGrowth="fixed-width"),
            ], fill="$bg-inset", cornerRadius=7, padding=[7, 10], alignItems="center",
                stroke="$separator", strokeWidth=1),
        )
    )
    out.append(
        component(
            "text-field-mono",
            "comp/field/format",
            H("comp/field/format", [
                text("EEE MMM d", 13, "$text-primary", name="VALUE",
                     fontFamily="$font-mono", width="fill_container", textGrowth="fixed-width"),
            ], width=150, fill="$bg-inset", cornerRadius=7, padding=[7, 10], alignItems="center",
                stroke="$separator", strokeWidth=1),
        )
    )
    out.append(
        component(
            "segmented",
            "comp/segmented",
            H("comp/segmented", [
                H("seg-a", [text("选项 A", 12, "#FFFFFF", name="l")], fill="$accent",
                  cornerRadius=5, padding=[5, 12], justifyContent="center", alignItems="center"),
                H("seg-b", [text("选项 B", 12, "$text-secondary", name="l")],
                  cornerRadius=5, padding=[5, 12], justifyContent="center", alignItems="center"),
            ], fill="$bg-inset", cornerRadius=7, gap=2, padding=2, alignItems="center"),
        )
    )
    out.append(
        component(
            "picker",
            "comp/picker",
            H("comp/picker", [
                text("选项", 12, "$text-primary", name="VALUE"),
                icon("chevron-down", 12, "$text-tertiary", "chev"),
            ], fill="$bg-inset", cornerRadius=7, gap=8, padding=[6, 10], alignItems="center",
                stroke="$separator", strokeWidth=1),
        )
    )
    out.append(
        component(
            "stepper",
            "comp/stepper",
            H("comp/stepper", [
                H("box", [icon("chevron-up", 11, "$text-secondary", "up")], width=18, height=12,
                  justifyContent="center", alignItems="center"),
                H("box2", [icon("chevron-down", 11, "$text-secondary", "dn")], width=18, height=12,
                  justifyContent="center", alignItems="center"),
            ], layout="vertical", fill="$bg-inset", cornerRadius=5, alignItems="center",
                stroke="$separator", strokeWidth=1),
        )
    )
    out.append(
        component(
            "row",
            "comp/row",
            H("comp/row", [
                V("texts", [text("设置项", 13, "$text-primary", weight="500", name="title")],
                  width="fill_container", gap=3),
                H("control", [], gap=8, alignItems="center"),
            ], width="fill_container", gap=12, padding=[10, 14], alignItems="center"),
        )
    )
    out.append(
        component(
            "table-head",
            "comp/table-head",
            H("comp/table-head", [text("列", 11, "$text-tertiary", name="c")],
              width="fill_container", gap=12, padding=[7, 14], alignItems="center",
              fill="$bg-inset"),
        )
    )
    out.append(
        component(
            "list-row",
            "comp/list-row",
            H("comp/list-row", [
                icon("grip-vertical", 14, "$text-tertiary", "handle"),
                V("texts", [
                    text("条目", 13, "$text-primary", weight="500", name="title"),
                    text("副标题", 11, "$text-tertiary", name="desc"),
                ], width="fill_container", gap=2),
            ], width="fill_container", gap=10, padding=[8, 14], alignItems="center"),
        )
    )
    out.append(
        component(
            "nav-item",
            "comp/nav-item",
            H("comp/nav-item", [
                icon("dot", 15, "$text-secondary", "ICON"),
                text("项目", 13, "$text-secondary", name="LABEL"),
            ], width=186, cornerRadius=6, gap=9, padding=[6, 9], alignItems="center"),
        )
    )
    out.append(
        component(
            "card",
            "comp/card",
            V("comp/card", [
                V("head", [
                    text("分区标题", 13, "$text-primary", weight="600", name="title"),
                    wrap("", 11, "$text-tertiary", name="desc"),
                ], width="fill_container", gap=3),
            ], width="fill_container", fill="$bg-card", cornerRadius=10, gap=10, padding=14),
        )
    )
    return out


# --------------------------------------------------------------------------------------
# Text metrics + layout solver
# --------------------------------------------------------------------------------------

# Advance widths (em fractions) for the Latin ranges we actually print; CJK is full width.
_NARROW = set("iljtfrI.,:;'|!()[]{}`\" ")
_WIDE = set("mwMW@")
_DIGITISH = set("0123456789")


def char_em(ch: str) -> float:
    if ch in _NARROW:
        return 0.30
    if ch in ("《", "》", "“", "”"):
        return 1.0
    if ch in _WIDE:
        return 0.86
    if ch in _DIGITISH:
        return 0.56
    o = ord(ch)
    if o > 0x2E80:  # CJK, kana, fullwidth forms
        return 1.0
    if ch.isupper():
        return 0.62
    return 0.52


def text_width(s: str, size: float, spacing: float = 0.0) -> float:
    return sum(char_em(c) * size + spacing for c in s)


def wrap_lines(s: str, size: float, avail: float, spacing: float = 0.0) -> list[str]:
    """Greedy wrap. CJK breaks anywhere, Latin at spaces — same rule the SVG renderer uses."""
    if avail <= 0:
        return [s]
    lines: list[str] = []
    cur = ""
    for tok in _tokenize(s):
        if text_width(cur + tok, size, spacing) <= avail or not cur:
            cur += tok
            continue
        lines.append(cur.rstrip())
        cur = tok.lstrip()
    if cur.strip() or not lines:
        lines.append(cur.rstrip())
    return lines


def _tokenize(s: str) -> list[str]:
    """Split into break-opportunity units: a CJK char, or a run of latin + one trailing space."""
    out: list[str] = []
    buf = ""
    for ch in s:
        if ord(ch) > 0x2E80:
            if buf:
                out.append(buf)
                buf = ""
            out.append(ch)
        elif ch == " ":
            buf += ch
            out.append(buf)
            buf = ""
        else:
            buf += ch
    if buf:
        out.append(buf)
    return out


LINE_H = 1.47  # measured off Pen's own renderer: a single line box is fontSize x 1.46-1.48


def resolve(node: dict, comps: dict[str, dict]) -> dict:
    """Expand refs into private copies with descendant overrides applied, ONCE per node.

    The .pen output keeps refs; measurement and preview run on this expanded copy so a
    ref's box computed here is the same box the renderer and the auditor read."""
    if node.get("type") != "ref":
        return node
    base = json.loads(json.dumps(comps[node["ref"]]))
    overrides = node.get("descendants", {}) or {}
    node_over = {k: v for k, v in node.items()
                 if k not in ("type", "ref", "descendants", "name", "id")}

    def apply(n: dict) -> None:
        if n.get("id") in overrides:
            n.update(overrides[n["id"]])
        for c in n.get("children", []) or []:
            apply(c)

    apply(base)
    children = base.pop("children", [])
    base.update(node_over)
    if children:
        base["children"] = children
    base.pop("reusable", None)
    base["name"] = node.get("name", base.get("name"))
    return base


def expand(node: dict, comps: dict[str, dict]) -> dict:
    """Deep-expand a whole page once, so measurement never re-resolves a ref."""
    n = resolve(node, comps)
    out = dict(n)
    if n.get("children") is not None:
        out["children"] = [expand(c, comps) for c in n["children"]]
    return out


def _pad(node: dict) -> tuple[float, float, float, float]:
    pad = node.get("padding", 0)
    if isinstance(pad, (int, float)):
        return float(pad), float(pad), float(pad), float(pad)
    if len(pad) == 2:
        return float(pad[0]), float(pad[1]), float(pad[0]), float(pad[1])
    return (float(pad[0]), float(pad[1]), float(pad[2]), float(pad[3]))


def num(v) -> float | None:
    return None if v in (None, "fill_container") else float(v)


def hug_w(node: dict) -> float:
    """Width a node wants when nobody constrains it (single-line text, fixed controls)."""
    t = node.get("type")
    if t == "text":
        return text_width(node.get("content", ""), node.get("fontSize", 13),
                          node.get("letterSpacing", 0))
    w = num(node.get("width"))
    if w is not None:
        return w
    if t in ("icon", "ellipse", "rectangle"):
        return num(node.get("height")) or 0.0
    kids = node.get("children", []) or []
    if not kids:
        return 0.0
    pt, pr, pb, pl = _pad(node)
    gap = float(node.get("gap", 0))
    if node.get("layout") == "vertical":
        return max(hug_w(k) for k in kids) + pl + pr
    return sum(hug_w(k) for k in kids) + gap * (len(kids) - 1) + pl + pr


def layout(node: dict, x: float, y: float, avail_w: float | None, avail_h: float | None) -> dict:
    t = node.get("type")
    pt, pr, pb, pl = _pad(node)

    if t in ("text", "icon", "ellipse", "rectangle", "note"):
        if t == "text":
            size = node.get("fontSize", 13)
            ls = node.get("letterSpacing", 0)
            w = num(node.get("width"))
            if w is None:
                if node.get("width") == "fill_container":
                    w = avail_w if avail_w is not None else text_width(node.get("content", ""), size, ls)
                else:
                    w = text_width(node.get("content", ""), size, ls)
            node["_lines"] = wrap_lines(node.get("content", ""), size, w, ls) or [""]
            h = num(node.get("height")) or round(len(node["_lines"]) * size * LINE_H)
        else:
            w = num(node.get("width"))
            h = num(node.get("height"))
            if w is None:
                w = h or 0.0
            if h is None:
                h = w
        node["_box"] = (x, y, float(w), float(h))
        return node

    kids = node.get("children", []) or []
    vertical = node.get("layout") == "vertical"
    gap = float(node.get("gap", 0))

    own_w = num(node.get("width"))
    if own_w is None and node.get("width") == "fill_container":
        own_w = avail_w
    if own_w is None:
        own_w = hug_w({**node, "width": None})
    inner_w = own_w - pl - pr

    # 1. hand every child a width, so wrapped heights are computed against the real column
    widths: list[float] = []
    fill_idx = [i for i, k in enumerate(kids) if k.get("width") == "fill_container"]
    fixed_total = sum(hug_w(k) for k in kids if k.get("width") != "fill_container")
    if not vertical:
        leftover = inner_w - fixed_total - gap * max(0, len(kids) - 1)
        share = max(0.0, leftover) / len(fill_idx) if fill_idx else 0.0
    for i, k in enumerate(kids):
        if k.get("width") == "fill_container":
            widths.append(inner_w if vertical else share)
        else:
            widths.append(hug_w(k))

    # 2. heights against those widths
    heights: list[float] = []
    for k, w in zip(kids, widths):
        h = num(k.get("height"))
        if h is None:
            h = measure_height(k, w, None)
        heights.append(h)

    own_h = num(node.get("height"))
    if own_h is None and node.get("height") == "fill_container":
        own_h = avail_h
    if own_h is None:
        content = (sum(heights) + gap * max(0, len(kids) - 1)) if vertical else (max(heights) if heights else 0)
        own_h = content + pt + pb
        floor_h = num(node.get("_min_h"))
        if floor_h:
            own_h = max(own_h, floor_h)
    inner_h = own_h - pt - pb

    # 3. fill_container children absorb the slack left over in this axis
    fill_h_idx = [i for i, k in enumerate(kids) if k.get("height") == "fill_container"]
    if vertical:
        slack = inner_h - (sum(heights) + gap * max(0, len(kids) - 1))
        if fill_h_idx and slack > 0:
            each = slack / len(fill_h_idx)
            for i in fill_h_idx:
                heights[i] += each
    elif fill_h_idx:
        for i in fill_h_idx:
            heights[i] = max(heights[i], inner_h)

    # 4. justify + place
    content_h = (sum(heights) + gap * max(0, len(kids) - 1)) if vertical else (max(heights) if heights else 0)
    just = node.get("justifyContent", "start")
    if vertical and kids:
        if just == "center":
            cursor = y + pt + max(0.0, (inner_h - content_h) / 2)
        elif just == "end":
            cursor = y + pt + max(0.0, inner_h - content_h)
        else:
            cursor = y + pt
    else:
        cursor = x + pl
    ai = node.get("alignItems", "start")

    for i, k in enumerate(kids):
        kw, kh = widths[i], heights[i]
        if vertical:
            cx = x + pl
            if ai == "center":
                cx = x + pl + (inner_w - kw) / 2
            elif ai == "end":
                cx = x + pl + (inner_w - kw)
            cy = cursor
            cursor += kh + gap
        else:
            cy = y + pt
            if ai == "center":
                cy = y + pt + (inner_h - kh) / 2
            elif ai == "end":
                cy = y + pt + (inner_h - kh)
            cx = cursor
            cursor += kw + gap
        # width/height are forced here so a fill_container child does not re-hug inside layout()
        probe = dict(k)
        probe["width"] = kw
        probe["height"] = kh
        layout(probe, cx, cy, kw, kh)
        k["_box"] = probe.get("_box")
        k["_lines"] = probe.get("_lines")
        for c, pc in zip(k.get("children", []) or [], probe.get("children", []) or []):
            _absorb(c, pc)

    node["_box"] = (x, y, float(own_w), float(own_h))
    return node


def _absorb(raw: dict, solved: dict) -> None:
    """Copy computed geometry from the probe tree back onto the tree the renderer walks."""
    raw["_box"] = solved.get("_box")
    raw["_lines"] = solved.get("_lines")
    for c, pc in zip(raw.get("children", []) or [], solved.get("children", []) or []):
        _absorb(c, pc)


def measure_height(node: dict, width: float, avail_h: float | None) -> float:
    probe = json.loads(json.dumps(node))
    probe["width"] = width
    layout(probe, 0, 0, width, avail_h)
    return probe["_box"][3]


def solve(page: dict, comps: dict[str, dict]) -> dict:
    """Expand a page once and lay it out; the returned tree carries `_box` everywhere."""
    tree = expand(json.loads(json.dumps(page)), comps)
    layout(tree, 0, 0, num(tree.get("width")), num(tree.get("height")))
    return tree


# --------------------------------------------------------------------------------------
# SVG preview + layout audit
# --------------------------------------------------------------------------------------

def _col(fill: str | None) -> str | None:
    if not fill:
        return None
    if fill.startswith("$"):
        v = TOKENS.get(fill[1:], {}).get("value")
        return v if isinstance(v, str) else None
    return fill


def _alpha(hexcol: str) -> float:
    return int(hexcol[7:9], 16) / 255 if len(hexcol) == 9 else 1.0


def render_svg(page: dict, comps: dict[str, dict], path: str) -> None:
    solved = solve(json.loads(json.dumps(page)), comps)
    w = int(solved["_box"][2])
    h = int(math.ceil(solved["_box"][3]))
    out: list[str] = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
        f'<rect width="{w}" height="{h}" fill="{_col(solved.get("fill")) or "#101014"}"/>',
    ]

    def esc(s: str) -> str:
        return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

    def walk(n: dict) -> None:
        t = n.get("type")
        x, y, bw, bh = n["_box"]
        if t == "note":
            return
        if t == "frame":
            f = _col(n.get("fill"))
            if f:
                op = f' fill-opacity="{_alpha(f):.3f}"' if len(f) == 9 else ""
                r = n.get("cornerRadius", 0)
                out.append(
                    f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{bh:.1f}" rx="{r}" '
                    f'fill="{f[:7]}"{op}/>'
                )
            if n.get("stroke"):
                s = _col(n["stroke"])
                out.append(
                    f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{bh:.1f}" '
                    f'rx="{n.get("cornerRadius", 0)}" fill="none" stroke="{s[:7]}" '
                    f'stroke-width="{n.get("strokeWidth", 1)}"/>'
                )
        elif t == "rectangle":
            out.append(
                f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{bh:.1f}" '
                f'rx="{n.get("cornerRadius", 0)}" fill="{(_col(n.get("fill")) or "#333")[:7]}"/>'
            )
        elif t == "ellipse":
            out.append(
                f'<ellipse cx="{x + bw / 2:.1f}" cy="{y + bh / 2:.1f}" rx="{bw / 2:.1f}" '
                f'ry="{bh / 2:.1f}" fill="{_col(n.get("fill"))}"/>'
            )
        elif t == "icon":
            # Placeholder glyph box; real icon set lives in Pencil.
            out.append(
                f'<rect x="{x + bw * 0.15:.1f}" y="{y + bh * 0.15:.1f}" width="{bw * 0.7:.1f}" '
                f'height="{bh * 0.7:.1f}" rx="2" fill="none" stroke="{_col(n.get("fill"))}" '
                f'stroke-width="1" stroke-dasharray="2 2"/>'
            )
        elif t == "text":
            size = n.get("fontSize", 13)
            weight = n.get("fontWeight", "normal")
            fam = _col(n.get("fontFamily")) or "Inter"
            fill = _col(n.get("fill")) or "#fff"
            ls = n.get("letterSpacing", 0)
            for i, line in enumerate(n.get("_lines") or [n.get("content", "")]):
                ly = y + size * (i + 0.92) - (0 if i == 0 else 0)
                ly = y + size * 0.86 + i * size * LINE_H + size * 0.24
                out.append(
                    f'<text x="{x:.1f}" y="{ly:.1f}" font-family="{fam}" font-size="{size}" '
                    f'font-weight="{weight}" letter-spacing="{ls}" fill="{fill[:7]}">{esc(line)}</text>'
                )
        for c in n.get("children", []) or []:
            if c.get("_box"):
                walk(c)

    walk(solved)
    # fold marker: where the real 680pt window bottom cuts the scrolling content
    if h > WIN_H:
        out.append(
            f'<line x1="0" y1="{WIN_H}" x2="{w}" y2="{WIN_H}" stroke="#FF453A" '
            f'stroke-width="1" stroke-dasharray="6 4"/>'
        )
        out.append(
            f'<text x="{w - 8}" y="{WIN_H - 6}" font-family="Inter" font-size="10" fill="#FF453A" '
            f'text-anchor="end">window bottom (680)</text>'
        )
    out.append("</svg>")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write("\n".join(out))


def audit(page: dict, comps: dict[str, dict]) -> list[str]:
    """Report nodes that escape their parent box, plus the pane's total content height."""
    solved = solve(json.loads(json.dumps(page)), comps)
    problems: list[str] = []

    def walk(n: dict, parent: dict | None) -> None:
        if n.get("_box") and parent and parent.get("_box") and parent.get("clip"):
            x, y, w, h = n["_box"]
            px, py, pw, ph = parent["_box"]
            if x + w > px + pw + 0.5 or x < px - 0.5 or y + h > py + ph + 0.5:
                problems.append(
                    f"{page['name']} :: '{n.get('name')}' escapes '{parent.get('name')}' "
                    f"(child {x:.0f},{y:.0f} {w:.0f}x{h:.0f} vs parent {px:.0f},{py:.0f} {pw:.0f}x{ph:.0f})"
                )
        for c in n.get("children", []) or []:
            if c.get("_box"):
                walk(c, n)

    walk(solved, None)
    return problems


def page_height(page: dict, comps: dict[str, dict]) -> float:
    return solve(json.loads(json.dumps(page)), comps)["_box"][3]


# --------------------------------------------------------------------------------------
# Document assembly
# --------------------------------------------------------------------------------------

def layout_pages(extras: list[dict], pages: list[dict]) -> None:
    """Extras stacked at the top-left, then window frames in two columns, notes above each."""
    col_w, gutter, note_h = WIN_W, 240, 64
    y = 0
    for e in extras:
        e["x"] = 0
        e["y"] = y
        y += page_height(e, COMPS) + 140
    base = y + 60
    ys = [base, base]
    for i, p in enumerate(pages):
        col = i % 2
        p["x"] = col * (col_w + gutter)
        p["y"] = ys[col]
        ys[col] += page_height(p, COMPS) + 150
        nid_ = p.get("_note_id")
        if nid_:
            doc_notes.append(notes(nid_, p["x"], p["y"] - note_h + 8, p.get("_note_text", "")))


COMPS: dict[str, dict] = {}
doc_notes: list[dict] = []


def _strip_private(node: dict) -> None:
    """Builder-only bookkeeping (`_box`, `_lines`, `_min_h`, `_note_*`) never ships."""
    for k in [k for k in node if k.startswith("_")]:
        del node[k]
    for c in node.get("children", []) or []:
        _strip_private(c)


def _bake_root_height(node: dict) -> None:
    """Ship a root screen's solved height as a number.

    A root frame left with no `height` is resolved by Pen to `fit_content(0)`,
    which collapses the screen to 0px and — because its children are
    `fill_container` on the cross axis — takes everything inside down with it
    (verified: screen C rendered 1800x1 px, i.e. blank). The SVG previews never
    caught this because they draw the solver's own `_box`, so they agree with
    the builder by construction and are not an independent check.
    """
    if node.get("height") is None:
        node["height"] = round(solve(node, COMPS)["_box"][3])


def build_document(pages: list[dict], extras: list[dict]) -> dict:
    global COMPS, doc_notes
    comps = list(C.values())  # built once, up front, so refs can carry real ids
    COMPS = {c["id"]: c for c in comps}
    doc_notes = []
    for node in pages + extras:
        _bake_root_height(node)
    layout_pages(extras, pages)
    children = json.loads(json.dumps(comps + extras + pages + doc_notes))
    for node in children:
        _strip_private(node)
    return {
        "version": "2.17",
        "children": children,
        "variables": TOKENS,
        "fileToken": "b1c0e5a4-7d2f-4c66-9a10-3f5e8d0a1c44",
    }


def main() -> int:
    pages, extras = build_pages()
    doc = build_document(pages, extras)
    with open(OUT_PEN, "w") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    problems: list[str] = []
    for p in pages + extras:
        solved_h = page_height(p, COMPS)
        problems.extend(audit(p, COMPS))
        print(f"  {p['name']:<46} {int(p['width'])}x{int(solved_h)}")
        svg = os.path.join(OUT_SVG_DIR, re.sub(r"[^0-9A-Za-z]+", "-", p["name"]).strip("-") + ".svg")
        render_svg(p, COMPS, svg)
    if problems:
        print("\nLAYOUT PROBLEMS")
        for p in problems:
            print("  " + p)
    print(f"\nwrote {OUT_PEN} ({os.path.getsize(OUT_PEN)} bytes)")
    return 0


# --------------------------------------------------------------------------------------
# Page DSL: the settings window scaffold + the row/card vocabulary every pane is built from
# --------------------------------------------------------------------------------------

NAV = [
    ("显示", [("menuBar", "菜单栏", "timer"), ("panel", "面板", "layout-dashboard"),
            ("calendar", "日历", "calendar")]),
    ("交互与动作", [("trackpad", "触控板", "touchpad"), ("hotkeys", "快捷键", "keyboard"),
                ("actionCenter", "动作库", "zap")]),
    ("提醒", [("alerts", "提醒规则", "bell")]),
    ("系统", [("power", "电源", "battery-charging"), ("timeZone", "时间与区域", "globe"),
            ("general", "通用", "settings-2"), ("about", "关于", "info")]),
]


def sidebar(active: str) -> dict:
    groups = []
    for gname, items in NAV:
        kids = [V("gl", [text(gname, 10, "$text-tertiary", letterSpacing=1, name="t")],
                  width="fill_container", padding=[2, 9])]
        for key, label, glyph in items:
            on = key == active
            kids.append(
                href("NAVITEM", f"nav-{key}",
                     descendants={
                         "ICON": {"icon": glyph, "fill": "#FFFFFF" if on else "$text-secondary"},
                         "LABEL": {"content": label, "fill": "#FFFFFF" if on else "$text-secondary"},
                     },
                     fill="$accent" if on else None,
                     width="fill_container")
            )
            if on:
                pass
        groups.append(V(f"group-{gname}", kids, width="fill_container", gap=2))
    return V("sidebar", [
        H("traffic", [ellipse(11, "#FF5F57"), ellipse(11, "#FEBC2E"), ellipse(11, "#28C840")],
          gap=7, padding=2),
        H("search", [icon("search", 13, "$text-tertiary", "i"),
                     text("搜索设置", 12, "$text-tertiary")],
          width="fill_container", fill="$bg-card", cornerRadius=7, gap=6, padding=[6, 9],
          alignItems="center"),
        V("nav", groups, width="fill_container", gap=14),
    ], width=SIDEBAR_W, height="fill_container", fill="$bg-sidebar", layout="vertical",
        gap=14, padding=[14, 12])


def pane_header(title: str, subtitle: str, glyph: str, right: list[dict] | None = None,
                status: str | None = None) -> dict:
    left = H("titles", [
        H("title-row", [icon(glyph, 17, "$text-secondary", "glyph"),
                        text(title, 19, "$text-primary", "600", "title")],
          gap=8, alignItems="center"),
        wrap(subtitle, 12, "$text-secondary"),
    ], width="fill_container", layout="vertical", gap=4)
    tail: list[dict] = []
    if status:
        tail.append(H("status-chip", [ellipse(7, "$success", "dot"),
                                      text(status, 11, "$text-secondary")],
                      fill="$bg-card", cornerRadius=12, gap=6, padding=[4, 10], alignItems="center"))
    tail.extend(right or [])
    return H("header", [left] + tail, width="fill_container", gap=12, alignItems="center")


def card(title: str, desc: str | None = None, children: list[dict] | None = None,
         action: dict | None = None, tone: str = "$bg-card", gap: float = 0,
         padding: list[int] | None = None, pad: list[int] | None = None) -> dict:
    head_kids = [V("texts", [text(title, 13, "$text-primary", "600", "title")] +
                   ([wrap(desc, 11, "$text-tertiary")] if desc else []),
                   width="fill_container", gap=3)]
    if action:
        head_kids.append(action)
    head = H("card-head", head_kids, width="fill_container", gap=10, alignItems="center",
             padding=[0, 14] if children else 0)
    body = children or []
    return V(f"card-{title}", [head] + body, width="fill_container", fill=tone,
             cornerRadius=10, padding=padding or pad or [12, 0], gap=gap)


def sep() -> dict:
    return rect("fill_container", 1, "$separator", "sep")


def row(title: str, desc: str | None = None, control: list[dict] | None = None,
        control_width: float | None = None, stack: bool = False, **kw) -> dict:
    """One settings row: label (+explanation) on the left, control on the right."""
    title_node = text(title, 13, "$text-primary", "500", "title")
    texts = V("texts", [title_node] + ([wrap(desc, 11, "$text-tertiary", name="desc")] if desc else []),
              width="fill_container", gap=3)
    ctrl = V("control", control or [], gap=8, alignItems="center",
             width=control_width) if control else None
    if stack:
        return V("row", [texts, ctrl] if ctrl else [texts], width="fill_container",
                 gap=8, padding=[10, 14])
    kids = [texts] + ([ctrl] if ctrl else [])
    return H("row", kids, width="fill_container", gap=12, padding=[10, 14], alignItems="center")


def row_toggle(title: str, desc: str | None = None, on: bool = True, **kw) -> dict:
    return row(title, desc, [href("TOGGLE_ON" if on else "TOGGLE_OFF", "toggle")], **kw)


def row_picker(title: str, value: str, desc: str | None = None, **kw) -> dict:
    return row(title, desc, [
        H("picker", [text(value, 12, "$text-primary", "value"),
                     icon("chevron-down", 12, "$text-tertiary", "chev")],
          fill="$bg-inset", cornerRadius=7, gap=8, padding=[6, 10], alignItems="center",
          stroke="$separator", strokeWidth=1)
    ], **kw)


def row_stepper(title: str, value: str, desc: str | None = None, **kw) -> dict:
    return row(title, desc, [
        H("stepper-group", [text(value, 12, "$text-primary", "value"),
                            href("STEPPER", "stepper")],
          gap=7, alignItems="center"),
    ], **kw)


def row_value(title: str, value: str, desc: str | None = None, tone: str = "$text-secondary",
              **kw) -> dict:
    return row(title, desc, [text(value, 12, tone, "value")], **kw)


def row_button(title: str, button: str, desc: str | None = None, kind: str = "secondary",
               **kw) -> dict:
    comp = {"primary": "BTN_PRIMARY", "secondary": "BTN_SECONDARY", "danger": "BTN_DANGER"}[kind]
    return row(title, desc, [href(comp, "btn", descendants={"LABEL": {"content": button}})], **kw)


def row_link(title: str, label: str, desc: str | None = None, **kw) -> dict:
    return row(title, desc, [href("BTN_LINK", "btn", descendants={"LABEL": {"content": label}})], **kw)


def segmented(items: list[str], active: int = 0, width: float | None = None) -> dict:
    kids = []
    for i, it in enumerate(items):
        on = i == active
        kids.append(H(f"seg{i}",
                      [text(it, 12, "#FFFFFF" if on else "$text-secondary", "l")],
                      fill="$accent" if on else None, cornerRadius=5, padding=[5, 11],
                      justifyContent="center", alignItems="center"))
    return H("segmented", kids, width=width, fill="$bg-inset", cornerRadius=7, gap=2,
             padding=2, alignItems="center")


def row_segmented(title: str, items: list[str], active: int, desc: str | None = None,
                  width: float | None = None, **kw) -> dict:
    return row(title, desc, [segmented(items, active, width)], **kw)


def text_field(value: str, width: float = 150, mono: bool = True, placeholder: bool = False) -> dict:
    return H("field", [text(value, 12, "$text-tertiary" if placeholder else "$text-primary",
                            "value", fontFamily="$font-mono" if mono else "$font-ui",
                            width=width - 20, textGrowth="fixed-width")],
             fill="$bg-inset", cornerRadius=7, padding=[7, 10], alignItems="center",
             stroke="$separator", strokeWidth=1)


def row_field(title: str, value: str, desc: str | None = None, width: float = 150,
              mono: bool = True, placeholder: bool = False, **kw) -> dict:
    return row(title, desc, [text_field(value, width, mono, placeholder)], **kw)


def chip(label: str, tone: str = "$bg-elevated", color: str = "$text-secondary",
         glyph: str | None = None) -> dict:
    kids = ([icon(glyph, 11, color, "g")] if glyph else []) + [text(label, 11, color, "t")]
    return H("chip", kids, fill=tone, cornerRadius=5, gap=4, padding=[3, 8], alignItems="center")


def banner(title: str, desc: str | None = None, tone: str = "$warning", button: str | None = None,
           glyph: str = "alert-triangle") -> dict:
    kids = [icon(glyph, 15, tone, "g"),
            V("texts", [text(title, 12.5, "$text-primary", "500", "title")] +
              ([wrap(desc, 11, "$text-tertiary")] if desc else []),
              width="fill_container", gap=3)]
    if button:
        kids.append(href("BTN_SECONDARY", "btn", descendants={"LABEL": {"content": button}}))
    return H("banner", kids, width="fill_container", fill="$bg-card", cornerRadius=9, gap=10,
             padding=[11, 14], alignItems="center", stroke="$separator", strokeWidth=1)


def colw(weights: list[float], inner: float = 612, gap: float = 12) -> list[float]:
    """Column widths that exactly fill a table row's inner width: 612 - gaps."""
    total = inner - gap * (len(weights) - 1)
    share = sum(weights)
    return [round(total * w / share) for w in weights]


def table_head(columns: list[tuple[str, float]]) -> dict:
    kids = [H(f"c{i}", [text(name, 11, "$text-tertiary", "h")], width=w, alignItems="center")
            for i, (name, w) in enumerate(columns)]
    return H("table-head", kids, width="fill_container", gap=12, padding=[7, 14],
             fill="$bg-inset", alignItems="center")


def cell(node: dict, width: float) -> dict:
    raw = node.get("width")
    if raw is None or raw == "fill_container" or (isinstance(raw, (int, float)) and raw > width):
        node = dict(node, width="fill_container")
    return H("cell", [node], width=width, alignItems="center")


def table_row(cells: list[dict], widths: list[float] | None = None, **kw) -> dict:
    if widths:
        cells = [cell(c, widths[i]) for i, c in enumerate(cells)]
    return H("table-row", cells, width="fill_container", gap=12, padding=[9, 14],
             alignItems="center", **kw)


TABLE_COLS = {
    "trackpad_rules": [200, 150, 110, 116],
    "hotkeys": [110, 190, 90, 100, 74],
    "alerts": [116, 130, 150, 70, 60, 26],
    "wake_history": [160, 120, 308],
    "panel_tabs": [300, 200, 88],
}


def tbl_head(table: str, labels: list[str]) -> dict:
    return table_head(list(zip(labels, TABLE_COLS[table])))


def data_table(headers: list[tuple[str, float]], rows_data: list[list[dict]]) -> list[dict]:
    """Head + rows sharing one column-width computation, so cells cannot drift apart."""
    widths = colw([w for _, w in headers])
    out = [table_head([(name, widths[i]) for i, (name, _) in enumerate(headers)])]
    for i, r in enumerate(rows_data):
        if i:
            out.append(sep())
        out.append(table_row([cell(n, widths[j]) for j, n in enumerate(r)]))
    return out


def list_row(title: str, desc: str | None = None, control: list[dict] | None = None,
             handle: bool = True, glyph: str | None = None) -> dict:
    lead = []
    if handle:
        lead.append(icon("grip-vertical", 14, "$text-tertiary", "handle"))
    if glyph:
        lead.append(icon(glyph, 15, "$text-secondary", "glyph"))
    kids = lead + [V("texts", [text(title, 13, "$text-primary", "500", "title")] +
                     ([wrap(desc, 11, "$text-tertiary", name="desc")] if desc else []),
                     width="fill_container", gap=2)]
    kids += control or []
    return H("list-row", kids, width="fill_container", gap=10, padding=[9, 14],
             alignItems="center", fill="$bg-inset")


def empty_state(title: str, desc: str, button: str | None = None, glyph: str = "inbox") -> dict:
    kids = [icon(glyph, 22, "$text-tertiary", "g"),
            text(title, 13, "$text-secondary", "500", "title"),
            wrap(desc, 11, "$text-tertiary")]
    if button:
        kids.append(href("BTN_SECONDARY", "btn", descendants={"LABEL": {"content": button}}))
    return V("empty", kids, width="fill_container", gap=8, padding=[22, 14], alignItems="center")


def page(name: str, active: str, title: str, subtitle: str, glyph: str,
         sections: list[dict], status: str | None = None, right: list[dict] | None = None,
         note: str | None = None, note_id: str | None = None,
         justify: str | None = None) -> dict:
    """A settings-window frame. Height grows past 680 when the pane scrolls, and the
    renderer draws the real window bottom so overflow is visible instead of implied."""
    content = V("content", [pane_header(title, subtitle, glyph, right, status)] + sections,
                width="fill_container", height="fill_container", layout="vertical",
                gap=14, padding=[CONTENT_PAD_V, CONTENT_PAD_H],
                justifyContent=justify)
    fr = H(name, [sidebar(active), content], width=WIN_W, height=None, fill="$bg-window",
           cornerRadius=10, clip=True)
    fr["_min_h"] = WIN_H
    if note:
        fr["_note_id"] = note_id or f"note-{active}"
        fr["_note_text"] = note
    return fr


def rows(*items: dict) -> list[dict]:
    out: list[dict] = []
    for i, it in enumerate(items):
        if i:
            out.append(sep())
        out.append(it)
    return out


def kv(label: str, value: str, tone: str = "$text-secondary") -> dict:
    return H("kv", [text(label, 11, "$text-tertiary", "k"),
                    text(value, 11.5, tone, "500", "v")],
             width="fill_container", gap=8, alignItems="center")


def bullet(label: str, desc: str | None = None, glyph: str = "check", tone: str = "$success") -> dict:
    kids = [icon(glyph, 12, tone, "g"),
            V("texts", [text(label, 11.5, "$text-primary", "500", "title")] +
              ([wrap(desc, 11, "$text-tertiary")] if desc else []),
              width="fill_container", gap=2)]
    return H("bullet", kids, width="fill_container", gap=8, alignItems="start")


def ia_frame() -> dict:
    def group(title: str, tone: str, items: list[tuple[str, str]]) -> dict:
        kids = [H("head", [text(title, 11, tone, "600", "t")], padding=[2, 2])]
        for name, note in items:
            kids.append(H("item", [text(name, 12, "$text-primary", "500", "n")],
                          width="fill_container", gap=6, padding=[4, 10], fill="$bg-inset",
                          cornerRadius=6, alignItems="center")
                        if not note else
                        H("item", [text(name, 12, "$text-primary", "500", "n"),
                                   text(note, 11, "$text-tertiary", "note")],
                          width="fill_container", gap=8, padding=[4, 10], fill="$bg-inset",
                          cornerRadius=6, alignItems="center"))
        return V("group", kids, width="fill_container", gap=5)

    def column(title: str, subtitle: str, groups: list[dict], tone: str) -> dict:
        return V("col", [H("h", [text(title, 14, tone, "600", "t")], padding=[0, 2]),
                         wrap(subtitle, 11, "$text-tertiary")] + groups,
                 width="fill_container", gap=12)

    left = column("现状 · 3 组 10 项", "分组按实现层划分，同一件事被拆到不同组，跨组语义互相污染。", [
        group("界面", "$text-secondary", [
            ("菜单栏", "却内含 macOS 系统时区"),
            ("面板", "却内含全应用动效"),
            ("日历", ""),
            ("操作中心", "动作库不是界面外观"),
        ]),
        group("输入", "$text-secondary", [
            ("触控板", ""),
            ("快捷键", ""),
            ("提醒规则", "监控与投递，与输入无关"),
        ]),
        group("系统", "$text-secondary", [
            ("电源", ""),
            ("通用", "启动/更新/外观/语言/iCloud 混装"),
            ("关于", ""),
        ]),
    ], "$danger")

    right = column("v1.0.0 · 4 组 11 项", "按用户意图分组：显示什么 → 怎么触发 → 何时提醒 → 系统层面。", [
        group("显示", "$accent", [
            ("菜单栏", "时钟格式 · 轮播 · 世界时钟"),
            ("面板", "标签 · 状态卡片 · 采样"),
            ("日历", "事件源 · 月视图 · 节假日"),
        ]),
        group("交互与动作", "$accent", [
            ("触控板", "手势规则 = 触发器 → 动作"),
            ("快捷键", "全局快捷键绑定"),
            ("动作库", "原「操作中心」；被三方引用"),
        ]),
        group("提醒", "$accent", [
            ("提醒规则", "指标监控 · 渠道 · 模板"),
        ]),
        group("系统", "$accent", [
            ("电源", "助手 · pmset · 唤醒历史"),
            ("时间与区域", "新增：应用时区 + 系统时区 + 语言地区"),
            ("通用", "启动 · 更新 · 外观 · iCloud"),
            ("关于", ""),
        ]),
    ], "$success")

    fixes = [
        ("操作中心 → 动作库", "它被面板、手势、快捷键共同引用，与外观无关；与触控板/快捷键同组。"),
        ("提醒规则 → 提醒组", "它读取系统观测值并向外投递，不采集用户输入。"),
        ("动效 → 通用 › 外观", "它影响整个应用（含设置窗口），不属于面板。"),
        ("系统时区 → 时间与区域", "原先藏在菜单栏页，属机器级设置。"),
        ("macOS 语言地区 → 时间与区域", "原先混在通用页，与同步/更新无关。"),
        ("通用不再当垃圾桶", "只保留启动、更新、外观、iCloud 四件事。"),
    ]
    migrate = [
        ("dashboard", "仪表盘窗口（非设置页）"),
        ("overview", "面板"),
        ("dateAndTime", "菜单栏"),
        ("quickActions", "动作库"),
        ("notifications", "提醒规则"),
        ("appearance", "通用 › 外观"),
        ("language / iCloud", "时间与区域 / 通用 › iCloud"),
    ]

    return V("A · 信息架构 现状 → v1.0.0", [
        V("title", [text("MenuCue 设置 · 信息架构重构", 20, "$text-primary", "600", "t"),
                    wrap("分类的问题不是名字不好听，而是同一件事被放在两个地方、两件事被塞进一个地方。"
                         "下面每一项都能在源码里找到证据。", 12, "$text-secondary")],
          width="fill_container", gap=5),
        H("cols", [left, rect(1, "fill_container", "$separator"), right],
          width="fill_container", gap=26, alignItems="start"),
        rect("fill_container", 1, "$separator"),
        V("fixes", [text("六处修正", 13, "$text-primary", "600", "t")] +
          [bullet(a, b) for a, b in fixes], width="fill_container", gap=7),
        rect("fill_container", 1, "$separator"),
        V("migrate", [text("深链迁移（旧标识符 → 新归属）", 13, "$text-primary", "600", "t")] +
          [kv(a, b) for a, b in migrate], width="fill_container", gap=6),
        V("additions", [
            text("v1.0.0 新增的界面元素（源码中不存在，属提案）", 13, "$text-primary", "600", "t"),
            bullet("提醒规则 › 全局启用", "源码只有逐渠道、逐规则开关，没有总开关。", "plus", "$accent"),
            bullet("动作库 › 搜索与来源筛选之外的动作详情", "展示动作被哪些规则/快捷键引用。", "plus", "$accent"),
            bullet("动作库 › 破坏性动作运行前确认", "清空废纸篓已确认；其余保持显式「运行」。", "plus", "$accent"),
            bullet("电源 › 移除助手确认", "现状是立即移除、无确认。", "plus", "$accent"),
            bullet("快捷键 › 恢复内置默认", "现状只有静默合并，无恢复入口。", "plus", "$accent"),
        ], width="fill_container", gap=7),
    ], width=1180, gap=18, padding=24, fill="$bg-window", cornerRadius=10, layout="vertical")


def tokens_frame() -> dict:
    swatches = [("bg-window", "#1E1F24"), ("bg-sidebar", "#191A1F"), ("bg-card", "#26272D"),
                ("bg-inset", "#1B1C21"), ("bg-elevated", "#2F3037"), ("accent", "#0A84FF"),
                ("success", "#32D74B"), ("warning", "#FFD60A"), ("danger", "#FF453A"),
                ("separator", "#3A3B42")]
    sw = [V("s", [rect("fill_container", 26, f"${name}", "c"),
                  text(name, 10, "$text-tertiary", "l")], width=92, gap=5) for name, _ in swatches]
    comps_row = [
        ("开关", [href("TOGGLE_ON", "t"), href("TOGGLE_OFF", "t2")]),
        ("分段", [segmented(["结构化", "高级"], 1)]),
        ("选择器", [row_picker("", "日期在前，时间在后")]),
        ("步进", [H("s", [text("5", 12, "$text-primary", "v"), href("STEPPER", "st")],
                  fill="$bg-inset", cornerRadius=7, gap=6, padding=[4, 6], alignItems="center")]),
        ("标签", [chip("已保存", "$bg-elevated", "$success", "check"),
                 chip("需要权限", "$bg-elevated", "$warning", "alert-triangle")]),
        ("按钮", [href("BTN_PRIMARY", "b1", descendants={"LABEL": {"content": "保存"}}),
                 href("BTN_SECONDARY", "b2", descendants={"LABEL": {"content": "取消"}}),
                 href("BTN_DANGER", "b3", descendants={"LABEL": {"content": "移除"}})]),
    ]
    return V("B · 设计系统 · 组件与令牌", [
        text("组件与令牌", 20, "$text-primary", "600", "t"),
        wrap("窗口 900×680（与 SettingsWindowView 的 ideal size 一致），侧栏 212，内容区 640。"
             "行高 13/500 + 说明 11/tertiary；卡片圆角 10，控件圆角 7。", 12, "$text-secondary"),
        V("swatches", [text("颜色", 13, "$text-primary", "600", "t"),
                       H("row", sw[:5], gap=10, width="fill_container"),
                       H("row2", sw[5:], gap=10, width="fill_container")],
          width="fill_container", gap=8),
        rect("fill_container", 1, "$separator"),
        V("comps", [text("控件", 13, "$text-primary", "600", "t")] +
          [H("c", [text(name, 11, "$text-tertiary", "n")] + ctrl, width="fill_container", gap=14,
               alignItems="center") for name, ctrl in comps_row],
          width="fill_container", gap=10),
        rect("fill_container", 1, "$separator"),
        V("rows", [
            text("行与状态", 13, "$text-primary", "600", "t"),
            V("card", rows(
                row_toggle("开关行", "标题 13/500，说明 11/tertiary，控件右对齐。", True),
                row("值行", "只读读数用等宽字，避免数字跳动。", [text("1.5 秒", 12, "$text-secondary", "v")]),
                row_field("输入行", "EEE MMM d"),
            ), width="fill_container", fill="$bg-card", cornerRadius=10, padding=[12, 0], gap=0),
            banner("需要权限", "摆放或移动窗口的动作首次运行时会申请辅助功能权限。", "$warning",
                   "打开系统设置"),
            empty_state("暂无规则", "添加规则把手势连接到系统或应用动作。", "新建规则", "plus"),
        ], width="fill_container", gap=12),
    ], width=560, gap=18, padding=24, fill="$bg-window", cornerRadius=10, layout="vertical")


# --------------------------------------------------------------------------------------
# Panes
# --------------------------------------------------------------------------------------

def slider(pct: float, width: float = 180) -> dict:
    """The knob rides the right end of the filled run, so its position tracks `pct`."""
    filled = max(14.0, width * pct)  # never narrower than the knob itself
    rest = max(0.0, width - filled)
    return H("slider", [
        H("filled", [rect("fill_container", 4, "$accent", "bar", cornerRadius=2),
                     ellipse(13, "#FFFFFF", "knob")],
          width=filled, height=14, gap=0, alignItems="center"),
        H("rest", [rect("fill_container", 4, "$bg-elevated", "bar", cornerRadius=2)],
          width=rest, height=14, justifyContent="center") if rest else None,
    ], gap=0, alignItems="center")


def row_slider(title: str, value: str, pct: float, desc: str | None = None, **kw) -> dict:
    return row(title, desc, [
        H("slider-group", [text(value, 12, "$text-secondary", "v"), slider(pct)],
          gap=10, alignItems="center"),
    ], **kw)


def check(label: str, on: bool) -> dict:
    return H("check", [href("CHECKBOX_ON" if on else "CHECKBOX_OFF", "cb"), text(label, 12,
                                                                               "$text-primary", "n")],
             gap=7, alignItems="center")


def tab_strip(items: list[str], active: int) -> dict:
    kids = []
    for i, it in enumerate(items):
        on = i == active
        kids.append(H(f"tab{i}", [text(it, 12.5, "$text-primary" if on else "$text-tertiary",
                                       "500" if on else "normal", "l")],
                      padding=[7, 12], cornerRadius=7,
                      fill="$bg-elevated" if on else None,
                      justifyContent="center", alignItems="center"))
    return H("tabs", kids, gap=4, padding=[3, 0], alignItems="center")


def trackpad_common_sidebar(active: str) -> str:
    return active


def page_trackpad_rules() -> dict:
    head = card("手势规则", "指定 App 的规则先于全局规则执行；同级按列表顺序。",
                [tbl_head("trackpad_rules", ["规则", "动作", "范围", ""])] + [
                    table_row([
                        H("r", [text("三指轻点", 12.5, "$text-primary", "500", "n"),
                                chip("接触 · 3 指", "$bg-inset", "$text-tertiary")],
                          gap=8, alignItems="center", width=210),
                        H("a", [icon("volume-2", 13, "$text-secondary", "g"),
                                text("音量 +", 12, "$text-primary", "n")], gap=6, alignItems="center",
                          width=150),
                        text("所有应用", 12, "$text-tertiary", "s"),
                        H("c", [href("TOGGLE_ON", "on"), icon("more-horizontal", 14, "$text-tertiary", "m")],
                          gap=10, alignItems="center"),
                    ], widths=TABLE_COLS["trackpad_rules"]),
                    sep(),
                    table_row([
                        H("r", [text("四指下滑", 12.5, "$text-primary", "500", "n"),
                                chip("滑动 · 4 指 · 下", "$bg-inset", "$text-tertiary")],
                          gap=8, alignItems="center", width=210),
                        H("a", [icon("maximize-2", 13, "$text-secondary", "g"),
                                text("最大化窗口", 12, "$text-primary", "n")], gap=6, alignItems="center",
                          width=150),
                        text("所有应用", 12, "$text-tertiary", "s"),
                        H("c", [href("TOGGLE_ON", "on2"), icon("more-horizontal", 14, "$text-tertiary", "m2")],
                          gap=10, alignItems="center"),
                    ], widths=TABLE_COLS["trackpad_rules"]),
                    sep(),
                    table_row([
                        H("r", [text("左边缘连续滑动", 12.5, "$text-primary", "500", "n"),
                                chip("连续边缘 · 2 指", "$bg-inset", "$text-tertiary")],
                          gap=8, alignItems="center", width=210),
                        H("a", [icon("volume-1", 13, "$text-secondary", "g"),
                                text("连续音量", 12, "$text-primary", "n")], gap=6, alignItems="center",
                          width=150),
                        text("除「音乐」", 12, "$text-tertiary", "s"),
                        H("c", [href("TOGGLE_ON", "on3"), icon("more-horizontal", 14, "$text-tertiary", "m3")],
                          gap=10, alignItems="center"),
                    ], widths=TABLE_COLS["trackpad_rules"]),
                ], gap=0,
                action=href("BTN_PRIMARY", "add", descendants={"LABEL": {"content": "新建规则"}}))

    manage = card("规则集", "导入导出使用带版本号的本地 JSON；无效条目会被独立归一化。",
                  rows(
                      H("actions", [href("BTN_SECONDARY", "i", descendants={"LABEL": {"content": "导入 JSON"}}),
                                    href("BTN_SECONDARY", "e", descendants={"LABEL": {"content": "导出 JSON"}}),
                                    href("BTN_DANGER", "r", descendants={"LABEL": {"content": "重置为预设"}}),
                                    text("重置会替换整套规则列表。", 11, "$text-tertiary", "n")],
                        width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                      row("当前规则数", "3 条自定义 · 0 条禁用。",
                          [chip("3", "$bg-elevated", "$text-tertiary")]),
                  ), tone="$bg-inset")

    empty = card("空状态（变体）", None, [
        empty_state("还没有手势规则", "添加一条规则，把触控手势连接到系统或应用动作。", "新建手势规则", "hand-tap")],
        tone="$bg-inset")

    return page(
        "F · 触控板 · 手势规则", "trackpad", "触控板", "手势规则 = 触发器 → 动作；动作取自统一动作库。",
        "touchpad", [
            card("运行状态", "只有启用后才开始原始触控观测；关闭时输入完全透传。", rows(
                row_toggle("启用手势", "默认关闭。启用后触控引擎开始观测，并在兼容时申请辅助功能权限。", True),
                row("当前", None, [chip("引擎运行中 · 1 台设备", "$accent-soft", "$accent", "activity"),
                                  chip("复制点击已在下方控制", "$bg-elevated", "$text-tertiary")]),
            )),
            tab_strip(["手势规则", "反馈与参数", "运行时与诊断"], 0),
            head,
            manage,
            empty,
        ],
        note="触控板（1/3）· 规则即数据：触发器 → 动作 → 范围；规则集导入导出收在一处。",
        note_id="note-trackpad1")


def page_trackpad_feedback() -> dict:
    hud = H("hud", [
        icon("volume-2", 15, "$text-primary", "g"),
        V("t", [text("音量 +", 12, "$text-primary", "500", "n"),
                rect("fill_container", 4, "$accent", "level", cornerRadius=2)],
          width=120, gap=5),
        text("236 × 64", 10, "$text-tertiary", "sz"),
    ], width=236, height=64, fill="$bg-elevated", cornerRadius=12, gap=10, padding=[0, 14],
        alignItems="center", stroke="$separator", strokeWidth=1)

    feedback = card("反馈与边缘控制", "反馈只作用于本机；边缘参数对所有边缘类规则共享。",
                    rows(
                        row_toggle("触觉反馈", "识别成功后给出轻微触感。", True),
                        row_toggle("反馈 HUD", "在指针附近显示 236×64 的短暂提示。", True),
                        row("HUD 预览", "居中显示 1.6 秒，0.18 秒淡出；时长与位置不可调。",
                            [chip("不可配置", "$bg-elevated", "$text-tertiary")]),
                    ))

    params = card("全局手势参数", "连续型动作（音量、亮度）按灵敏度整体缩放。",
                  rows(
                      row_slider("边缘宽度", "8%", 0.42, "3%–20%，步进 1%。所有边缘进入/连续规则共享。"),
                      row_slider("灵敏度", "1.00×", 0.25, "0.25×–4.00×，步进 0.05×。"),
                  ))

    return page(
        "G · 触控板 · 反馈与参数", "trackpad", "触控板", "反馈与全局手势参数；规则级覆盖不提供。",
        "touchpad", [
            tab_strip(["手势规则", "反馈与参数", "运行时与诊断"], 1),
            H("hud-demo", [text("反馈 HUD", 11, "$text-tertiary", "lab"), hud],
              width="fill_container", fill="$bg-card", cornerRadius=10, padding=[14, 14], gap=12,
              alignItems="center"),
            feedback,
            params,
            card("为什么是全局参数", None, rows(
                row_link("边缘宽度与灵敏度", "查看边缘类规则", "编辑器只显示共享值，不提供按规则覆盖。"),
            ), tone="$bg-inset"),
        ],
        note="触控板（2/3）· HUD 尺寸与时长照源码；边缘/灵敏度明确标注为全局共享。",
        note_id="note-trackpad2")


def page_trackpad_runtime() -> dict:
    status = card("运行时", "识别通过与否都不影响原生输入；抑制需要单独授权。",
                  rows(
                      H("state", [icon("activity", 16, "$success", "g"),
                                  V("t", [text("引擎运行中 · 1 台设备", 13, "$text-primary", "500", "n"),
                                          text("原始触控观测保持透传。", 11, "$text-tertiary", "d")],
                                    width="fill_container", gap=2),
                                  href("BTN_SECONDARY", "retry", descendants={"LABEL": {"content": "重试"}})],
                        width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                      H("modes", [chip("AirPlay 镜像时暂停本机手势", "$bg-elevated", "$text-tertiary",
                                       "monitor"),
                                  chip("指针在本机显示器外时暂停", "$bg-elevated", "$text-tertiary",
                                       "mouse-pointer")],
                        width="fill_container", gap=8, padding=[8, 14], alignItems="center"),

                  ))

    suppression = card("点击抑制", "多指轻点后抑制左键，避免误触；需要辅助功能权限。",
                       rows(
                           row_toggle("多指轻点后抑制左键点击", "连续边缘规则激活时，原生滚动也会被抑制。", False),
                           row("辅助功能权限", "点击抑制需要授权；音量与受支持的亮度控制不需要。",
                               [chip("需要授权", "$bg-elevated", "$warning", "alert-triangle")]),
                           H("acts", [href("BTN_PRIMARY", "req", descendants={"LABEL": {"content": "请求访问"}}),
                                      href("BTN_SECONDARY", "os", descendants={"LABEL": {"content": "打开系统设置"}})],
                             width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                       ))

    live = card("实时触点预览", "只在诊断页挂载，最多 30 Hz；切换标签即释放。",
                rows(
                    H("canvas", [icon("hand", 26, "$text-tertiary", "g"),
                                 text("触点位置预览", 12, "$text-tertiary", "l")],
                      width="fill_container", height=132, fill="$bg-inset", cornerRadius=9, gap=10,
                      justifyContent="center", alignItems="center", stroke="$separator", strokeWidth=1),
                    row("当前触点", "预览不消费正常指针输入。",
                        [chip("4 个触点", "$bg-elevated", "$text-tertiary"),
                         chip("上次识别：三指轻点", "$bg-elevated", "$text-tertiary")]),
                ))

    return page(
        "H · 触控板 · 运行时与诊断", "trackpad", "触控板", "运行时状态、输入所有权与实时诊断。",
        "touchpad", [
            tab_strip(["手势规则", "反馈与参数", "运行时与诊断"], 2),
            status,
            suppression,
            live,
            card("输入所有权的三种暂停", None, [
                bullet("本机", "正常执行手势自动化。", "check", "$success"),
                bullet("AirPlay 镜像中", "暂停本机自动化，系统输入保持透传。", "pause", "$warning"),
                bullet("指针在本机显示器外", "暂停本机自动化，避免跨 Mac 误捕获。", "pause", "$warning"),
            ], gap=7, padding=[12, 14]),
        ],
        status="引擎运行中",
        note="触控板（3/3）· 权限行按状态渐进显示；暂停语义写清楚，不再是只读徽章。",
        note_id="note-trackpad3")


def page_hotkeys() -> dict:
    bindings = card("快捷键", "动作来自统一动作库；快捷键只定义触发方式。",
                    [tbl_head("hotkeys", ["组合键", "动作", "名称", "状态", ""])] + [
                        table_row([
                            chip("⌘ ⇧ ↑", "$bg-inset", "$text-primary"),
                            H("a", [icon("maximize-2", 13, "$text-secondary", "g"),
                                    text("最大化窗口", 12, "$text-primary", "n")], gap=6, width=200,
                              alignItems="center"),
                            text("—", 12, "$text-tertiary", "n"),
                            chip("已注册", "$bg-elevated", "$success", "check"),
                            H("c", [href("TOGGLE_ON", "t"), icon("more-horizontal", 14, "$text-tertiary", "m")],
                              gap=10, alignItems="center"),
                        ], widths=TABLE_COLS["hotkeys"]),
                        sep(),
                        table_row([
                            chip("⌘ ⇧ ↓", "$bg-inset", "$text-primary"),
                            H("a", [icon("minimize-2", 13, "$text-secondary", "g"),
                                    text("还原窗口", 12, "$text-primary", "n")], gap=6, width=200,
                              alignItems="center"),
                            text("—", 12, "$text-tertiary", "n"),
                            chip("已注册", "$bg-elevated", "$success", "check"),
                            H("c", [href("TOGGLE_ON", "t2"), icon("more-horizontal", 14, "$text-tertiary", "m2")],
                              gap=10, alignItems="center"),
                        ], widths=TABLE_COLS["hotkeys"]),
                        sep(),
                        table_row([
                            chip("⌘ ⇧ →", "$bg-inset", "$text-primary"),
                            H("a", [icon("move", 13, "$text-secondary", "g"),
                                    text("移到下一显示器", 12, "$text-primary", "n")], gap=6, width=200,
                              alignItems="center"),
                            text("—", 12, "$text-tertiary", "n"),
                            chip("已注册", "$bg-elevated", "$success", "check"),
                            H("c", [href("TOGGLE_ON", "t3"), icon("more-horizontal", 14, "$text-tertiary", "m3")],
                              gap=10, alignItems="center"),
                        ], widths=TABLE_COLS["hotkeys"]),
                        sep(),
                        table_row([
                            chip("⌘ ⇧ [", "$bg-inset", "$text-primary"),
                            H("a", [icon("arrow-left", 13, "$text-secondary", "g"),
                                    text("上一标签页", 12, "$text-primary", "n")], gap=6, width=200,
                              alignItems="center"),
                            text("—", 12, "$text-tertiary", "n"),
                            chip("已注册", "$bg-elevated", "$success", "check"),
                            H("c", [href("TOGGLE_ON", "t4"), icon("more-horizontal", 14, "$text-tertiary", "m4")],
                              gap=10, alignItems="center"),
                        ], widths=TABLE_COLS["hotkeys"]),
                        sep(),
                        table_row([
                            chip("未设置", "$bg-inset", "$text-tertiary"),
                            H("a", [icon("laptop", 13, "$warning", "g"),
                                    text("隐藏刘海", 12, "$text-secondary", "n")], gap=6, width=200,
                              alignItems="center"),
                            text("刘海屏", 12, "$text-tertiary", "n"),
                            chip("此设备不可用", "$bg-elevated", "$warning", "alert-triangle"),
                            H("c", [href("TOGGLE_OFF", "t5"), icon("more-horizontal", 14, "$text-tertiary", "m5")],
                              gap=10, alignItems="center"),
                        ], widths=TABLE_COLS["hotkeys"]),
                    ], gap=0,
                    action=href("BTN_PRIMARY", "add", descendants={"LABEL": {"content": "添加快捷键"}}))

    return page(
        "I · 设置窗口 · 快捷键", "hotkeys", "快捷键", "在任意应用中按下即可运行本机动作。",
        "keyboard", [
            card("全局快捷键", "源码只有逐条启用，没有总开关——v1.0.0 补一个，避免逐条关闭。", rows(
                row_toggle("启用全局快捷键", "关闭后所有绑定保留但不再注册。", True),
                row("当前", None, [chip("4 个已注册", "$accent-soft", "$accent", "check"),
                                  chip("0 个冲突", "$bg-elevated", "$text-tertiary"),
                                  chip("1 个不可用", "$bg-elevated", "$warning", "alert-triangle")]),
            )),
            bindings,
            banner("窗口与标签动作需要辅助功能权限",
                   "摆放或移动窗口、上一/下一标签页的动作会在首次运行时申请授权。",
                   "$warning", "打开系统设置"),
            card("动作来自动作库", None, rows(
                row_link("动作库", "查看全部动作与引用关系", "快捷键、手势与面板引用同一套动作定义。"),
                row("需要 ⌘、⌃ 或 ⌥", "不含修饰键的组合会拦截日常输入，保存时会被拒绝。",
                    [chip("校验规则", "$bg-elevated", "$text-tertiary")]),
                row("系统占用提示", "被 macOS 或其他应用占用的组合仍归它们所有，本快捷键不会响应。",
                    [chip("无法检测", "$bg-elevated", "$text-tertiary")]),
            ), tone="$bg-inset"),
            card("内置默认", "6 条默认绑定在存储版本落后时静默合并；v1.0.0 给出显式入口。",
                 rows(
                     H("acts", [href("BTN_SECONDARY", "r", descendants={"LABEL": {"content": "恢复内置默认"}}),
                                text("只补齐缺失的默认绑定，不覆盖你自定义的组合键。", 11, "$text-tertiary", "n")],
                       width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                 ), tone="$bg-inset"),
        ],
        status="4 个已注册 · 0 冲突",
        note="快捷键 · 补总开关与「恢复默认」；不可用动作直接显示原因与本机限制。",
        note_id="note-hotkeys")


def page_action_center() -> dict:
    pinned = card("固定到面板", "面板在固定的「更多」按钮之前显示这些动作；上限 7 个。",
                  rows(
                      list_row("关闭显示器", "显示与屏幕", [
                          icon("chevron-up", 13, "$text-tertiary", "u"),
                          icon("chevron-down", 13, "$text-tertiary", "d"),
                          icon("minus-circle", 15, "$danger", "x")]),
                      list_row("深色模式", "系统 · 当前已开启", [
                          chip("已开启", "$accent-soft", "$accent"),
                          icon("chevron-up", 13, "$text-tertiary", "u2"),
                          icon("chevron-down", 13, "$text-tertiary", "d2"),
                          icon("minus-circle", 15, "$danger", "x2")]),
                      list_row("清空废纸篓", "破坏性动作 · 运行前确认", [
                          chip("破坏性", "$bg-elevated", "$danger", "alert-triangle"),
                          icon("chevron-up", 13, "$text-tertiary", "u3"),
                          icon("chevron-down", 13, "$text-tertiary", "d3"),
                          icon("minus-circle", 15, "$danger", "x3")]),
                  ), action=chip("3 / 7", "$bg-elevated", "$text-tertiary"))

    catalog = card("全部动作", "「运行」是设置页内唯一的执行入口；破坏性动作运行前确认。",
                   [H("filters", [
                       H("search", [icon("search", 13, "$text-tertiary", "g"),
                                    text("搜索动作", 12, "$text-tertiary", "t")],
                         width=200, fill="$bg-inset", cornerRadius=7, gap=6, padding=[6, 9],
                         alignItems="center"),
                       segmented(["全部", "内置", "快捷指令", "触控板原生"], 0),
                   ], width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                    H("gl", [text("显示与屏幕 · 7", 11, "$text-tertiary", "t")], padding=[6, 14]),
                    ] + [
                       H("arow", [icon("sun", 14, "$text-secondary", "g"),
                                  text("保持屏幕常亮", 12.5, "$text-primary", "500", "n"),
                                  chip("面板", "$bg-elevated", "$text-tertiary", "pin"),
                                  chip("手势规则：左边缘连续滑动", "$bg-elevated", "$text-tertiary", "hand-tap"),
                                  href("TOGGLE_OFF", "pin"),
                                  href("BTN_SECONDARY", "run", descendants={"LABEL": {"content": "运行"}})],
                         width="fill_container", gap=8, padding=[8, 14], alignItems="center"),
                       sep(),
                       H("arow", [icon("moon", 14, "$text-secondary", "g"),
                                  text("深色模式", 12.5, "$text-primary", "500", "n"),
                                  chip("已开启", "$accent-soft", "$accent"),
                                  chip("已固定", "$bg-elevated", "$text-tertiary", "pin"),
                                  href("TOGGLE_ON", "pin2"),
                                  href("BTN_SECONDARY", "run2", descendants={"LABEL": {"content": "运行"}})],
                         width="fill_container", gap=8, padding=[8, 14], alignItems="center"),
                       sep(),
                       H("arow", [icon("laptop", 14, "$warning", "g"),
                                  text("隐藏刘海", 12.5, "$text-secondary", "500", "n"),
                                  chip("刘海屏不可用", "$bg-elevated", "$warning", "alert-triangle"),
                                  chip("尚无引用", "$bg-elevated", "$text-tertiary"),
                                  href("TOGGLE_OFF", "pin3"),
                                  href("BTN_SECONDARY", "run3", descendants={"LABEL": {"content": "运行"}})],
                         width="fill_container", gap=8, padding=[8, 14], alignItems="center"),
                       sep(),
                       H("gl2", [text("系统 · 5", 11, "$text-tertiary", "t")], padding=[6, 14]),
                       H("arow", [icon("lock", 14, "$text-secondary", "g"),
                                  text("锁定屏幕", 12.5, "$text-primary", "500", "n"),
                                  chip("快捷键：⌘⌥L", "$bg-elevated", "$text-tertiary", "keyboard"),
                                  href("TOGGLE_OFF", "pin4"),
                                  href("BTN_SECONDARY", "run4", descendants={"LABEL": {"content": "运行"}})],
                         width="fill_container", gap=8, padding=[8, 14], alignItems="center"),
                       sep(),
                       H("arow", [icon("trash-2", 14, "$danger", "g"),
                                  text("清空废纸篓", 12.5, "$text-primary", "500", "n"),
                                  chip("破坏性 · 运行前确认", "$bg-elevated", "$danger", "alert-triangle"),
                                  chip("已固定", "$bg-elevated", "$text-tertiary", "pin"),
                                  href("TOGGLE_ON", "pin5"),
                                  href("BTN_SECONDARY", "run5", descendants={"LABEL": {"content": "运行"}})],
                         width="fill_container", gap=8, padding=[8, 14], alignItems="center"),
                   ], gap=0)

    return page(
        "J · 设置窗口 · 动作库", "actionCenter", "动作库",
        "面板、手势与快捷键共同引用的唯一动作定义；不再归入「界面」。",
        "zap", [
            pinned,
            catalog,
            card("权限", None, rows(
                row("锁定屏幕 · 清理模式", "执行 macOS 系统事件需要辅助功能权限。",
                    [chip("需要授权", "$bg-elevated", "$warning", "alert-triangle"),
                     href("BTN_SECONDARY", "os", descendants={"LABEL": {"content": "打开系统设置"}})]),
                row("触控板原生动作", "32 个动作只在手势规则中可用，设置页不提供运行入口。",
                    [chip("只读", "$bg-elevated", "$text-tertiary")]),
            )),
        ],
        status="13 内置 · 32 触控板动作",
        note="动作库 · 原「操作中心」；每行显示被谁引用，执行只走显式「运行」。",
        note_id="note-actionCenter")


def page_alerts() -> dict:
    channels = card("投递渠道", "渠道必须先在钥匙串保存凭据才能启用；关闭渠道会从所有规则里移除它。",
                    rows(
                        H("ch", [icon("send", 14, "$success", "g"),
                                 text("飞书", 12.5, "$text-primary", "500", "n"),
                                 chip("已就绪", "$bg-elevated", "$success", "check"),
                                 href("TOGGLE_ON", "t1"),
                                 href("BTN_SECONDARY", "c1", descendants={"LABEL": {"content": "收起配置"}}),
                                 href("BTN_SECONDARY", "test", descendants={"LABEL": {"content": "发送测试"}}),
                                 chip("测试成功", "$bg-elevated", "$success", "check")],
                          width="fill_container", gap=8, padding=[10, 14], alignItems="center"),
                    ))

    feishu = card("飞书配置", None, rows(
        row("Webhook URL", "必填；保存在系统钥匙串，界面只显示「已保存」。",
            [chip("已保存", "$bg-elevated", "$success", "lock"),
             href("BTN_DANGER", "rm", descendants={"LABEL": {"content": "移除凭据"}})]),
        row("签名密钥", "可选；用于校验回调签名。",
            [chip("已保存", "$bg-elevated", "$success", "lock"),
             href("BTN_DANGER", "rm2", descendants={"LABEL": {"content": "移除凭据"}})]),
        row("移除必填凭据的后果", "渠道被同时禁用，并从全部规则中移除，且没有撤销。",
            [chip("不可撤销", "$bg-elevated", "$warning", "alert-triangle")]),
    ), tone="$bg-inset")

    others = card("其他渠道", "结构相同：凭据 → 启用 → 测试。",
                  rows(
                      row("Webhook", "Endpoint URL 必填，Bearer token 可选。",
                          [chip("未配置", "$bg-elevated", "$text-tertiary"),
                           href("TOGGLE_OFF", "t2"),
                           href("BTN_SECONDARY", "c2", descendants={"LABEL": {"content": "配置"}})]),
                      row("Bark", "Device key 必填；Server URL 默认 https://api.day.app。",
                          [chip("未配置", "$bg-elevated", "$text-tertiary"),
                           href("TOGGLE_OFF", "t3"),
                           href("BTN_SECONDARY", "c3", descendants={"LABEL": {"content": "配置"}})]),
                      row("Telegram", "Bot token + Chat ID 必填，Topic ID 可选。",
                          [chip("未配置", "$bg-elevated", "$text-tertiary"),
                           href("TOGGLE_OFF", "t4"),
                           href("BTN_SECONDARY", "c4", descendants={"LABEL": {"content": "配置"}})]),
                  ), tone="$bg-inset")

    rules = card("告警规则", "阈值按指标自己的单位；百分比类指标内部按 0–1 比较。",
                 [tbl_head("alerts", ["规则", "指标", "条件", "持续", "冷却", ""])] + [
                     table_row([text("CPU 使用率", 12.5, "$text-primary", "500", "n"),
                                text("cpu.total.busy", 11.5, "$text-tertiary", "m", fontFamily="$font-mono"),
                                text("高于 90%", 12, "$text-primary", "c"),
                                text("60 秒", 12, "$text-tertiary", "d"),
                                text("0 秒", 12, "$text-tertiary", "cd"),
                                href("TOGGLE_ON", "on")], widths=TABLE_COLS["alerts"]),
                     sep(),
                     table_row([text("电池电量", 12.5, "$text-primary", "500", "n2"),
                                text("battery.level", 11.5, "$text-tertiary", "m2", fontFamily="$font-mono"),
                                text("低于 20%", 12, "$text-primary", "c2"),
                                text("30 秒", 12, "$text-tertiary", "d2"),
                                text("300 秒", 12, "$text-tertiary", "cd2"),
                                href("TOGGLE_OFF", "off")], widths=TABLE_COLS["alerts"]),
                     sep(),
                     table_row([text("深色唤醒", 12.5, "$text-primary", "500", "n3"),
                                text("event.darkWake", 11.5, "$text-tertiary", "m3", fontFamily="$font-mono"),
                                text("每次发生", 12, "$text-primary", "c3"),
                                text("—", 12, "$text-tertiary", "d3"),
                                text("0 秒", 12, "$text-tertiary", "cd3"),
                                href("TOGGLE_ON", "on3")], widths=TABLE_COLS["alerts"]),
                 ], gap=0,
                 action=href("BTN_PRIMARY", "add", descendants={"LABEL": {"content": "新建规则"}}))

    editor = card("规则编辑器 · CPU 使用率", "改动只在「保存规则」时落库；界面不显示未保存状态。",
                  rows(
                      row_field("规则名称", "CPU 使用率", None, 190, mono=False),
                      row_picker("指标", "cpu.total.busy · 百分比"),
                      H("cond", [text("条件", 13, "$text-primary", "500", "n"),
                                 H("c", [href("BTN_SECONDARY", "p", descendants={"LABEL": {"content": "高于"}}),
                                         text_field("90", 74, mono=False),
                                         chip("%", "$bg-elevated", "$text-tertiary")],
                                   gap=8, alignItems="center")],
                        width="fill_container", gap=12, padding=[10, 14], alignItems="center"),
                      row_field("持续", "60", "连续满足 60 秒后才告警。", 74, mono=False),
                      row_field("恢复阈值", "75", "留空则复用告警阈值。", 74, mono=False),
                      row_field("恢复持续", "60", "连续满足 60 秒后发送恢复消息。", 74, mono=False),
                      row_field("冷却", "0", "两次告警之间的最小间隔，0 表示不限制。", 74, mono=False),
                      H("deliver", [text("投递到", 13, "$text-primary", "500", "n"),
                                    check("飞书", True), check("Webhook", False),
                                    check("Bark", False), check("Telegram", False),
                                    chip("未启用的渠道不可选", "$bg-elevated", "$text-tertiary")],
                        width="fill_container", gap=14, padding=[10, 14], alignItems="center"),
                      H("msg", [text("消息", 13, "$text-primary", "500", "n"),
                                segmented(["告警", "恢复"], 0),
                                href("BTN_SECONDARY", "var", descendants={"LABEL": {"content": "插入变量"}}),
                                chip("{{rule.name}} · {{metric.value}} · {{device.name}}",
                                     "$bg-inset", "$text-tertiary", "code")],
                        width="fill_container", gap=12, padding=[10, 14], alignItems="center"),
                      row_field("标题模板", "{{rule.name}}", None, 260, mono=False),
                      row_field("正文模板", "{{device.name}} 告警：{{metric.value}}", None, 260, mono=False),
                      H("preview", [text("预览", 11, "$text-tertiary", "l"),
                                    V("p", [text("CPU 使用率", 12, "$text-primary", "500", "t"),
                                            text("MacBook Pro 告警：93%", 11, "$text-tertiary", "b")],
                                      gap=2)],
                        width="fill_container", fill="$bg-inset", cornerRadius=8, gap=12,
                        padding=[10, 14], alignItems="center"),
                  ))

    return page(
        "K · 设置窗口 · 提醒规则", "alerts", "提醒规则",
        "监控系统指标与深色唤醒，按规则投递到外部渠道；与输入无关。",
        "bell-badge", [
            card("运行状态", "源码没有总开关，只能逐渠道、逐规则关闭——v1.0.0 补一个。", rows(
                row_toggle("启用告警监控", "关闭后保留全部规则与渠道配置，但不再采样、不再投递。", True),
                row("当前", None, [chip("1 个渠道已就绪", "$accent-soft", "$accent", "check"),
                                  chip("2 条规则启用", "$bg-elevated", "$text-tertiary"),
                                  chip("采样中", "$bg-elevated", "$text-tertiary", "activity")]),
            )),
            channels, feishu, others, rules, editor,
            card("设备身份", None, rows(
                row_field("设备名", "MacBook Pro", "留空则使用系统主机名。", 190, mono=False),
                row("推送里显示的来源", "MacBook Pro", None),
            )),
            card("源码里不存在的部分", "不要在界面上暗示已经支持。",
                 [H("gap", [chip("无静默时段", "$bg-elevated", "$text-tertiary"),
                            chip("无投递历史界面", "$bg-elevated", "$text-tertiary"),
                            chip("无全局开关（本页已补）", "$bg-elevated", "$text-tertiary")],
                   width="fill_container", gap=8, padding=[10, 14], alignItems="center")],
                 tone="$bg-inset"),
        ],
        status="采样中 · 2 条规则",
        note="提醒规则 · 渠道凭据、规则表与编辑器同页；明确标出源码中不存在的能力。",
        note_id="note-alerts")


def page_power() -> dict:
    monitoring = card("后台监控", "只有打开这个开关才会在后台记录唤醒与进程采样。",
                      rows(
                          row_toggle("后台记录唤醒与进程", "关闭时，唤醒历史与「持续运行」只覆盖面板打开期间。", False),
                          row("采样节奏", "进程采样约每 300 秒一次；低电量模式下至少 900 秒。",
                              [chip("300 秒 / 900 秒", "$bg-elevated", "$text-tertiary")]),
                      ))

    helper = card("Power Helper", "系统电源设置与系统时区都通过它写入，需要管理员授权。",
                  rows(
                      H("state", [icon("check-circle-2", 16, "$success", "g"),
                                  V("t", [text("已启用", 13, "$text-primary", "500", "n"),
                                          text("版本 3 · 支持电源设置与进程控制", 11, "$text-tertiary", "d")],
                                    width="fill_container", gap=2),
                                  chip("移除前需确认", "$bg-elevated", "$warning", "alert-triangle"),
                                  href("BTN_SECONDARY", "refresh", descendants={"LABEL": {"content": "刷新助手"}}),
                                  href("BTN_DANGER", "remove", descendants={"LABEL": {"content": "移除助手"}}),
                                  ],
                        width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                  ))

    profiles = card("系统电源设置", "只写入 Helper 支持的四个布尔开关；混合取值会先确认。",
                    rows(
                        row_segmented("电源来源", ["电池", "外接电源", "全部"], 1),
                        row_toggle("电源小盹（powernap）", None, True),
                        row_toggle("网络访问唤醒（womp）", None, False),
                        row_toggle("待机（standby）", None, True),
                        row_toggle("TCP Keepalive", None, True),
                        row("电池与外接电源取值不同", "「全部」下改为「应用开 / 应用关」并弹出确认。",
                            [chip("需确认", "$bg-elevated", "$warning")]),
                    ))

    readouts = card("只读读数", "解析出来但从未渲染的三个值，v1.0.0 上屏。",
                    rows(
                        row("电源模式", "pmset 报告的当前模式。",
                            [chip("正常", "$bg-elevated", "$success")]),
                        row("磁盘睡眠", "解析自 pmset custom，当前无任何控制入口。",
                            [chip("10 分钟", "$bg-elevated", "$text-secondary")]),
                        row("显示器睡眠", "解析自 pmset custom，当前无任何控制入口。",
                            [chip("5 分钟", "$bg-elevated", "$text-secondary")]),
                    ), tone="$bg-inset")

    history = card("唤醒历史", "本机保存最近 30 天的睡眠与唤醒事件。",
                   [H("meta", [text("最近 30 天 · 本机保存 · 128 KB", 11, "$text-tertiary", "m"),
                               chip("清空前确认", "$bg-elevated", "$warning"),
                               href("BTN_DANGER", "clear", descendants={"LABEL": {"content": "清空历史"}})],
                      width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                    tbl_head("wake_history", ["时间", "类型", "原因"]),
                    table_row([text("11:02", 12, "$text-primary", "t"),
                               chip("用户唤醒", "$bg-elevated", "$text-secondary"),
                               text("Lid Open", 12, "$text-tertiary", "r")], widths=TABLE_COLS["wake_history"]),
                    sep(),
                    table_row([text("09:41", 12, "$text-primary", "t2"),
                               chip("深色唤醒", "$bg-inset", "$text-tertiary"),
                               text("DarkWake from Deep Idle", 12, "$text-tertiary", "r2")], widths=TABLE_COLS["wake_history"]),
                    sep(),
                    H("hidden", [text("清空后隐藏了 12 条更早的记录", 11, "$text-tertiary", "n"),
                                 href("BTN_LINK", "show", descendants={"LABEL": {"content": "显示它们"}}),
                                 chip("可恢复", "$bg-elevated", "$text-tertiary")],
                      width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                   ], gap=0)

    return page(
        "L · 设置窗口 · 电源", "power", "电源", "Power Helper、系统电源设置与唤醒历史。",
        "battery-charging", [
            monitoring, helper, profiles, readouts, history,
            card("进入本页会发生什么", None, [
                bullet("前台读取", "打开本页会立即读取一次 pmset 与电池状态；不写入历史。", "info", "$accent"),
                bullet("后台采样", "只有打开「后台记录」才会持续采样。", "info", "$accent"),
                bullet("清空历史可撤销", "文件保留，仅用时间水印隐藏，可随时恢复。", "undo", "$success"),
            ], gap=7, padding=[12, 14]),
        ],
        status="助手已启用",
        note="电源 · 后台监控显式化；移除助手加确认；已解析未展示的睡眠读数上屏。",
        note_id="note-power")


def page_timezone() -> dict:
    app_tz = card("MenuCue 显示时区", "只影响 MenuCue 内的日期与时间，不改变 macOS。",
                  rows(
                      row_picker("显示时区", "Asia/Shanghai (GMT+08:00)"),
                      row("回退规则", "第一项时钟是它的兜底；时区不可用时回落到系统时区。",
                          [chip("自动回退", "$bg-elevated", "$text-tertiary")]),
                  ))

    system_tz = card("macOS 系统时区", "改的是整台 Mac，需要 Power Helper。",
                     rows(
                         H("now", [text("当前系统时区", 13, "$text-primary", "500", "n"),
                                   chip("Asia/Shanghai (GMT+08:00)", "$bg-inset", "$text-primary"),
                                   href("BTN_SECONDARY", "refresh", descendants={"LABEL": {"content": "刷新"}})],
                           width="fill_container", gap=12, padding=[10, 14], alignItems="center"),
                         H("search", [H("f", [icon("search", 13, "$text-tertiary", "g"),
                                              text("搜索时区", 12, "$text-tertiary", "t")],
                                        width=220, fill="$bg-inset", cornerRadius=7, gap=6,
                                        padding=[6, 9], alignItems="center"),
                                      chip("按名称或 IANA 标识搜索", "$bg-elevated", "$text-tertiary")],
                           width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                         list_row("Tokyo (GMT+09:00)", "Asia/Tokyo",
                                  [chip("选择", "$bg-elevated", "$text-tertiary")]),
                         list_row("Los Angeles (GMT-07:00)", "America/Los_Angeles",
                                  [chip("选择", "$bg-elevated", "$text-tertiary")]),
                         H("acts", [href("BTN_PRIMARY", "apply", descendants={"LABEL": {"content": "应用时区"}}),
                                    chip("助手已启用", "$bg-elevated", "$success"),
                                    chip("立即生效并影响所有应用", "$bg-elevated", "$warning", "alert-triangle")],
                           width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                     ))

    region = card("macOS 语言与地区", "原先混在「通用」里；这里只做跳转，不复制系统设置。",
                  rows(
                      row("系统语言", "决定 macOS 与应用默认语言。",
                          [chip("简体中文", "$bg-elevated", "$text-secondary")]),
                      row("地区", "决定日期、数字与货币格式。",
                          [chip("中国", "$bg-elevated", "$text-secondary")]),
                      row_link("更多设置", "打开系统设置", "MenuCue 不在应用内复制系统语言与地区。"),
                  ))

    return page(
        "M · 设置窗口 · 时间与区域", "timeZone", "时间与区域",
        "新增页：把应用显示时区、macOS 系统时区与语言地区从菜单栏页和通用页收回来。",
        "globe", [
            banner("这些设置会改变整台 Mac",
                   "系统时区由 Power Helper 写入，影响所有应用与系统服务。",
                   "$warning", "查看助手状态"),
            app_tz, system_tz, region,
        ],
        note="时间与区域 · 新增页；散落在两页的系统时区与语言地区第一次归位。",
        note_id="note-timeZone")


def page_general() -> dict:
    startup = card("启动", None, rows(
        row_toggle("登录时启动 MenuCue", None, True),
        row("状态", "已登记为登录项。",
            [chip("已启用", "$bg-elevated", "$success", "check")]),
        row_button("需要批准时", "打开登录项设置", "macOS 要求你在「登录项」中确认后才会自动启动。"),
    ))

    updates = card("更新", None, rows(
        row_toggle("自动检查并下载更新", "启用后每 12 小时检查一次，下载完成后提示安装。", True),
        row("状态", "当前版本已是最新。", [chip("已是最新", "$bg-elevated", "$success", "check")]),
        row("上次检查", "今天 09:12", None),
        row_button("手动检查", "检查更新", None),
    ))

    appearance = card("外观", "动效从「面板」搬到这里：它影响整个应用，不只是一个标签页。",
                      rows(
                          row_picker("外观", "跟随系统"),
                          row_picker("自动参考时区", "Asia/Shanghai", "「按时区自动」时使用：07:00–19:00 为浅色。"),
                          row_toggle("应用到 macOS 系统外观", "通过 AppleScript 修改系统外观，首次会请求自动化权限。",
                                     False),
                          row_segmented("动画效果", ["完整", "优雅", "精简"], 1),
                          row("「优雅」是什么", "保留主数值过渡，降低连续帧成本；系统开启「减弱动态效果」时按精简处理。",
                              [chip("默认", "$bg-elevated", "$text-tertiary")]),
                      ))

    language = card("MenuCue 语言", "需要重启应用生效。",
                    rows(
                        row_segmented("语言", ["跟随系统", "English", "简体中文"], 2),
                        row("重启", "改语言后必须重启；未应用前不会影响当前界面。",
                            [href("BTN_PRIMARY", "relaunch", descendants={"LABEL": {"content": "应用并重启"}})]),
                    ))

    icloud = card("iCloud 同步", "只同步可移植偏好；钥匙串凭据与历史数据不参与。",
                  rows(
                      H("state", [icon("cloud", 16, "$success", "g"),
                                  V("t", [text("同步中", 13, "$text-primary", "500", "n"),
                                          text("上次同步 2 分钟前", 11, "$text-tertiary", "d")],
                                    width="fill_container", gap=2),
                                  href("BTN_SECONDARY", "retry", descendants={"LABEL": {"content": "重试同步"}})],
                        width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                      row_toggle("同步可移植偏好", None, True),
                      row("会同步", "外观、时钟格式与时区、触控板规则、快捷键、提醒规则与模板。",
                          [chip("可移植", "$bg-elevated", "$text-tertiary")]),
                      row("不会同步", "渠道凭据、唤醒历史、进程能耗历史与任何本机路径。",
                          [chip("本机专属", "$bg-elevated", "$text-tertiary")]),
                  ))

    return page(
        "N · 设置窗口 · 通用", "general", "通用",
        "启动、更新、外观、语言与 iCloud 同步——不再收纳其他页面的内容。",
        "settings-2", [startup, updates, appearance, language, icloud],
        note="通用 · 五件事各自成卡；动效迁入外观，语言与地区迁出到「时间与区域」。",
        note_id="note-general")


def page_about() -> dict:
    brand = card("MenuCue", None, [
        H("brand", [H("mark", [icon("timer", 22, "#FFFFFF", "g")], width=52, height=52,
                      fill="$accent", cornerRadius=13, justifyContent="center", alignItems="center"),
                    V("t", [text("MenuCue", 17, "$text-primary", "600", "n"),
                            text("版本 1.0.0（Build 42）", 11.5, "$text-tertiary", "v"),
                            H("chips", [chip("已是最新", "$bg-elevated", "$success", "check"),
                                        chip("Developer ID 签名 · 已公证", "$bg-elevated", "$text-tertiary",
                                             "shield")], gap=8, alignItems="center")],
                      width="fill_container", gap=5),
                    href("BTN_SECONDARY", "check", descendants={"LABEL": {"content": "检查更新"}})],
          width="fill_container", gap=14, padding=[12, 14], alignItems="center"),
    ])

    links = card("链接", None, rows(
        row_link("源码与问题", "GitHub 仓库"),
        row_link("更新日志", "发行说明"),
        row_link("开源许可", "第三方声明"),
    ))

    legal = card("法律", None, [
        V("t", [text("© 2026 MenuCue", 11.5, "$text-secondary", "t"),
                wrap("MenuCue 仅在本机运行；唤醒历史、进程采样与提醒规则数据都保存在本机，"
                     "iCloud 同步只同步可移植偏好。", 11, "$text-tertiary")],
          width="fill_container", gap=5, padding=[12, 14]),
    ], tone="$bg-inset")

    return page(
        "O · 设置窗口 · 关于", "about", "关于", "版本、链接与法律信息。",
        "info", [brand, links, legal], justify="center",
        note="关于 · 只保留版本、链接与法律；启动与更新早已移到通用。",
        note_id="note-about")


def popover(name: str, active: int, body: list[dict], note: str, note_id: str) -> dict:
    content = V("body", body, width="fill_container", height="fill_container", layout="vertical",
                gap=10, padding=[12, 14])
    fr = V(name, [
        H("top", [segmented(["状态", "日历", "电源", "操作"], active)],
          width="fill_container", padding=[12, 14, 0, 14], justifyContent="center"),
        content,
        V("footer", [
            rect("fill_container", 1, "$separator", "sp"),
            H("f", [H("uptime", [icon("power", 12, "$text-tertiary", "g"),
                                 text("已运行 3 天 4 小时", 11, "$text-tertiary", "t")],
                      gap=6, alignItems="center", width="fill_container"),
                    icon("settings", 15, "$text-secondary", "gear"),
                    icon("more-horizontal", 15, "$text-secondary", "more")],
              width="fill_container", gap=14, padding=[10, 14], alignItems="center"),
        ], width="fill_container", layout="vertical", gap=0),
    ], width=360, height=620, fill="$bg-window", cornerRadius=12, clip=True, gap=0)
    fr["_note_id"] = note_id
    fr["_note_text"] = note
    return fr


def metric_card(glyph: str, title: str, value: str, sub: str, pct: float) -> dict:
    return V("mcard", [
        H("h", [icon(glyph, 13, "$text-tertiary", "g"),
                text(title, 11, "$text-tertiary", "t")], gap=6, alignItems="center"),
        text(value, 15, "$text-primary", "600", "v"),
        H("bar", [rect(round(140 * pct), 4, "$accent", "fill", cornerRadius=2),
                  rect("fill_container", 4, "$bg-elevated", "rest", cornerRadius=2)],
          width="fill_container", gap=0),
        text(sub, 10.5, "$text-tertiary", "s"),
    ], width="fill_container", fill="$bg-card", cornerRadius=10, gap=7, padding=11)


def popover_status() -> dict:
    tiles = H("tiles", [
        V("t1", [icon("monitor-off", 17, "$text-primary", "g"), text("关闭显示器", 10, "$text-secondary", "l")],
          width="fill_container", height=62, fill="$bg-card", cornerRadius=10, gap=6,
          justifyContent="center", alignItems="center"),
        V("t2", [icon("moon", 17, "$accent", "g"), text("深色模式", 10, "$text-secondary", "l")],
          width="fill_container", height=62, fill="$bg-card", cornerRadius=10, gap=6,
          justifyContent="center", alignItems="center"),
        V("t3", [icon("trash-2", 17, "$text-primary", "g"), text("清空废纸篓", 10, "$text-secondary", "l")],
          width="fill_container", height=62, fill="$bg-card", cornerRadius=10, gap=6,
          justifyContent="center", alignItems="center"),
        V("t4", [icon("lock", 17, "$text-primary", "g"), text("锁定屏幕", 10, "$text-secondary", "l")],
          width="fill_container", height=62, fill="$bg-card", cornerRadius=10, gap=6,
          justifyContent="center", alignItems="center"),
    ], width="fill_container", gap=8)

    body = [
        V("quick", [H("h", [text("快捷操作", 12, "$text-primary", "500", "t"),
                            href("BTN_LINK", "all", descendants={"LABEL": {"content": "全部"}})],
                      width="fill_container", gap=8, alignItems="center"),
                    tiles], width="fill_container", gap=8),
        H("r1", [metric_card("cpu", "CPU", "23%", "M4 Pro · 10 核 · 48°C", 0.23),
                 metric_card("hard-drive", "内存", "11.2 GB", "共 24 GB · 47%", 0.47)],
          width="fill_container", gap=8),
        H("r2", [metric_card("database", "磁盘", "312 GB", "Macintosh HD · 61%", 0.61),
                 metric_card("wifi", "网络", "1.2 MB/s", "↑ 240 KB/s · 192.168.1.8", 0.4)],
          width="fill_container", gap=8),
    ]
    return popover("P · 弹窗 · 状态", 0, body,
                   "弹窗 · 状态标签：卡片固定渲染，快捷操作是唯一可直接执行的区域。",
                   "note-popover1")


def popover_actions() -> dict:
    def arow(glyph: str, title: str, sub: str, tone: str = "$text-secondary",
             state: str | None = None) -> dict:
        kids = [icon(glyph, 15, tone, "g"),
                V("t", [text(title, 12.5, "$text-primary", "500", "n"),
                        text(sub, 10.5, "$text-tertiary", "s")], width="fill_container", gap=2)]
        if state:
            kids.append(chip(state, "$bg-elevated", "$text-tertiary"))
        return H("arow", kids, width="fill_container", fill="$bg-card", cornerRadius=9, gap=10,
                 padding=[10, 12], alignItems="center")

    body = [
        H("search", [icon("search", 13, "$text-tertiary", "g"),
                     text("搜索动作", 12, "$text-tertiary", "t")],
          width="fill_container", fill="$bg-card", cornerRadius=8, gap=6, padding=[7, 10],
          alignItems="center"),
        H("gl", [text("显示与屏幕", 10.5, "$text-tertiary", "t")], padding=[2, 12]),
        arow("monitor-off", "关闭显示器", "按钮 · 立即执行"),
        arow("moon", "深色模式", "开关 · 当前已开启", "$accent", "已开启"),
        arow("sun", "保持屏幕常亮", "开关 · 当前已关闭"),
        H("gl2", [text("系统", 10.5, "$text-tertiary", "t")], padding=[8, 12]),
        arow("trash-2", "清空废纸篓", "破坏性 · 运行前确认", "$danger"),
        arow("laptop", "隐藏刘海", "此设备不可用", "$warning"),
    ]
    return popover("Q · 弹窗 · 操作", 3, body,
                   "弹窗 · 操作标签：搜索 + 分组 + 状态徽章；破坏性动作标注在行内。",
                   "note-popover2")


def rule_editor() -> dict:
    trigger = card("触发器", "切换家族时手指数会被夹到该识别器支持的范围。", rows(
        row_picker("手势家族", "滑动"),
        row_stepper("手指数", "4 指", "滑动支持 2–5 指。"),
        row_picker("方向", "向下"),
        row_picker("区域", "任意位置"),
    ))

    advanced = card("高级 · 阈值与修饰键", "默认值适合大多数手势；只在偏离默认值时才需要打开。",
                    rows(
                        H("mods", [text("必需修饰键", 13, "$text-primary", "500", "n"),
                                   check("fn", False), check("⇧", False), check("⌃", False),
                                   check("⌥", False), check("⌘", False)],
                          width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                        row_slider("最长时长", "0.60 秒", 0.17, "0.12–3 秒"),
                        row_slider("位移容差", "3.5%", 0.14, "0.5%–25%"),
                        row_slider("最小滑动距离", "8%", 0.10, "0.5%–80%"),
                        row_slider("最小速度", "0", 0.02, "0–10"),
                    ))

    action = card("动作", "动作来自统一动作库，编辑器不再自带定义。", rows(
        row_picker("动作家族", "窗口摆放"),
        row_picker("摆放方式", "最大化"),
        row("可用性", "窗口动作首次运行时会申请辅助功能权限。",
            [chip("需要辅助功能", "$bg-elevated", "$warning", "alert-triangle")]),
    ))

    scope = card("作用范围", "指定应用的规则先于全局规则执行。", rows(
        row_picker("运行于", "仅选定的应用"),
        list_row("音乐", "com.apple.Music", [icon("minus-circle", 14, "$danger", "x")]),
        H("add", [text_field("com.example.app", 200, mono=False, placeholder=True),
                  href("BTN_SECONDARY", "add", descendants={"LABEL": {"content": "添加"}}),
                  href("BTN_SECONDARY", "run", descendants={"LABEL": {"content": "运行中的 App"}})],
          width="fill_container", gap=8, padding=[10, 14], alignItems="center"),
        row("未选择任何应用时", "规则不会运行；界面明确提示，而不是静默失败。",
            [chip("不会触发", "$bg-elevated", "$warning")]),
    ))

    footer = H("footer", [
        href("BTN_DANGER", "del", descendants={"LABEL": {"content": "删除规则"}}),
        H("sp", [], width="fill_container"),
        href("BTN_SECONDARY", "cancel", descendants={"LABEL": {"content": "取消"}}),
        href("BTN_PRIMARY", "save", descendants={"LABEL": {"content": "保存"}}),
    ], width="fill_container", gap=10, padding=[12, 16], alignItems="center")

    fr = V("R · 手势规则编辑器", [
        H("title", [text("编辑手势规则", 15, "$text-primary", "600", "t"),
                    H("sp", [], width="fill_container"),
                    icon("x", 15, "$text-tertiary", "close")],
          width="fill_container", gap=10, padding=[14, 16], alignItems="center"),
        rect("fill_container", 1, "$separator", "sp1"),
        V("body", [
            row_field("规则名称", "四指下滑", None, 220, mono=False),
            trigger, advanced, action, scope,
        ], width="fill_container", layout="vertical", gap=12, padding=[14, 16]),
        rect("fill_container", 1, "$separator", "sp2"),
        footer,
    ], width=560, fill="$bg-window", cornerRadius=12, clip=True, gap=0)
    fr["_note_id"] = "note-ruleEditor"
    fr["_note_text"] = "规则编辑器 · 三段式：触发器 → 动作 → 范围；高级参数默认折叠。"
    return fr


def build_pages() -> tuple[list[dict], list[dict]]:
    build_components()
    extras = [ia_frame(), tokens_frame()]
    pages = [
        page_menu_bar(), page_panel(), page_calendar(),
        page_trackpad_rules(), page_trackpad_feedback(), page_trackpad_runtime(),
        page_hotkeys(), page_action_center(),
        page_alerts(), page_power(), page_timezone(), page_general(), page_about(),
        popover_status(), popover_actions(), rule_editor(),
    ]
    return pages, extras


def page_menu_bar() -> dict:
    fmt = card("时钟格式", "结构化用选单拼装；高级直接写 Unicode 日期字段模式。",
               rows(
                   row_segmented("模式", ["结构化", "高级"], 1),
                   row_field("日期格式", "EEE MMM d", "留空则不显示日期。", 190),
                   row_field("时间格式", "HH:mm:ss", "必须包含有效时间符号，引号需成对。", 190),
                   row("预览", "当前格式在菜单栏中的实际宽度。",
                       [chip("周六 9月12日 11:23:56", "$bg-inset", "$text-primary")]),
                   row_picker("顺序", "日期在前，时间在后", "高级模式下按模式串自身顺序渲染。"),
               ),
               action=href("BTN_SECONDARY", "reset", descendants={"LABEL": {"content": "重置格式"}}))

    structured_note = card("结构化选项", "切到「高级」时这些值会被保留但不生效。",
                           rows(
                               row_picker("时钟制式", "24 小时"),
                               row_toggle("显示秒数", None, True),
                               row_picker("日期", "缩写"),
                               row_picker("星期", "短"),
                           ), tone="$bg-inset")

    carousel = card("时钟轮播", "至少保留一个时钟；拖动排序决定轮播顺序。",
                    rows(
                        row_stepper("切换间隔", "5 秒", "2–30 秒；在菜单栏时钟上滚动可临时切换。"),
                        list_row("系统时钟", "GMT-07:00 · Los Angeles", [
                            chip("自定义标签", "$bg-elevated", "$text-tertiary"),
                            icon("minus-circle", 15, "$danger", "del"),
                        ]),
                        list_row("上海", "GMT+08:00 · Asia/Shanghai", [
                            chip("自定义标签", "$bg-elevated", "$text-tertiary"),
                            icon("minus-circle", 15, "$danger", "del"),
                        ]),
                        H("add", [row_picker("", "Asia/Tokyo (GMT+09:00)"),
                                  href("BTN_SECONDARY", "add", descendants={"LABEL": {"content": "添加"}}),
                                  href("BTN_LINK", "sys", descendants={"LABEL": {"content": "添加系统时钟"}})],
                          width="fill_container", gap=12, padding=[10, 14], alignItems="center"),
                        row("第一项时钟的作用", "概览与外观设置的兜底时区；滚动切换只临时生效。",
                            [chip("被引用", "$bg-elevated", "$text-tertiary", "link")]),
                    ))

    return page(
        "C · 设置窗口 · 菜单栏", "menuBar", "菜单栏", "状态栏时钟、格式与轮播；时间与时区归入「时间与区域」。",
        "timer", [
            card("状态栏项目", None, rows(
                row_segmented("内容", ["时钟", "图标"], 0),
                row_picker("图标", "MenuCue 标志", "仅图标模式生效；点击图标打开面板。"),
            )),
            fmt,
            structured_note,
            carousel,
            card("相关设置已移出本页", None, rows(
                row_link("时区", "前往「时间与区域」",
                         "应用显示时区与 macOS 系统时区原先藏在本页底部。"),
            ), tone="$bg-inset"),
        ],
        status="时钟运行中",
        note="菜单栏 · 图标模式下格式控件整块置灰；预览与格式同卡；时区移出本页。",
        note_id="note-menuBar")


def page_panel() -> dict:
    tabs = card("弹窗标签", "第一个标签在打开面板时显示；左右滑动按此顺序切换。",
                [tbl_head("panel_tabs", ["标签", "说明", "顺序"])] + rows(
                    table_row([H("n", [icon("grip-vertical", 13, "$text-tertiary", "h"),
                                       text("状态", 12.5, "$text-primary", "500", "n")], gap=8,
                                 alignItems="center", width="fill_container"),
                               text("CPU / 内存 / 磁盘 / 网络 + 快捷操作", 11, "$text-tertiary", "d"),
                               chip("默认打开", "$accent-soft", "$accent")], widths=TABLE_COLS["panel_tabs"]),
                    table_row([H("n", [icon("grip-vertical", 13, "$text-tertiary", "h"),
                                       text("日历", 12.5, "$text-primary", "500", "n")], gap=8,
                                 alignItems="center", width="fill_container"),
                               text("月视图与近期事件", 11, "$text-tertiary", "d"),
                               icon("chevron-up", 12, "$text-tertiary", "u")], widths=TABLE_COLS["panel_tabs"]),
                    table_row([H("n", [icon("grip-vertical", 13, "$text-tertiary", "h"),
                                       text("电源", 12.5, "$text-primary", "500", "n")], gap=8,
                                 alignItems="center", width="fill_container"),
                               text("能耗与唤醒", 11, "$text-tertiary", "d"),
                               icon("chevron-down", 12, "$text-tertiary", "d2")], widths=TABLE_COLS["panel_tabs"]),
                    table_row([H("n", [icon("grip-vertical", 13, "$text-tertiary", "h"),
                                       text("操作", 12.5, "$text-primary", "500", "n")], gap=8,
                                 alignItems="center", width="fill_container"),
                               text("固定动作与搜索", 11, "$text-tertiary", "d"),
                               icon("chevron-down", 12, "$text-tertiary", "d3")], widths=TABLE_COLS["panel_tabs"]),
                ), gap=0,
                action=chip("4 个标签 · 全部显示", "$bg-elevated", "$text-tertiary"))

    cards = card("状态卡片", "固定渲染，不提供显隐与排序；风扇卡只出现在有风扇的 Mac 上。",
                 rows(
                     H("grid", [V("t1", [icon("cpu", 15, "$text-secondary", "g"),
                                         text("CPU", 11, "$text-secondary", "l")],
                                   width="fill_container", fill="$bg-inset", cornerRadius=9, gap=5,
                                   justifyContent="center", alignItems="center", padding=9),
                                V("t2", [icon("hard-drive", 15, "$text-secondary", "g"),
                                         text("内存", 11, "$text-secondary", "l")],
                                   width="fill_container", fill="$bg-inset", cornerRadius=9, gap=5,
                                   justifyContent="center", alignItems="center", padding=9),
                                V("t3", [icon("database", 15, "$text-secondary", "g"),
                                         text("磁盘", 11, "$text-secondary", "l")],
                                   width="fill_container", fill="$bg-inset", cornerRadius=9, gap=5,
                                   justifyContent="center", alignItems="center", padding=9),
                                V("t4", [icon("wifi", 15, "$text-secondary", "g"),
                                         text("网络", 11, "$text-secondary", "l")],
                                   width="fill_container", fill="$bg-inset", cornerRadius=9, gap=5,
                                   justifyContent="center", alignItems="center", padding=9)],
                       width="fill_container", gap=8, padding=[10, 14], alignItems="center"),
                     row_link("完整指标", "在仪表盘查看", "面板卡片是只读镜像；详情、历史与图表在仪表盘。"),
                 ))

    sampling = card("指标采样", "采样只在「状态」标签可见时运行；隐藏面板即停止。",
                    rows(
                        row_toggle("按电池电量自适应采样", "外接电源时最快，电量下降时自动放慢，久坐电池更省电。", True),
                        row("当前", None, [chip("外接电源", "$bg-elevated", "$text-secondary", "plug"),
                                          chip("每 1.5 秒采样一次", "$accent-soft", "$accent", "activity")]),
                        row_stepper("外接电源 / 满电", "1.5 秒", "0.5–30 秒，步进 0.5 秒。"),
                        row_stepper("低电量", "10 秒", "0.5–30 秒；不得小于最快间隔。"),
                        row_stepper("全速高于", "60%", "5%–95%；必须高于低电量阈值。"),
                        row_stepper("最慢低于", "20%", "5%–95%；必须低于全速阈值。"),
                        row("自适应关闭时", "以上四项不生效，面板按固定间隔采样。",
                            [chip("固定 1.5 秒", "$bg-elevated", "$text-tertiary")]),
                    ))

    return page(
        "D · 设置窗口 · 面板", "panel", "面板", "弹窗的标签与状态卡片，以及指标采样策略。",
        "layout-dashboard", [
            tabs,
            cards,
            sampling,
            card("动效已移至「通用 › 外观」", None, rows(
                row_link("动画效果", "前往「通用」", "它影响整个应用与设置窗口，不属于面板。"),
            ), tone="$bg-inset"),
        ],
        status="每 1.5 秒采样",
        note="面板 · 标签排序可视化；采样与弹窗外观分区；动效移出。",
        note_id="note-panel")


def page_calendar() -> dict:
    access = card("日历访问", "MenuCue 只读取事件，不写入、不修改。",
                  rows(
                      H("state", [icon("check-circle-2", 16, "$success", "g"),
                                  V("t", [text("完全访问已授权", 13, "$text-primary", "500", "n"),
                                          text("3 个日历源 · 最近刷新 11:23", 11, "$text-tertiary", "d")],
                                    width="fill_container", gap=2)],
                        width="fill_container", gap=10, padding=[10, 14], alignItems="center"),
                      row("权限被拒绝时", "本页只保留本卡，事件来源与月视图隐藏，并给出打开系统设置的入口。",
                          [chip("降级为空状态", "$bg-elevated", "$text-tertiary")]),
                  ))

    sources = card("事件来源", "选择「仅选定」后可逐个日历开关。",
                   rows(
                       row_segmented("显示范围", ["全部日历", "仅选定"], 0),
                       H("list", [H("c", [href("CHECKBOX_ON", "cb1"),
                                          ellipse(9, "#FF9F0A", "dot"),
                                          text("工作", 12.5, "$text-primary", "500", "n")],
                                    width="fill_container", gap=9, alignItems="center"),
                                  chip("12 个事件", "$bg-elevated", "$text-tertiary")],
                         width="fill_container", gap=12, padding=[9, 14], alignItems="center"),
                       sep(),
                       H("list", [H("c", [href("CHECKBOX_ON", "cb2"),
                                          ellipse(9, "#0A84FF", "dot"),
                                          text("个人", 12.5, "$text-primary", "500", "n")],
                                    width="fill_container", gap=9, alignItems="center"),
                                  chip("4 个事件", "$bg-elevated", "$text-tertiary")],
                         width="fill_container", gap=12, padding=[9, 14], alignItems="center"),
                       sep(),
                       H("list", [H("c", [href("CHECKBOX_OFF", "cb3"),
                                          ellipse(9, "#BF5AF2", "dot"),
                                          text("订阅 · 节假日", 12.5, "$text-secondary", "500", "n")],
                                    width="fill_container", gap=9, alignItems="center"),
                                  chip("已关闭", "$bg-elevated", "$text-tertiary")],
                         width="fill_container", gap=12, padding=[9, 14], alignItems="center"),
                   ))

    month = card("月视图", "影响面板日历标签与仪表盘日历。",
                 rows(
                     row_picker("每周起始日", "周一"),
                     row_toggle("显示农历", "在日期下方显示农历日期。", False),
                     row_picker("全天事件", "保持原样"),
                     row_toggle("显示日期距离", "在日期旁显示「今天 / 3 天后」。", True),
                     row_toggle("显示月度统计", "本月事件计数与工作日天数。", True),
                     row_picker("工作日依据", "中国法定节假日", "决定月度统计中的工作日与调休。"),
                 ))

    refresh = card("刷新", None, rows(
        row("自动刷新", "监听系统日历变更并防抖 0.2 秒刷新；无需手动操作。",
            [chip("已开启", "$accent-soft", "$accent", "refresh-cw")]),
        row_button("立即刷新", "刷新", "重新读取事件源并重算月度统计。"),
    ))

    denied = card("未授权状态（变体）", "权限被拒绝或受限时本页整体降级为下面这一块。",
                  [H("row", [texts_block := V("texts", [
                      text("MenuCue 无法读取你的日历", 13, "$text-primary", "500", "n"),
                      wrap("在「隐私与安全性 › 日历」中允许 MenuCue 访问，即可恢复事件来源与月视图。",
                           11, "$text-tertiary")], width="fill_container", gap=3),
                      href("BTN_PRIMARY", "b", descendants={"LABEL": {"content": "打开系统设置"}}),
                      href("BTN_SECONDARY", "b2", descendants={"LABEL": {"content": "再次请求访问"}})],
                    width="fill_container", gap=12, padding=[12, 14], alignItems="center")],
                  tone="$bg-inset")

    return page(
        "E · 设置窗口 · 日历", "calendar", "日历", "事件来源、月视图与节假日；权限状态放在最上面。",
        "calendar", [access, sources, month, refresh, denied],
        status="已授权 · 3 个日历",
        note="日历 · 权限卡置顶，未授权变体同页展示；来源选择可视化颜色。",
        note_id="note-calendar")




if __name__ == "__main__":
    sys.exit(main())
