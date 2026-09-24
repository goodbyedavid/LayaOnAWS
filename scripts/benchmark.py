#!/usr/bin/env python3
"""Latency benchmark for a Laya System One endpoint.

This mirrors the questions-per-call sweep that the upstream Laya repository
publishes, so that results here are directly comparable with the numbers in its
BENCHMARKS.md rather than being a differently shaped measurement.

Design notes that matter when reading the output:

* Raw per-request durations are retained in the result so that mean, standard
  deviation, and percentiles can be recomputed later. An earlier version of this
  harness reported only four aggregates and the samples were unrecoverable.
* ``p95`` uses linear interpolation between ranks. At twenty samples a
  nearest-rank p95 degenerates into "the second largest observation", which
  reads like a tail estimate without being one. The sample count is reported
  alongside every percentile so the reader can judge it.
* Each question in a multi-question request is distinct. Sending the same
  question fifty times would let any per-question memoisation flatter the
  batched numbers.
* A single unauthenticated request is issued first to confirm the endpoint
  rejects it, which is otherwise easy to leave untested.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import time
import urllib.error
import urllib.request

# Distinct ticket bodies so repeated sampling is not measuring one cached input.
TICKETS: list[dict[str, str]] = [
    {
        "from": "user@example.com",
        "subject": "Duplicate charge",
        "body": "We were billed twice for March. Please refund the duplicate charge.",
    },
    {
        "from": "ops@example.net",
        "subject": "API returning 503",
        "body": "Your API has returned 503 for the last twenty minutes across all regions.",
    },
    {
        "from": "buyer@example.org",
        "subject": "Enterprise pricing",
        "body": "We are evaluating your product for 400 seats and need volume pricing.",
    },
    {
        "from": "hr@example.com",
        "subject": "Update billing address",
        "body": "Please update the billing address on our account to the new office.",
    },
]

# Non-Latin text so the multilingual checkpoint is exercised on its own terms.
MULTILINGUAL_TICKET: dict[str, str] = {
    "from": "cliente@example.es",
    "subject": "Cobro duplicado",
    "body": "Nos cobraron dos veces en marzo. Solicitamos el reembolso del cargo duplicado.",
}

QUESTION_TEMPLATES: list[tuple[str, dict[str, object]]] = [
    (
        "department",
        {
            "type": "choice",
            "instructions": "Which department should handle this request?",
            "criteria": {
                "billing": "Invoices, payments, duplicate charges, and refunds",
                "technical": "Bugs, outages, and system errors",
                "sales": "Pricing, proposals, and new contracts",
                "other": "Everything else",
            },
        },
    ),
    (
        "urgency",
        {
            "type": "choice",
            "instructions": "How urgent is this request?",
            "criteria": {
                "low": "Can wait several days",
                "normal": "Should be handled this week",
                "high": "Needs attention today",
                "critical": "Active outage or revenue impact",
            },
        },
    ),
    (
        "needs_human",
        {
            "type": "noul",
            "instructions": "Does this request require a human agent rather than automation?",
            "criteria": {"true": "A human must review", "false": "Automation can resolve"},
        },
    ),
    (
        "sentiment",
        {
            "type": "score",
            "instructions": "Rate the customer's frustration level.",
            "criteria": ["calm", "mildly annoyed", "frustrated", "angry"],
        },
    ),
]


def build_payload(model: str | None, question_count: int, index: int) -> bytes:
    """Build a request body with ``question_count`` distinct questions."""
    ticket = (
        MULTILINGUAL_TICKET
        if model == "multilingual"
        else TICKETS[index % len(TICKETS)]
    )

    questions: dict[str, object] = {}
    for position in range(question_count):
        name, template = QUESTION_TEMPLATES[position % len(QUESTION_TEMPLATES)]
        # Suffix keeps keys unique once the templates wrap around.
        key = name if position < len(QUESTION_TEMPLATES) else f"{name}_{position}"
        questions[key] = template

    body: dict[str, object] = {"state": ticket, "questions": questions}
    if model:
        body["model"] = model
    return json.dumps(body).encode()


def post(url: str, payload: bytes, api_key: str | None, timeout: float) -> tuple[int, bytes]:
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(url, data=payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def summarize(durations_ms: list[float], question_count: int) -> dict[str, object]:
    ordered = sorted(durations_ms)
    count = len(ordered)

    def interpolated(quantile: float) -> float:
        if count == 1:
            return ordered[0]
        position = quantile * (count - 1)
        lower = int(position)
        upper = min(lower + 1, count - 1)
        weight = position - lower
        return ordered[lower] * (1 - weight) + ordered[upper] * weight

    mean = statistics.fmean(ordered)
    return {
        "samples": count,
        "min_ms": round(ordered[0], 2),
        "mean_ms": round(mean, 2),
        "stdev_ms": round(statistics.stdev(ordered), 2) if count > 1 else 0.0,
        "p50_ms": round(interpolated(0.50), 2),
        "p95_ms": round(interpolated(0.95), 2),
        "max_ms": round(ordered[-1], 2),
        "ms_per_question": round(mean / question_count, 2),
        "questions_per_second": round(question_count / (mean / 1000.0), 1),
        "percentile_method": "linear interpolation between ranks",
        "raw_samples_ms": [round(value, 3) for value in durations_ms],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8000")
    parser.add_argument(
        "--models",
        default="english,multilingual",
        help="Comma list passed through as the request 'model' field",
    )
    parser.add_argument(
        "--question-counts",
        default="1,5,10,50",
        help="Comma list of questions per call, matching the upstream sweep",
    )
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=180.0)
    parser.add_argument("--api-key-env", default="LAYA_BENCHMARK_API_KEY")
    args = parser.parse_args()

    api_key = os.environ.get(args.api_key_env)
    decide_url = f"{args.url.rstrip('/')}/v1/systemone"
    health_url = f"{args.url.rstrip('/')}/health"

    result: dict[str, object] = {}

    with urllib.request.urlopen(health_url, timeout=30) as response:
        result["health"] = {
            "status": response.status,
            "body": json.loads(response.read()),
        }

    # Confirm the endpoint rejects an unauthenticated decision request. This is
    # a correctness check, not a latency sample, so it is excluded from timings.
    if api_key:
        status, _ = post(decide_url, build_payload(None, 1, 0), None, args.timeout)
        result["unauthenticated_status"] = status
        result["unauthenticated_rejected"] = status in (401, 403)

    models = [entry.strip() for entry in args.models.split(",") if entry.strip()]
    counts = [int(entry) for entry in args.question_counts.split(",") if entry.strip()]

    sweep: dict[str, dict[str, object]] = {}
    sample_response: dict[str, object] = {}

    for model in models:
        for question_count in counts:
            durations_ms: list[float] = []
            last_body: bytes | None = None

            for iteration in range(args.warmup + args.samples):
                payload = build_payload(model, question_count, iteration)
                started = time.perf_counter()
                status, body = post(decide_url, payload, api_key, args.timeout)
                elapsed_ms = (time.perf_counter() - started) * 1000
                if status != 200:
                    raise SystemExit(
                        f"model={model} questions={question_count} "
                        f"returned HTTP {status}: {body[:400]!r}"
                    )
                if iteration >= args.warmup:
                    durations_ms.append(elapsed_ms)
                last_body = body

            key = f"{model}/{question_count}"
            sweep[key] = summarize(durations_ms, question_count)
            if question_count == counts[0] and last_body is not None:
                sample_response[model] = json.loads(last_body)

    result["sweep"] = sweep
    result["sample_response"] = sample_response

    revisions: list[str] = []
    for root, directories, _ in os.walk("/opt/laya-cache"):
        if os.path.basename(root) == "snapshots":
            revisions.extend(sorted(directories))
            directories[:] = []
    result["snapshot_revisions"] = sorted(set(revisions))

    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
