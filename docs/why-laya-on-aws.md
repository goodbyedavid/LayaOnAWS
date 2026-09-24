# Most of your AI spend is classification wearing generation's clothes

A large share of production AI work is not writing.
It is deciding: which team owns this ticket, is this refund urgent, does this
message need a human, which of four next steps should the agent take.

These decisions are small and closed.
There is a fixed option set, a short input, and no prose to produce.
Yet the default implementation sends each one to a general-purpose language
model and parses the answer back out of generated text, which means paying
generation latency and generation prices to pick one of four labels.

This repository deploys a specialised alternative on AWS and measures it.
The numbers are good enough to be interesting and the limitations are sharp
enough that you should read them before deploying anything.

## Laya, and the category

Laya is an open-source inference server, Apache-2.0, built for exactly these
typed decisions.
It returns a structured answer with a probability per option, not text.

It speaks the same `POST /v1/systemone` wire protocol as Jev, a hosted API in
this category from TypeSafe.
Upstream's benchmarks reference Jev 1.13.0 at an independently measured p50 of
236 to 276 ms, and are explicit that Jev's numbers are "third-party published,
never measured here" because they had no API access.
Nothing here is a measured comparison against Jev either.
What Jev establishes is that the category has a defined protocol and a hosted
option, which is the right answer for plenty of customers.

The protocol match is the load-bearing fact.
A client written against the hosted API reaches your own endpoint by changing a
base URL, and nothing else.
That is why the architecture here keeps a pass-through front door instead of
anything that rewrites the request path.
Change the path or the auth scheme and you have thrown away the only cheap part
of the migration.

## What it does on one cheap GPU

Measured on a single `g4dn.xlarge` with a Tesla T4, PyTorch 2.14.0, twenty
samples per cell after warm-up, called over loopback on the host.

| Questions per call | english | multilingual |
| --- | --- | --- |
| 1 | 32.73 ms | 27.73 ms |
| 5 | 42.27 ms | 30.13 ms |
| 10 | 71.27 ms | 36.04 ms |
| 50 | 285.84 ms | 142.45 ms |

At 50 questions in one request, multilingual costs 2.85 ms per question and
sustains 351 questions per second.
Both models stay resident in 4,136 MiB of the T4's 15,360 MiB, so the cheapest
current-generation inference GPU is oversized for this.

Those batched figures run 2.0 to 2.7 times faster than upstream publishes, and
the throughput sits above the top of upstream's stated 103 to 332 range.
The likely cause is a Triton dispatch path that PyTorch 2.14 reaches and the
older pin did not, which fits the shape of the result: single-question latency
is unchanged while batched latency improves sharply.
That is a hypothesis, not an attribution, because both PyTorch versions were
never run through the same sweep.

Put the managed HTTPS front door in front and add a flat 30 ms.
Single-question english goes from 32.62 to 64.38 ms at the p50.
The penalty is fixed, so it shrinks as a proportion the moment you batch.

## Where it breaks

Upstream measures Laya at 0.425 on banking77, a 77-label intent dataset,
against a published Jev figure of 0.870.
They do not bury this.
They call it "the one clear loss, and it is architectural" and give the
mechanism: options in a choice question share a fixed token budget, so at 77
options each description gets roughly four tokens and the options stop being
distinguishable.
Two different checkpoints score identically, which looks like a budget ceiling
rather than a capability gap.

Their guidance follows: keep choice questions under about twenty options.
So if your use case is many-class intent detection, this is the wrong tool and
no amount of infrastructure will fix it.
Routing among a handful of teams is what it is good at.

The live deployment produced a matching signal.
On startup Laya warned that the checkpoint ships an out-of-range temperature for
the `choice:11+` bucket and clamped it, and upstream confirms that is the only
bucket the clamp touches.
The high-option-count path is simply the least mature part of the system.

