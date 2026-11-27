# SPDX-License-Identifier: MIT
"""Steam shortcut discovery shared by lepton-add-game and the Android Library.

Only reads Steam's files. Writing shortcuts stays in lepton-add-game.
"""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import re
import struct

TOOLS = Path(__file__).resolve().parent


def manage_module():
    """lepton-manage-installs next to this file: Steam directory and installs."""
    loader = importlib.machinery.SourceFileLoader("lepton_manage_installs", str(TOOLS / "lepton-manage-installs"))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


def steam_root(required=True):
    """The native Steam directory Lepton uses, or None if Steam is absent and
    not required. Raises ValueError for an unsupported or ambiguous Steam."""
    return manage_module().steam_root(required=required)


def steam_running():
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            comm = (entry / "comm").read_text().strip()
        except (OSError, UnicodeError):
            continue
        if comm in {"steam", "steam.sh", "steamwebhelper"}:
            return True
    return False


def cstr(data, index):
    end = data.find(b"\x00", index)
    if end < 0:
        raise ValueError("Malformed Steam binary VDF: unterminated string")
    return data[index:end].decode("utf-8"), end + 1


def read_binary(data, spans=None):
    """Return shortcuts data, existing entry names, and root closing offset.
    If given, spans receives {(entry, key): (start, end)} of string values."""
    if not data:
        return {}, b"", 0
    if data[:11] != b"\x00shortcuts\x00":
        raise ValueError("Unrecognized shortcuts.vdf root; refusing to edit")

    def node(pos, path=()):
        fields = {}
        while pos < len(data):
            kind = data[pos]
            pos += 1
            if kind == 8:
                return fields, pos
            key, pos = cstr(data, pos)
            if kind == 0:
                value, pos = node(pos, path + (key,))
            elif kind == 1:
                start = pos
                value, pos = cstr(data, pos)
                if spans is not None:
                    spans[path + (key,)] = (start, pos - 1)
            elif kind == 2:
                if pos + 4 > len(data):
                    raise ValueError("Truncated VDF integer")
                value = struct.unpack_from("<I", data, pos)[0]
                pos += 4
            elif kind == 7:
                if pos + 8 > len(data):
                    raise ValueError("Truncated VDF uint64")
                value = struct.unpack_from("<Q", data, pos)[0]
                pos += 8
            else:
                raise ValueError("Unsupported VDF field type %s; refusing to edit" % kind)
            fields[key] = value
        raise ValueError("Truncated VDF object")

    root, end = node(11)
    # Binary VDF commonly has two trailing 0x08 terminators: one for the
    # "shortcuts" map and another for the implicit outer map. Other writers
    # omit the implicit outer terminator. Accept only these two shapes, and
    # insert new entries before the shortcuts map's own closing byte.
    if data[end:] not in (b"", b"\x08"):
        raise ValueError("Unexpected bytes after shortcuts.vdf root")
    return root, data, end - 1


def steam_users(steam):
    """[(userdata directory, label)] of this Steam's numeric users; the label
    is the account's name from config/loginusers.vdf when it is known."""
    userdata = steam / "userdata"
    users = sorted(p for p in userdata.iterdir() if p.is_dir() and p.name.isdigit()) if userdata.is_dir() else []
    names = {}
    try:
        text = (steam / "config/loginusers.vdf").read_text(encoding="utf-8", errors="replace")
    except OSError:
        text = ""
    for match in re.finditer(r'"(\d{17})"\s*\{([^{}]*)\}', text):
        persona = re.search(r'"PersonaName"\s*"([^"\n]*)"', match.group(2), re.I)
        account = re.search(r'"AccountName"\s*"([^"\n]*)"', match.group(2), re.I)
        label = (persona.group(1) if persona else "") or (account.group(1) if account else "")
        if label:
            names[str(int(match.group(1)) - 76561197960265728)] = label
    return [(user, names.get(user.name, "Steam user " + user.name)) for user in users]


def shortcuts_for(target):
    """Steam shortcuts, for every local Steam user, whose executable resolves
    to TARGET. Shortcuts are found by target, so a renamed shortcut is found
    too. Yields {"user", "appid", "name", "launch_options"}."""
    steam = steam_root(required=False)
    if steam is None:
        return
    target = Path(os.path.abspath(target)).resolve()
    for user, _ in steam_users(steam):
        shortcuts = user / "config/shortcuts.vdf"
        if not shortcuts.is_file():
            continue
        entries, _, _ = read_binary(shortcuts.read_bytes())
        for entry in entries.values():
            if not isinstance(entry, dict):
                continue
            exe = entry.get("Exe", "").strip('"')
            if exe and Path(exe).resolve() == target:
                yield {"user": user.name, "appid": entry.get("appid"), "name": entry.get("AppName"),
                       "launch_options": entry.get("LaunchOptions", "")}
