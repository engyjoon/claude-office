#!/usr/bin/env python3
"""Claude Office M0 — 훅 페이로드 수집 도구

사용법 (저장소 루트에서):
    python3 scripts/capture.py install            # 수집 훅 설치 (settings.json 백업 후 병합)
    python3 scripts/capture.py install --basic    # 확장 이벤트 없이 기본 이벤트만
    python3 scripts/capture.py status             # 설치 상태와 수집 건수
    python3 scripts/capture.py report             # 필드 구조 요약 (값 없이 키만) → 공유해도 안전
    python3 scripts/capture.py breakdown          # 서브에이전트 생애·툴 짝 집계 (값 없이) → 공유해도 안전
    python3 scripts/capture.py export             # 민감 정보를 가린 테스트 픽스처 생성
    python3 scripts/capture.py uninstall          # 수집 훅 제거 (다른 훅은 그대로)

원본 데이터는 ~/claude-office-capture/raw/ 에만 저장됩니다. 원본에는 프롬프트와 파일 내용이
들어 있을 수 있으니 저장소에 커밋하지 말고, export 결과를 검토한 뒤에만 커밋하세요.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

HOME = Path.home()
CLAUDE_DIR = HOME / ".claude"
SETTINGS = CLAUDE_DIR / "settings.json"
HOOK_DST = CLAUDE_DIR / "hooks" / "claude-office-capture.sh"
HOOK_SRC = Path(__file__).resolve().parent / "capture-hook.sh"
CAPTURE_DIR = HOME / "claude-office-capture"
RAW_DIR = CAPTURE_DIR / "raw"
MARKER = "claude-office-capture.sh"

# 대부분의 Claude Code 버전에서 지원하는 이벤트. 도구 이벤트는 matcher "*"로 전부 받습니다.
BASE_EVENTS = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
               "Notification", "Stop", "SubagentStop", "PreCompact"]
# 2.1.318에서 확인한 확장 이벤트. 이 버전 이상이면 자동으로 함께 등록합니다.
EXTENDED_EVENTS = ["SubagentStart", "PermissionRequest", "PermissionDenied", "PostToolUseFailure", "StopFailure"]
EXTENDED_MIN_VERSION = (2, 1, 318)
TOOL_EVENTS = {"PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied"}

DEFAULT_OUT = Path(__file__).resolve().parent.parent / "Tests" / "OfficeCoreTests" / "Fixtures" / "captured"


# ---------------------------------------------------------------- settings.json

def load_settings() -> dict:
    if not SETTINGS.exists():
        return {}
    try:
        return json.loads(SETTINGS.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        sys.exit(f"~/.claude/settings.json을 JSON으로 읽을 수 없습니다 ({e}). 파일을 직접 확인해 주세요. 아무것도 바꾸지 않았습니다.")


def save_settings(data: dict) -> Path | None:
    backup = None
    if SETTINGS.exists():
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = SETTINGS.with_name(f"settings.json.bak-{stamp}")
        shutil.copy2(SETTINGS, backup)
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    tmp = SETTINGS.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(SETTINGS)
    return backup


def is_ours(group: dict) -> bool:
    return any(MARKER in str(h.get("command", "")) for h in group.get("hooks", []))


def strip_ours(data: dict) -> int:
    removed = 0
    hooks = data.get("hooks", {})
    for event in list(hooks.keys()):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        kept = [g for g in groups if not (isinstance(g, dict) and is_ours(g))]
        removed += len(groups) - len(kept)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if "hooks" in data and not data["hooks"]:
        del data["hooks"]
    return removed


# ---------------------------------------------------------------- commands

def cmd_install(args) -> None:
    if not HOOK_SRC.exists():
        sys.exit(f"{HOOK_SRC} 를 찾을 수 없습니다. 저장소 루트에서 실행해 주세요.")
    version = claude_version()
    events = list(BASE_EVENTS)
    parsed = parse_version(version)
    if not args.basic and parsed and parsed >= EXTENDED_MIN_VERSION:
        events += EXTENDED_EVENTS
    if args.extra:
        events += [e.strip() for e in args.extra.split(",") if e.strip() and e.strip() not in events]

    HOOK_DST.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(HOOK_SRC, HOOK_DST)
    HOOK_DST.chmod(HOOK_DST.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    data = load_settings()
    strip_ours(data)  # 재설치해도 중복되지 않게
    hooks = data.setdefault("hooks", {})
    for event in events:
        group = {"hooks": [{"type": "command", "command": str(HOOK_DST)}]}
        if event in TOOL_EVENTS:
            group = {"matcher": "*", **group}
        hooks.setdefault(event, []).append(group)
    backup = save_settings(data)

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    (CAPTURE_DIR / "meta.json").write_text(json.dumps({
        "installed_at": dt.datetime.now().astimezone().isoformat(),
        "claude_version": version,
        "events": events,
    }, ensure_ascii=False, indent=2), encoding="utf-8")

    print("수집 훅을 설치했습니다.")
    print(f"  훅 스크립트 : {HOOK_DST}")
    print(f"  등록 이벤트 : {', '.join(events)}")
    print(f"  설정 백업   : {backup or '(기존 settings.json 없음)'}")
    print(f"  Claude Code : {version or '버전을 확인하지 못했습니다'}")
    if not parsed or parsed < EXTENDED_MIN_VERSION:
        print(f"  참고        : {'.'.join(map(str, EXTENDED_MIN_VERSION))} 미만이거나 버전을 몰라서 기본 이벤트만 등록했습니다.")
    print()
    print("다음 단계:")
    print("  1. 새 터미널에서 claude를 실행하고, /hooks 를 입력해 위 이벤트가 보이는지 확인하세요.")
    print("  2. 서브에이전트를 쓰는 작업을 한두 번 해주세요. (docs/M0-capture.md 의 시나리오 참고)")
    print("  3. python3 scripts/capture.py report")


def cmd_uninstall(args) -> None:
    data = load_settings()
    removed = strip_ours(data)
    if removed:
        backup = save_settings(data)
        print(f"settings.json에서 수집 훅 {removed}개를 제거했습니다. (백업: {backup})")
    else:
        print("settings.json에 수집 훅이 없습니다.")
    if HOOK_DST.exists():
        HOOK_DST.unlink()
        print(f"{HOOK_DST} 를 삭제했습니다.")
    print(f"수집한 원본은 {RAW_DIR} 에 남아 있습니다. 필요 없으면 직접 지워 주세요.")


def cmd_status(args) -> None:
    data = load_settings()
    events = [e for e, groups in data.get("hooks", {}).items()
              if isinstance(groups, list) and any(isinstance(g, dict) and is_ours(g) for g in groups)]
    print(f"설치 상태 : {'설치됨' if events else '설치 안 됨'}")
    if events:
        print(f"등록 이벤트 : {', '.join(events)}")
    records = load_records()
    print(f"수집 건수 : {len(records)}건 ({RAW_DIR})")
    counts = Counter(r["payload"].get("hook_event_name", "?") for r in records)
    for name, n in counts.most_common():
        print(f"  {name:<20} {n}")


def load_records() -> list[dict]:
    out = []
    if not RAW_DIR.exists():
        return out
    for f in sorted(RAW_DIR.glob("*.json")):
        try:
            rec = json.loads(f.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        if isinstance(rec, dict) and isinstance(rec.get("payload"), dict):
            rec["_file"] = f.name
            rec["_mtime"] = f.stat().st_mtime_ns  # 같은 초 안의 순서를 맞추기 위해 파일 수정 시각(나노초)을 씁니다
            out.append(rec)
    return out


def shape(value, depth=0):
    """값을 지우고 타입 구조만 남깁니다."""
    if isinstance(value, dict):
        if depth >= 2:
            return "{…}"
        return {k: shape(v, depth + 1) for k, v in sorted(value.items())}
    if isinstance(value, list):
        return [shape(value[0], depth + 1)] if value else []
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if value is None:
        return "null"
    return "string"


def cmd_report(args) -> None:
    records = load_records()
    if not records:
        sys.exit("수집된 데이터가 없습니다. install 후 Claude Code를 사용해 주세요.")
    meta = {}
    if (CAPTURE_DIR / "meta.json").exists():
        meta = json.loads((CAPTURE_DIR / "meta.json").read_text(encoding="utf-8"))

    by_event: dict[str, list[dict]] = defaultdict(list)
    for r in records:
        by_event[r["payload"].get("hook_event_name", "?")].append(r["payload"])

    lines = ["# Claude Office 훅 페이로드 리포트", "",
             f"- Claude Code 버전: {meta.get('claude_version') or '알 수 없음'}",
             f"- 수집 건수: {len(records)}",
             f"- 터미널: {', '.join(sorted({r.get('term_program') or '?' for r in records}))}",
             "", "값은 모두 지우고 키와 타입만 남겼습니다.", ""]

    for event in sorted(by_event):
        payloads = by_event[event]
        lines.append(f"## {event} ({len(payloads)}건)")
        keys = Counter(k for p in payloads for k in p.keys())
        lines.append("")
        lines.append("| 키 | 등장 | 타입 |")
        lines.append("|---|---|---|")
        for k, n in sorted(keys.items()):
            sample = next(p[k] for p in payloads if k in p)
            t = shape(sample)
            t = json.dumps(t, ensure_ascii=False) if not isinstance(t, str) else t
            if len(t) > 120:
                t = t[:117] + "…"
            lines.append(f"| `{k}` | {n}/{len(payloads)} | `{t}` |")
        if event in TOOL_EVENTS:
            tools: dict[str, Counter] = defaultdict(Counter)
            for p in payloads:
                ti = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
                tools[p.get("tool_name", "?")].update(ti.keys())
            lines.append("")
            lines.append("| tool_name | 건수 | tool_input 키 |")
            lines.append("|---|---|---|")
            tc = Counter(p.get("tool_name", "?") for p in payloads)
            for name, n in tc.most_common():
                lines.append(f"| `{name}` | {n} | {', '.join(sorted(tools[name])) or '-'} |")
        if event == "Notification":
            nt = Counter(str(p.get("notification_type", "(없음)")) for p in payloads)
            lines.append("")
            lines.append("notification_type: " + ", ".join(f"`{k}` × {v}" for k, v in nt.most_common()))
        lines.append("")

    report = "\n".join(lines)
    (CAPTURE_DIR / "report.md").write_text(report, encoding="utf-8")
    print(report)
    print(f"\n(저장됨: {CAPTURE_DIR / 'report.md'})")


# ---------------------------------------------------------------- breakdown

SHORT = {"PreToolUse": "Pre", "PostToolUse": "Post", "PostToolUseFailure": "Fail", "PermissionRequest": "Perm",
         "PermissionDenied": "Denied", "SubagentStart": "Start", "SubagentStop": "Stop", "Notification": "Noti"}


def cmd_breakdown(args) -> None:
    """서브에이전트와 툴 호출의 짝을 값 없이 집계합니다 (agent_id는 S1, S2…로 바꿈)."""
    records = sorted(load_records(), key=lambda r: (r["_mtime"], r["_file"]))
    if not records:
        sys.exit("수집된 데이터가 없습니다.")
    alias: dict[str, str] = {}

    def name_of(agent_id: str) -> str:
        if agent_id not in alias:
            alias[agent_id] = f"S{len(alias) + 1}"
        return alias[agent_id]

    lines = ["# Claude Office 서브에이전트 집계", "",
             "agent_id는 S1, S2…로 바꿨고, 툴 입력·출력 값은 넣지 않았습니다. 순서는 파일 수정 시각 기준입니다.", ""]

    # 1) 이벤트 × 주체 × 툴
    counts: Counter = Counter()
    for r in records:
        p = r["payload"]
        event = p.get("hook_event_name", "?")
        if event in ("SubagentStart", "SubagentStop"):
            actor = f"대상 {p.get('agent_type') or '(빈 값)'}"
        else:
            actor = (p.get("agent_type") or "(빈 값)") if p.get("agent_id") else "(메인)"
        counts[(event, actor, p.get("tool_name", ""))] += 1
    lines += ["## 1. 이벤트별 주체", "", "| 이벤트 | 주체 (서브에이전트 종류 / 메인) | 툴 | 건수 |", "|---|---|---|---|"]
    for (event, actor, tool), n in sorted(counts.items()):
        lines.append(f"| {event} | {actor} | {tool or '-'} | {n} |")

    # 2) 서브에이전트별 생애
    timelines: dict[str, list[str]] = defaultdict(list)
    types: dict[str, str] = {}
    previous_main_tool: dict[str, str] = {}
    last_main_tool = "-"
    for r in records:
        p = r["payload"]
        event = p.get("hook_event_name", "?")
        tool = p.get("tool_name")
        agent_id = p.get("agent_id")
        if not agent_id:
            if event == "PreToolUse" and tool:
                last_main_tool = tool
            continue
        name = name_of(agent_id)
        types.setdefault(name, p.get("agent_type") or "(빈 값)")
        if not timelines[name]:
            previous_main_tool[name] = last_main_tool
        timelines[name].append(SHORT.get(event, event) + (f"({tool})" if tool else ""))
    lines += ["", "## 2. 서브에이전트별 생애", "",
              "| 이름 | 종류 | 처음 보이기 직전 메인의 툴 | 이벤트 수 | 순서 (앞 14개) |", "|---|---|---|---|---|"]
    for name in sorted(timelines, key=lambda x: int(x[1:])):
        seq = timelines[name]
        shown = " → ".join(seq[:14]) + (" …" if len(seq) > 14 else "")
        lines.append(f"| {name} | {types[name]} | {previous_main_tool.get(name, '-')} | {len(seq)} | {shown} |")

    # 3) 짝이 없는 툴 호출
    started: dict[str, str] = {}
    finished: set[str] = set()
    for r in records:
        p = r["payload"]
        tool_use_id = p.get("tool_use_id")
        if not tool_use_id:
            continue
        if p.get("hook_event_name") == "PreToolUse":
            started[tool_use_id] = p.get("tool_name", "?")
        elif p.get("hook_event_name") in ("PostToolUse", "PostToolUseFailure", "PermissionDenied"):
            finished.add(tool_use_id)
    dangling = Counter(name for tid, name in started.items() if tid not in finished)
    lines += ["", "## 3. 시작만 있고 끝이 없는 툴 호출", ""]
    lines.append(", ".join(f"`{k}` × {v}" for k, v in dangling.most_common()) or "없음")

    # 4) 위임 툴의 옵션
    delegations = Counter()
    for r in records:
        p = r["payload"]
        if p.get("hook_event_name") == "PreToolUse" and p.get("tool_name") in ("Agent", "Task"):
            ti = p.get("tool_input") or {}
            delegations[(ti.get("subagent_type") or "(없음)", bool(ti.get("run_in_background")))] += 1
    lines += ["", "## 4. 위임 (Agent/Task 툴)", "", "| subagent_type | 백그라운드 | 건수 |", "|---|---|---|"]
    for (kind, background), n in sorted(delegations.items()):
        lines.append(f"| {kind} | {'예' if background else '아니오'} | {n} |")

    report = "\n".join(lines)
    (CAPTURE_DIR / "breakdown.md").write_text(report, encoding="utf-8")
    print(report)
    print(f"\n(저장됨: {CAPTURE_DIR / 'breakdown.md'})")


# ---------------------------------------------------------------- export (sanitize)

class Sanitizer:
    LONG = 80
    SECRET_KV = re.compile(r"(?i)((?:password|passwd|pwd|token|secret|api[_-]?key|auth)[\w-]*\s*[=: ]\s*)(\"[^\"]*\"|'[^']*'|\S+)")
    SECRET_BLOB = re.compile(r"\b(?:[A-Za-z0-9+/_-]{32,}={0,2}|[0-9a-fA-F]{24,})\b")
    MASK_KEYS = {"prompt", "content", "new_string", "old_string", "file_text", "output", "stdout", "stderr",
                 "last_assistant_message", "edits"}

    def __init__(self, keep_names: bool):
        self.keep_names = keep_names
        self.projects: dict[str, str] = {}

    def project_alias(self, cwd: str) -> str:
        if cwd not in self.projects:
            self.projects[cwd] = f"~/work/project-{len(self.projects) + 1}"
        return self.projects[cwd]

    def text(self, s: str) -> str:
        if not self.keep_names:
            for real, alias in sorted(self.projects.items(), key=lambda kv: -len(kv[0])):
                s = s.replace(real, alias)
        s = s.replace(str(HOME), "~")
        s = self.SECRET_KV.sub(lambda m: m.group(1) + "<가림>", s)
        s = self.SECRET_BLOB.sub("<가림>", s)
        if len(s) > self.LONG:
            s = s[: self.LONG - 1] + f"…<{len(s)}자 생략>"
        return s

    def walk(self, value, key: str = ""):
        if key in self.MASK_KEYS and isinstance(value, (str, list)):
            return f"<{key}: {len(value)}{'자' if isinstance(value, str) else '개'} 가림>"
        if isinstance(value, dict):
            return {k: self.walk(v, k) for k, v in value.items()}
        if isinstance(value, list):
            return [self.walk(v, key) for v in value[:3]] + ([f"<{len(value) - 3}개 생략>"] if len(value) > 3 else [])
        if isinstance(value, str):
            return self.text(value)
        return value


def cmd_export(args) -> None:
    records = load_records()
    if not records:
        sys.exit("수집된 데이터가 없습니다.")
    out = Path(args.out).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    sani = Sanitizer(args.keep_project_names)
    for r in records:
        cwd = r["payload"].get("cwd")
        if isinstance(cwd, str):
            sani.project_alias(cwd)

    picked: dict[tuple, int] = Counter()
    written = 0
    for r in records:
        p = r["payload"]
        key = (p.get("hook_event_name", "?"), p.get("tool_name", ""))
        if picked[key] >= args.per_kind:
            continue
        picked[key] += 1
        clean = {"captured_at": r.get("captured_at"), "term_program": r.get("term_program"),
                 "payload": sani.walk(p)}
        name = f"{key[0]}{'-' + key[1].replace('__', '-') if key[1] else ''}-{picked[key]}.json"
        (out / name).write_text(json.dumps(clean, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        written += 1
    print(f"{written}개 픽스처를 {out} 에 저장했습니다.")
    print("커밋하기 전에 파일을 열어 회사 코드, 서버 주소, 계정 정보 같은 내용이 남아 있지 않은지 꼭 확인해 주세요.")


def parse_version(text: str | None) -> tuple[int, ...] | None:
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", text or "")
    return tuple(int(x) for x in m.groups()) if m else None


def claude_version() -> str | None:
    exe = shutil.which("claude")
    if not exe:
        return None
    try:
        r = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=10)
        return (r.stdout or r.stderr).strip() or None
    except (OSError, subprocess.TimeoutExpired):
        return None


def main() -> None:
    ap = argparse.ArgumentParser(description="Claude Office M0 훅 페이로드 수집 도구")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("install", help="수집 훅 설치")
    p.add_argument("--extra", help="추가로 등록할 이벤트 (쉼표 구분)")
    p.add_argument("--basic", action="store_true", help="버전과 관계없이 기본 이벤트만 등록")
    p.set_defaults(func=cmd_install)
    sub.add_parser("uninstall", help="수집 훅 제거").set_defaults(func=cmd_uninstall)
    sub.add_parser("status", help="설치 상태와 수집 건수").set_defaults(func=cmd_status)
    sub.add_parser("report", help="필드 구조 리포트 (값 없음)").set_defaults(func=cmd_report)
    sub.add_parser("breakdown", help="서브에이전트 생애·툴 짝 집계 (값 없음)").set_defaults(func=cmd_breakdown)
    p = sub.add_parser("export", help="민감 정보를 가린 픽스처 생성")
    p.add_argument("--out", default=str(DEFAULT_OUT))
    p.add_argument("--per-kind", type=int, default=3, help="이벤트·툴 조합당 최대 개수 (기본 3)")
    p.add_argument("--keep-project-names", action="store_true", help="프로젝트 경로를 가리지 않음")
    p.set_defaults(func=cmd_export)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
