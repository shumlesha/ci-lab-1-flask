"""Run real integration tests and record wall time plus leak checks."""

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from contextlib import closing
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[1]


def checked(command: list[str]) -> str:
    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )

    if result.returncode:
        raise RuntimeError(
            f"Command failed: {command!r}\n{result.stderr}"
        )

    return result.stdout.strip()


def preflight(output: Path) -> None:
    from testcontainers.core.config import testcontainers_config

    if testcontainers_config.ryuk_disabled:
        raise RuntimeError(
            "Enable Ryuk; remove TESTCONTAINERS_RYUK_DISABLED"
        )

    info = checked([
        "docker",
        "info",
        "--format",
        "{{.OSType}}",
    ])

    if info != "linux":
        raise RuntimeError(
            "Switch Docker Desktop to Linux containers"
        )

    import docker

    with closing(docker.from_env()) as client:
        client.ping()
        sdk_id = client.info()["ID"]

    cli_id = checked([
        "docker",
        "info",
        "--format",
        "{{.ID}}",
    ])

    if cli_id != sdk_id:
        raise RuntimeError(
            "Docker SDK and CLI use different daemons; "
            "check DOCKER_HOST"
        )

    images = [
        os.environ.get("TEST_POSTGRES_IMAGE", "postgres:16"),
        os.environ.get("TEST_REDIS_IMAGE", "redis:7"),
        testcontainers_config.ryuk_image,
    ]

    evidence = []

    for image in images:
        found = subprocess.run(
            ["docker", "image", "inspect", image],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        if found.returncode:
            print(
                f"Pulling before measurements: {image}",
                flush=True,
            )
            checked(["docker", "pull", image])

        evidence.extend(
            json.loads(
                checked(["docker", "image", "inspect", image])
            )
        )

    (output / "images.json").write_text(
        json.dumps(evidence, indent=2),
        encoding="utf-8",
    )

    (output / "environment.txt").write_text(
        f"Python: {sys.version}\n"
        f"OS: {platform.platform()}\n"
        + checked(["docker", "version"])
        + "\n",
        encoding="utf-8",
    )


def junit_result(path: Path) -> dict[str, int]:
    if not path.is_file():
        raise RuntimeError("pytest did not produce a JUnit report")

    root = ET.parse(path).getroot()

    suites = (
        [root]
        if root.tag == "testsuite"
        else list(root.findall("testsuite"))
    )

    return {
        key: sum(
            int(suite.get(key, "0"))
            for suite in suites
        )
        for key in ("tests", "failures", "errors", "skipped")
    }


def run_once(
    output: Path,
    mode: str,
    workers: int,
    index: int,
) -> dict:
    run_id = uuid4().hex

    directory = output / (
        f"{index:02d}-{mode}-{run_id[:8]}"
    )

    directory.mkdir(parents=True)

    env = {
        **os.environ,
        "LAB3_TEST_RUN_ID": run_id,
        "LAB3_REPORT_DIR": str(directory),
        "PYTHONUNBUFFERED": "1",
        "PYTHONIOENCODING": "utf-8",
    }

    command = [
        sys.executable,
        "-m",
        "pytest",
        "tests/integration",
        "--no-cov",
        "--color=no",
        f"--junitxml={directory / 'junit.xml'}",
        "--durations=10",
    ]

    if mode == "parallel":
        command += [
            "-n",
            str(workers),
            "--dist=load",
        ]
    else:
        command += ["-n", "0"]

    print(
        "Running: " + " ".join(command),
        flush=True,
    )

    started = time.perf_counter()

    with (directory / "pytest.log").open(
        "w",
        encoding="utf-8",
    ) as log:
        try:
            process = subprocess.run(
                command,
                cwd=ROOT,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=900,
            )

            code = process.returncode

        except subprocess.TimeoutExpired:
            code = 124
            log.write(
                "\nIntegration run exceeded 900 seconds\n"
            )

    elapsed = time.perf_counter() - started

    print(
        (directory / "pytest.log").read_text(
            encoding="utf-8"
        ),
        flush=True,
    )

    leftovers = checked([
        "docker",
        "ps",
        "-aq",
        "--filter",
        f"label=lab3.run={run_id}",
    ]).splitlines()

    (directory / "leftovers.json").write_text(
        json.dumps(leftovers),
        encoding="utf-8",
    )

    try:
        counts = junit_result(directory / "junit.xml")
    except (RuntimeError, ET.ParseError):
        counts = {
            "tests": 0,
            "failures": 0,
            "errors": 1,
            "skipped": 0,
        }

    passed = (
        code == 0
        and not leftovers
        and counts["tests"] > 0
        and not any(
            counts[key]
            for key in ("failures", "errors", "skipped")
        )
    )

    return {
        "mode": mode,
        "workers": workers if mode == "parallel" else 0,
        "wall_seconds": round(elapsed, 6),
        "returncode": code,
        "passed": passed,
        "run_id": run_id,
        "directory": str(directory),
        "leftovers": leftovers,
        **counts,
    }


def summarize(runs: list[dict]) -> dict:
    medians = {}

    for mode in ("sequential", "parallel"):
        values = [
            run["wall_seconds"]
            for run in runs
            if run["mode"] == mode and run["passed"]
        ]

        if values:
            medians[mode] = statistics.median(values)

    result = {
        "runs": runs,
        "median_seconds": medians,
    }

    if set(medians) == {"sequential", "parallel"}:
        result["speedup"] = (
            medians["sequential"] / medians["parallel"]
        )

        result["reduction_percent"] = 100 * (
            1 - medians["parallel"] / medians["sequential"]
        )

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)

    parser.add_argument(
        "--mode",
        choices=("parallel", "sequential", "compare"),
        default="parallel",
    )

    parser.add_argument(
        "--workers",
        type=int,
        default=2,
    )

    parser.add_argument(
        "--repeat",
        type=int,
        default=1,
    )

    args = parser.parse_args()

    if not 1 <= args.workers <= 8:
        parser.error("Use 1..8 workers")

    if not 1 <= args.repeat <= 10:
        parser.error("Use 1..10 repetitions")

    output = ROOT / "reports" / "integration"
    output.mkdir(parents=True, exist_ok=True)

    runs = []

    try:
        preflight(output)

        for index in range(args.repeat):
            modes = (
                ["sequential", "parallel"]
                if args.mode == "compare"
                else [args.mode]
            )

            if index % 2:
                modes.reverse()

            for mode in modes:
                result = run_once(
                    output,
                    mode,
                    args.workers,
                    len(runs) + 1,
                )

                runs.append(result)

                if not result["passed"]:
                    raise RuntimeError(
                        "Tests failed, skipped, timed out "
                        "or leaked containers"
                    )

        if len({run["tests"] for run in runs}) != 1:
            raise RuntimeError(
                "Compared runs executed different numbers of tests"
            )

    except (RuntimeError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1

    finally:
        summary = summarize(runs)

        (output / "benchmark.json").write_text(
            json.dumps(summary, indent=2),
            encoding="utf-8",
        )

        lines = [
            "# Integration test measurements",
            "",
            "| Mode | Workers | Wall seconds | Tests | "
            "Passed | Leftovers |",
            "|---|---:|---:|---:|---|---:|",
        ]

        for run in runs:
            lines.append(
                f"| {run['mode']} | "
                f"{run['workers']} | "
                f"{run['wall_seconds']:.3f} | "
                f"{run['tests']} | "
                f"{run['passed']} | "
                f"{len(run['leftovers'])} |"
            )

        if "speedup" in summary:
            lines += [
                "",
                f"Median speedup: {summary['speedup']:.3f}x",
                "Wall-time reduction: "
                f"{summary['reduction_percent']:.2f}%",
            ]

        lines += [
            "",
            "Speedup below 1 means a measured slowdown, "
            "not a test failure.",
        ]

        (output / "benchmark.md").write_text(
            "\n".join(lines) + "\n",
            encoding="utf-8",
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
