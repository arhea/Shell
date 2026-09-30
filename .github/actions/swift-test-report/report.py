#!/usr/bin/env python3
"""Render an Xcode .xcresult bundle as a Markdown test report.

Reads the bundle with `xcrun xcresulttool` (Xcode 16+) and `xcrun xccov`, then
writes a Markdown report: a summary (counts, duration, code coverage) followed
by full detail for every failed test: message, source location, a code
excerpt, arguments, device, and the recorded activity log. Passing and skipped
tests are only counted. A summary-only copy can be written for PR comments.

When running in GitHub Actions it also appends the report to the job summary,
emits an error annotation per failure, and sets step outputs.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import unquote, urlparse

# Cap per-test `activities` lookups so a mass failure doesn't take minutes.
MAX_ACTIVITY_LOOKUPS = 30
EXCERPT_CONTEXT = 3


# --- xcresult access ---------------------------------------------------------


def xcrun(*args: str, quiet: bool = False) -> dict | None:
    """Run an xcrun tool that prints JSON. Returns None if it fails."""
    proc = subprocess.run(["xcrun", *args], capture_output=True, text=True)
    if proc.returncode != 0:
        if quiet:
            return None
        print(f"warning: xcrun {' '.join(args[:3])} failed: {proc.stderr.strip()}", file=sys.stderr)
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        print(f"warning: xcrun {' '.join(args[:3])} returned invalid JSON", file=sys.stderr)
        return None


def test_results(bundle: str, kind: str, *extra: str) -> dict | None:
    return xcrun("xcresulttool", "get", "test-results", kind, "--path", bundle, "--compact", *extra)


# --- model -------------------------------------------------------------------


@dataclass
class Failure:
    message: str
    file: str | None = None
    line: int | None = None
    context: list[str] = field(default_factory=list)  # e.g. arguments, repetition, device


@dataclass
class FailedTest:
    identifier: str
    name: str
    suite: str
    target: str
    duration: str | None
    failures: list[Failure]
    activities: list[dict] = field(default_factory=list)
    devices: list[str] = field(default_factory=list)


# Node types that narrow down which run of a test failed.
CONTEXT_NODE_TYPES = {"Arguments", "Repetition", "Device", "Test Plan Configuration", "Runtime Warning"}


def collect_failures(node: dict, context: list[str]) -> list[Failure]:
    failures = []
    node_type = node.get("nodeType")
    if node_type == "Failure Message":
        loc = node.get("sourceLocation") or {}
        failures.append(Failure(node.get("name", ""), loc.get("filePath"), loc.get("lineNumber"), context))
        return failures
    if node_type in CONTEXT_NODE_TYPES and node.get("name"):
        label = "Arguments" if node_type == "Arguments" else node_type
        context = [*context, f"{label}: {node['name']}"]
    for child in node.get("children", []):
        failures.extend(collect_failures(child, context))
    return failures


def walk_tests(nodes: list[dict], target: str = "", suite: str = ""):
    """Yield (test case node, target, suite) for every test case in the tree."""
    for node in nodes:
        node_type = node.get("nodeType")
        if node_type == "Test Case":
            yield node, target, suite
            continue
        child_target, child_suite = target, suite
        if node_type in ("Unit test bundle", "UI test bundle"):
            child_target = node.get("name", target)
        elif node_type == "Test Suite":
            child_suite = f"{suite}/{node['name']}" if suite else node.get("name", "")
        yield from walk_tests(node.get("children", []), child_target, child_suite)


def load_failed_tests(bundle: str) -> list[FailedTest]:
    tree = test_results(bundle, "tests") or {}
    failed = []
    for node, target, suite in walk_tests(tree.get("testNodes", [])):
        identifier = node.get("nodeIdentifier") or f"{suite}/{node.get('name')}"
        if node.get("result") == "Failed":
            failures = collect_failures(node, [])
            if not failures:
                failures = [Failure("Test failed without a recorded failure message.")]
            failed.append(FailedTest(identifier, node.get("name", identifier), suite, target, node.get("duration"), failures))
    return failed


def load_activities(bundle: str, tests: list[FailedTest]) -> None:
    for test in tests[:MAX_ACTIVITY_LOOKUPS]:
        data = test_results(bundle, "activities", "--test-id", test.identifier)
        if not data:
            continue
        for run in data.get("testRuns", []):
            device = run.get("device") or {}
            if device:
                label = f"{device.get('deviceName', '?')} ({device.get('platform', '')} {device.get('osVersion', '')})".strip()
                if label not in test.devices:
                    test.devices.append(label)
            if not any(a.get("isAssociatedWithFailure") for a in walk_activities(run.get("activities", []))):
                continue
            args = ", ".join(a.get("value", "") for a in run.get("arguments", []))
            test.activities.append({"arguments": args, "activities": run.get("activities", [])})


def walk_activities(activities: list[dict]):
    for activity in activities:
        yield activity
        yield from walk_activities(activity.get("childActivities", []))


@dataclass
class Coverage:
    covered: int
    executable: int
    targets: list[tuple[str, int, int]]  # name, covered, executable
    files: list[tuple[str, int, int]]  # path, covered, executable

    @property
    def percent(self) -> float | None:
        return 100.0 * self.covered / self.executable if self.executable else None


def load_coverage(bundle: str, exclude: re.Pattern | None) -> Coverage | None:
    # Fails when the run had coverage off or never got past the build.
    report = xcrun("xccov", "view", "--report", "--json", bundle, quiet=True)
    if not report or not report.get("targets"):
        return None
    covered = executable = 0
    targets, files = [], []
    for target in report["targets"]:
        t_covered = t_exec = 0
        for f in target.get("files", []):
            if exclude and exclude.search(f.get("path", "")):
                continue
            t_covered += f.get("coveredLines", 0)
            t_exec += f.get("executableLines", 0)
            files.append((f.get("path", f.get("name", "?")), f.get("coveredLines", 0), f.get("executableLines", 0)))
        if t_exec:
            targets.append((target.get("name", "?"), t_covered, t_exec))
        covered += t_covered
        executable += t_exec
    return Coverage(covered, executable, targets, files)


def load_build_issues(bundle: str) -> tuple[list[dict], int]:
    build = xcrun("xcresulttool", "get", "build-results", "--path", bundle, "--compact") or {}
    return build.get("errors", []), build.get("warningCount", 0)


# --- formatting helpers ------------------------------------------------------


class Paths:
    """Turns absolute paths from the bundle into repo-relative paths and links."""

    def __init__(self, workspace: str | None, repo_url: str | None, sha: str | None):
        self.workspace = os.path.realpath(workspace) + "/" if workspace else None
        self.repo_url = repo_url
        self.sha = sha

    def relative(self, path: str) -> str:
        if self.workspace:
            real = os.path.realpath(path)
            if real.startswith(self.workspace):
                return real[len(self.workspace):]
        return path

    def in_repo(self, path: str) -> bool:
        return self.relative(path) != path or not os.path.isabs(path)

    def link(self, path: str, line: int | None) -> str:
        rel = self.relative(path)
        label = f"{rel}:{line}" if line else rel
        if self.repo_url and self.sha and self.in_repo(path):
            anchor = f"#L{line}" if line else ""
            return f"[`{label}`]({self.repo_url}/blob/{self.sha}/{rel}{anchor})"
        return f"`{label}`"


def fence(text: str, lang: str = "") -> str:
    ticks = "```"
    while ticks in text:
        ticks += "`"
    return f"{ticks}{lang}\n{text.rstrip()}\n{ticks}"


def cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.1f}%"


def duration(seconds: float | None) -> str:
    if seconds is None:
        return "n/a"
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, secs = divmod(int(round(seconds)), 60)
    return f"{minutes}m {secs:02d}s"


def excerpt(path: str | None, line: int | None) -> str | None:
    if not path or not line or not os.path.isfile(path):
        return None
    try:
        lines = Path(path).read_text(errors="replace").splitlines()
    except OSError:
        return None
    start = max(1, line - EXCERPT_CONTEXT)
    end = min(len(lines), line + EXCERPT_CONTEXT)
    width = len(str(end))
    out = []
    for n in range(start, end + 1):
        marker = ">" if n == line else " "
        out.append(f"{marker} {n:>{width}} | {lines[n - 1]}")
    return "\n".join(out)


def render_activities(activities: list[dict], depth: int = 0) -> list[str]:
    out = []
    for activity in activities:
        title = (activity.get("title") or "").strip()
        children = activity.get("childActivities", [])
        if title:
            flag = " ❌" if activity.get("isAssociatedWithFailure") else ""
            text = title.replace("\n", " ⏎ ")
            out.append(f"{'  ' * depth}- {text}{flag}")
            out.extend(render_activities(children, depth + 1))
        else:
            out.extend(render_activities(children, depth))
    return out


def parse_source_url(url: str | None) -> tuple[str | None, int | None]:
    """Build issue locations look like file:///path#StartingLineNumber=5&..."""
    if not url:
        return None, None
    parsed = urlparse(url)
    line = re.search(r"StartingLineNumber=(\d+)", parsed.fragment)
    # Xcode's line numbers in these URLs are zero-based.
    return unquote(parsed.path) or None, int(line.group(1)) + 1 if line else None