Two more things to read before quoting any accuracy number.
The flagship 0.766 on typed-decisions, against Jev's 0.727, comes from a
checkpoint fine-tuned on that benchmark's own training split, and upstream
discloses that base checkpoints fall below the majority-class baseline there.
Upstream also discloses training-set contamination behind its spam and phishing
results.
On the same typed-decisions task, Jev leads on soft accuracy and on calibration
error, and is more stable to option ordering at twenty options.
This is a mixed picture, not a sweep.

For non-English traffic the risk is concrete: upstream reports 0.000 accuracy at
0.952 confidence on Khmer.
Confidence being high tells you nothing there.
This repository measured multilingual latency but never multilingual quality, so
treat that path as unproven until you test it on your own labels.

## Why run it yourself

A hosted API already exists, so self-hosting has to earn the work.
Usually it earns it on one of three grounds.

The first is data.
These decisions run over support tickets and user messages, which is frequently
regulated or contractually restricted.
Inference inside the customer's own VPC, in their region, with no third-party
egress, closes a review that otherwise kills the project outright.

The second is arithmetic.
Per-request pricing is excellent at low volume and becomes the dominant line
item at high volume.
A dedicated T4 is $0.526 per hour, roughly $380 a month if left running, and at
the batched throughput above the crossover arrives sooner than people expect.
The stack deploys at zero GPU capacity precisely so a customer can find their own
crossover before committing to anything.

The third is control.
The weights and the server are open source, so a component sitting on the
critical path of every inbound ticket can be pinned, audited, and kept running
regardless of what the upstream project does next.

## What the design cost to get right

Two decisions are worth stealing, and one mistake is worth not repeating.

Zero GPU capacity is the default, and launching one is always explicit.
A reference architecture that strangers clone should not quietly bill $380 a
month, and the price of that safety is a three minute cold start.

The public endpoint is opt-in and needs no domain.
An internet-facing load balancer with its own certificate was built first and
then abandoned, because no certificate authority will issue for a hostname you do
not control, which made a Route 53 hosted zone a hard prerequisite for every
person cloning the repo.
An API Gateway HTTP API removes that entirely: it serves HTTPS on a generated
hostname with a certificate that already chains to a public root, the load
balancer behind it is internal, and a custom domain becomes an optional upgrade
to the front door rather than a precondition for deploying at all.

Rate limiting is the control that matters, because Laya serialises inference
through a single worker and an unthrottled public endpoint in front of a
single-worker server is trivial to saturate.
API Gateway enforces it, since AWS WAF cannot attach to an HTTP API.

The mistake: PyTorch 2.14 dispatches through a Triton kernel that is compiled at
runtime, so the container needs a C compiler.
Without one the server starts, loads both checkpoints, answers `/health`, reports
healthy to the orchestrator, and then fails every single inference request with a
deliberately non-leaking error.
Installing `gcc` alone is not enough, because `--no-install-recommends` skips
`libc6-dev` and the failure just moves from a missing compiler to a missing
`stdlib.h`.
A health check that passes while the service is completely broken is the worst
category of failure, and having already solved it is most of what a reference
architecture is for.

That JIT also has a runtime cost: the first authenticated request after a
container start took 2.98 seconds against 0.297 warm.
The cache now lives in the mounted model volume, so it is paid once per host.

## Should you use this

Deploy it if you are making a high volume of small typed decisions, under about
twenty options each, and either data residency or per-request cost is pushing you
off a hosted API.
Measure it against your own labels, because the accuracy numbers above are
upstream's and the ones that matter are yours.

Do not deploy it for many-class intent detection, for low volume where hosted
will be cheaper and simpler, for anything needing world knowledge or multi-step
reasoning, or for non-English production traffic you have not tested.
And be clear-eyed that this is an independent open-source project with no vendor
support contract behind it.

One unresolved item, in the interest of not overselling the numbers.
Upstream publishes 39.5 ms for single-question english; this repository measures
32.62 ms on the same GPU model.
That was initially suspected to be the PyTorch version, and it is not: the same
measurement gives 32.95 ms on the older pin, which is statistically identical.
The two harnesses are measuring different things.
Every figure here is this repository's own measurement under the conditions
stated, and none of it is a reproduction of upstream's table.
