"""Guard the explicit Swift test lanes in the current shared-workflow format.

This deliberately reads only build-test-package's existing indentation and
literal run blocks. It is not a general YAML or shell parser; changing that
format requires reviewing the guard rather than silently losing a gate.
"""

from dataclasses import dataclass
from pathlib import Path
import re
import shlex
import unittest


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/verify.yml"
RENDER = "P1RegressionTests.renderingYieldsMainActorAndLatestRevisionWins"
EXPORT = "SelfContainedHTMLExportTests.exportImageBuilderRunsOffMainActorWhileInputCanContinue"
SCALING = "InlineRenderingPerformanceTests"


@dataclass
class Step:
    raw: str
    keys: set[str]
    commands: list[list[str]]


def read_steps(workflow):
    match = re.search(
        r"^  build-test-package:\n(.*?)(?=^  [\w-]+:|\Z)",
        workflow, re.MULTILINE | re.DOTALL,
    )
    if not match or "    steps:\n" not in match[1]:
        raise AssertionError("Expected literal build-test-package steps")
    header, body = match[1].split("    steps:\n", 1)
    if re.search(r"^    (if|continue-on-error)\s*:", header, re.MULTILINE):
        raise AssertionError("Test job must not be conditional or tolerate failure")
    starts = list(re.finditer(r"^      - ", body, re.MULTILINE))
    steps = []
    for index, start in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(body)
        raw = body[start.start():end]
        keys = set(re.findall(r"^(?:      - |        )([\w-]+)\s*:", raw, re.MULTILINE))
        run = re.search(r"^        run: (.*)$", raw, re.MULTILINE)
        commands = []
        if run:
            if run[1] == "|":
                lines = []
                for line in raw[run.end():].splitlines():
                    if line.strip() and not line.startswith("          "):
                        break
                    lines.append(line.strip())
            else:
                lines = [run[1]]
            commands = [tokens for line in lines if (tokens := shlex.split(line, comments=True))]
        steps.append(Step(raw, keys, commands))
    return steps


def validate_lanes(workflow):
    steps = read_steps(workflow)

    def unique_step(predicate, label):
        found = [(index, step) for index, step in enumerate(steps) if predicate(step)]
        if len(found) != 1:
            raise AssertionError(f"Expected exactly one {label} step")
        return found[0]

    package_index, _ = unique_step(
        lambda step: ["bash", "Scripts/package_app.sh", "--release"] in step.commands,
        "package",
    )
    default_index, default = unique_step(
        lambda step: any(command[:2] == ["swift", "test"] and "--skip" in command
                         for command in step.commands),
        "default test",
    )
    expected_default = ["swift", "test"]
    for test in (RENDER, SCALING, EXPORT):
        expected_default.extend(["--skip", test])
    if default.commands != [expected_default]:
        raise AssertionError("Default exclusions must exactly match the isolated gates")

    gates = [(default_index, default)]
    isolated = {}
    for test in (RENDER, SCALING, EXPORT):
        isolated[test] = unique_step(
            lambda step: ["swift", "test", "--filter", test] in step.commands,
            f"isolated {test}",
        )
        gates.append(isolated[test])
    if isolated[RENDER][0] != isolated[EXPORT][0]:
        raise AssertionError("Both heartbeat commands belong to the same mandatory step")
    if isolated[RENDER][1].commands != [
        ["set", "-euo", "pipefail"],
        ["swift", "test", "--filter", RENDER],
        ["swift", "test", "--filter", EXPORT],
    ]:
        raise AssertionError("Heartbeats must run sequentially with failure propagation")
    if isolated[SCALING][1].commands != [["swift", "test", "--filter", SCALING]]:
        raise AssertionError("Scaling gate must run its exact isolated filter")
    for index, step in gates:
        if index >= package_index:
            raise AssertionError("Every test gate must precede packaging")
        if step.keys != {"name", "run"}:
            raise AssertionError("Test gates must be unconditional literal run steps")


class TestLaneTests(unittest.TestCase):
    def setUp(self):
        self.workflow = WORKFLOW.read_text()
        self.heartbeat = next(step for step in read_steps(self.workflow)
                              if ["swift", "test", "--filter", EXPORT] in step.commands)

    def reject(self, workflow):
        with self.assertRaises(AssertionError):
            validate_lanes(workflow)

    def test_real_workflow_preserves_all_mandatory_test_lanes(self):
        validate_lanes(self.workflow)

    def test_exclusion_without_executable_isolated_filter_is_rejected(self):
        command = f"          swift test --filter '{EXPORT}'\n"
        # Its name remains in the default skip and even this comment; neither
        # occurrence can substitute for a command in the actual run block.
        self.reject(self.workflow.replace(command, f"          # {command.strip()}\n", 1))

    def test_unpaired_default_exclusion_is_rejected(self):
        self.reject(self.workflow.replace(f" --skip '{EXPORT}'", "", 1))

    def test_gate_failure_or_condition_bypasses_are_rejected(self):
        for field in ("continue-on-error: true", "if: false", "if : false"):
            with self.subTest(field=field):
                changed = self.heartbeat.raw.replace("        run: |", f"        {field}\n        run: |", 1)
                self.reject(self.workflow.replace(self.heartbeat.raw, changed, 1))
        self.reject(self.workflow.replace("  build-test-package:\n", "  build-test-package:\n    if: false\n", 1))

    def test_heartbeat_after_packaging_is_rejected(self):
        package = next(step for step in read_steps(self.workflow)
                       if ["bash", "Scripts/package_app.sh", "--release"] in step.commands)
        changed = self.workflow.replace(self.heartbeat.raw, "", 1)
        self.reject(changed.replace(package.raw, package.raw + self.heartbeat.raw, 1))

    def test_heartbeat_shell_cannot_swallow_a_failed_command(self):
        for old, new in (
            ("          set -euo pipefail\n", ""),
            (f"--filter '{EXPORT}'", f"--filter '{EXPORT}' || true"),
        ):
            with self.subTest(new=new):
                changed = self.heartbeat.raw.replace(old, new, 1)
                self.reject(self.workflow.replace(self.heartbeat.raw, changed, 1))


if __name__ == "__main__":
    unittest.main()