# --- report ------------------------------------------------------------------


@dataclass
class Report:
    summary: str  # counts and coverage only
    markdown: str  # summary plus failure details
    passed: int
    failed: int
    skipped: int
    total: int
    coverage: float | None
    annotations: list[str]
    ok: bool


def annotation(path: str | None, line: int | None, title: str, message: str, paths: Paths) -> str:
    def esc(s: str, prop: bool = False) -> str:
        s = s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        return s.replace(":", "%3A").replace(",", "%2C") if prop else s

    props = [f"title={esc(title, True)}"]
    if path:
        props.insert(0, f"file={esc(paths.relative(path), True)}")
        if line:
            props.insert(1, f"line={line}")
    return f"::error {','.join(props)}::{esc(message)}"


def build_report(bundle: str, title: str, paths: Paths, exclude: re.Pattern | None) -> Report:
    summary = test_results(bundle, "summary") or {}
    failed_tests = load_failed_tests(bundle)
    load_activities(bundle, failed_tests)
    coverage = load_coverage(bundle, exclude)
    build_errors, warning_count = load_build_issues(bundle)
    build_errors = [e for e in build_errors if e.get("message") != "Testing cancelled because the build failed."] or build_errors

    passed = summary.get("passedTests", 0)
    failed = summary.get("failedTests", 0)
    skipped = summary.get("skippedTests", 0)
    expected = summary.get("expectedFailures", 0)
    total = summary.get("totalTestCount", passed + failed + skipped + expected)
    result = summary.get("result", "unknown")
    # A failed build produces a bundle with no tests and result "unknown".
    ok = result == "Passed" and failed == 0 and not (total == 0 and build_errors)
    elapsed = None
    if summary.get("startTime") and summary.get("finishTime"):
        elapsed = summary["finishTime"] - summary["startTime"]

    md: list[str] = []
    icon = "✅" if ok else "❌"
    md.append(f"## {icon} {title}")
    md.append("")
    md.append("| Result | Passed | Failed | Skipped | Total | Coverage | Duration |")
    md.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    status = "Passed" if ok else ("Build failed" if total == 0 and build_errors else "Failed")
    failed_cell = f"**{failed}**" if failed else "0"
    skipped_cell = f"{skipped}" + (f" (+{expected} expected failures)" if expected else "")
    md.append(
        f"| {status} | {passed} | {failed_cell} | {skipped_cell} | {total} "
        f"| {pct(coverage.percent if coverage else None)} | {duration(elapsed)} |"
    )
    md.append("")

    env = []
    if summary.get("environmentDescription"):
        env.append(summary["environmentDescription"])
    for dc in summary.get("devicesAndConfigurations", []):
        d = dc.get("device", {})
        config = dc.get("testPlanConfiguration", {}).get("configurationName")
        env.append(f"{d.get('modelName', d.get('deviceName', '?'))} · {d.get('platform', '')} {d.get('osVersion', '')} ({d.get('architecture', '')})"
                   + (f" · {config}" if config else ""))
    if env:
        md.append(f"<sub>{' — '.join(cell(e) for e in env)}</sub>")
        md.append("")

    if coverage and coverage.targets:
        md.append("<details><summary>Code coverage by target</summary>")
        md.append("")
        md.append("| Target | Covered lines | Executable lines | Coverage |")
        md.append("| --- | ---: | ---: | ---: |")
        for name, c, e in sorted(coverage.targets, key=lambda t: t[0]):
            md.append(f"| {cell(name)} | {c:,} | {e:,} | {pct(100.0 * c / e)} |")
        md.append(f"| **All** | **{coverage.covered:,}** | **{coverage.executable:,}** | **{pct(coverage.percent)}** |")
        md.append("")
        lowest = sorted((f for f in coverage.files if f[2]), key=lambda f: (f[1] / f[2], -f[2]))[:10]
        if lowest:
            md.append("Least covered files:")
            md.append("")
            md.append("| File | Covered | Coverage |")
            md.append("| --- | ---: | ---: |")
            for path, c, e in lowest:
                md.append(f"| {paths.link(path, None)} | {c:,} / {e:,} | {pct(100.0 * c / e)} |")
            md.append("")
        md.append("</details>")
        md.append("")

    summary_md = "\n".join(md).rstrip() + "\n"
    annotations: list[str] = []

    if not ok and build_errors:
        md.append(f"### 🛑 Build errors ({len(build_errors)})")
        md.append("")
        for err in build_errors:
            path, line = parse_source_url(err.get("sourceURL"))
            kind = err.get("issueType", "Error")
            where = f" — {paths.link(path, line)}" if path else ""
            md.append(f"- **{cell(kind)}**{where}")
            md.append("")
            md.append(fence(err.get("message", ""), "text"))
            snippet = excerpt(path, line)
            if snippet:
                md.append("")
                md.append(fence(snippet, "swift"))
            md.append("")
            annotations.append(annotation(path, line, kind, err.get("message", ""), paths))
        if warning_count:
            md.append(f"<sub>{warning_count} build warning(s) not shown.</sub>")
            md.append("")

    if failed_tests:
        md.append(f"### ❌ Failed tests ({len(failed_tests)})")
        md.append("")
        for test in failed_tests:
            where = f"{test.target} › {test.suite}" if test.suite else test.target
            md.append(f"#### `{test.identifier}`")
            md.append("")
            meta = [f"**Target:** {cell(where)}"]
            if test.duration:
                meta.append(f"**Duration:** {test.duration}")
            if test.devices:
                meta.append(f"**Ran on:** {cell(', '.join(test.devices))}")
            md.append(" · ".join(meta))
            md.append("")
            for i, failure in enumerate(test.failures, 1):
                heading = f"**Failure {i} of {len(test.failures)}**" if len(test.failures) > 1 else "**Failure**"
                loc = f" at {paths.link(failure.file, failure.line)}" if failure.file else ""
                ctx = f" ({cell('; '.join(failure.context))})" if failure.context else ""
                md.append(f"{heading}{loc}{ctx}")
                md.append("")
                md.append(fence(failure.message, "text"))
                snippet = excerpt(failure.file, failure.line)
                if snippet:
                    md.append("")
                    md.append(fence(snippet, "swift"))
                md.append("")
                annotations.append(annotation(failure.file, failure.line, f"{test.target}: {test.identifier}", failure.message, paths))
            logs = [(run["arguments"], render_activities(run["activities"])) for run in test.activities]
            # Skip logs that only repeat the failure messages shown above.
            messages = {f.message.strip() for f in test.failures}
            logs = [(args, lines) for (args, lines), run in zip(logs, test.activities)
                    if any((a.get("title") or "").strip() not in messages | {""}
                           for a in walk_activities(run["activities"]))]
            if logs:
                md.append("<details><summary>Activity log</summary>")
                md.append("")
                for args, lines in logs:
                    if args:
                        md.append(f"Arguments: `{args}`")
                        md.append("")
                    md.extend(lines)
                    md.append("")
                md.append("</details>")
                md.append("")

    return Report(summary_md, "\n".join(md).rstrip() + "\n", passed, failed, skipped, total,
                  coverage.percent if coverage else None, annotations, ok)


def missing_bundle_report(bundle: str, title: str) -> Report:
    md = (f"## ❌ {title}\n\nNo result bundle at `{bundle}`. The test step likely failed "
          "before `xcodebuild` wrote results; check the step log.\n")
    return Report(md, md, 0, 0, 0, 0, None, [f"::error title={title}::No result bundle at {bundle}"], False)


def truncate(markdown: str, limit: int) -> str:
    if len(markdown) <= limit:
        return markdown
    note = "\n\n> ⚠️ Report truncated. The full report is in the step output `report`."
    cut = markdown[: limit - len(note)]
    # Don't leave a code fence open.
    if cut.count("```") % 2:
        cut += "\n```"
    return cut + note + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("xcresult", help="Path to the .xcresult bundle")
    parser.add_argument("--title", default="Test results")
    parser.add_argument("--output", default="test-report.md", help="Where to write the full Markdown report")
    parser.add_argument("--summary-output", help="Also write the summary alone (no per-test detail), e.g. for a PR comment")
    parser.add_argument("--coverage-exclude", default=r"/Tests/|Tests?\.swift$",
                        help="Regex of source paths to leave out of coverage ('' to include everything)")
    parser.add_argument("--workspace", default=os.environ.get("GITHUB_WORKSPACE", os.getcwd()))
    parser.add_argument("--sha", default=os.environ.get("REPORT_SHA") or os.environ.get("GITHUB_SHA"))
    args = parser.parse_args()

    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    repo = os.environ.get("GITHUB_REPOSITORY")
    repo_url = f"{server}/{repo}" if repo else None
    run_id = os.environ.get("GITHUB_RUN_ID")
    run_link = f"{repo_url}/actions/runs/{run_id}" if repo_url and run_id else None

    exclude = re.compile(args.coverage_exclude) if args.coverage_exclude else None
    paths = Paths(args.workspace, repo_url, args.sha)

    if os.path.isdir(args.xcresult):
        report = build_report(args.xcresult, args.title, paths, exclude)
    else:
        report = missing_bundle_report(args.xcresult, args.title)

    Path(args.output).write_text(report.markdown)
    if args.summary_output:
        summary = report.summary
        if not report.ok and run_link:
            summary += f"\nFailure details are in the [workflow run summary]({run_link}).\n"
        Path(args.summary_output).write_text(summary)

    for line in report.annotations:
        print(line)

    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        # The job summary accepts up to 1 MiB per step.
        with open(summary_path, "a") as f:
            f.write(truncate(report.markdown, 1_000_000))

    if output_path := os.environ.get("GITHUB_OUTPUT"):
        coverage = "" if report.coverage is None else f"{report.coverage:.2f}"
        with open(output_path, "a") as f:
            f.write(f"passed={report.passed}\nfailed={report.failed}\nskipped={report.skipped}\n"
                    f"total={report.total}\ncoverage={coverage}\n"
                    f"report={os.path.abspath(args.output)}\n")

    print(f"{report.passed} passed, {report.failed} failed, {report.skipped} skipped; coverage {pct(report.coverage)}",
          file=sys.stderr)
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
