# Fast structured decisions on AWS: deploying Laya behind your own endpoint

This is the reasoning behind the reference architecture in this repository.
It explains the problem the architecture addresses, why Laya is an interesting
candidate, where Laya is genuinely weak, and what running it on AWS changes for
an account team and for a customer.

Every performance number here is either measured in this repository and labelled
with its conditions, or quoted from upstream and labelled as upstream's.
Where the two disagree, the disagreement is stated rather than smoothed over.

## The problem: not every decision needs a large language model

A surprising share of production "AI" work is not generation.
It is classification and routing.

Which team owns this ticket.
Is this refund request urgent.
Does this message need a human.
Which of these four next steps should the agent take.

These are small, closed-form decisions with a fixed set of options, and they
happen constantly.
A customer support pipeline might make several of them per inbound message.
An agentic workflow might make one per step, hundreds of times per task.

The default implementation is to send each decision to a general-purpose large
language model and parse the answer out of generated text.
That works, and it is the right answer when the decision genuinely needs broad
reasoning or world knowledge.
But for a four-way routing choice, it has three costs that compound at volume:

1. **Latency.** Generation-based decisions typically land in the hundreds of
   milliseconds. When a workflow chains ten of them, that becomes seconds of
   wall-clock time that the user feels.
2. **Cost per decision.** Token-billed inference is priced for generation. Paying
   generation rates to pick one of four labels is poor value at high volume.
3. **Output uncertainty.** A model that emits text can emit text you did not
   expect, so you end up writing parsers, retries, and validation for a decision
   that should have been a constrained choice all along.

The category name for addressing this is "System One" inference, borrowing
Kahneman's fast-versus-slow framing.
The idea is a small, specialised model that returns a *structured* decision with
calibrated probabilities, fast, and leaves the slow general reasoning to a larger
model that you call far less often.

## What Jev is, and what I can honestly say about it

Jev is a hosted API in this category, offered by TypeSafe.
It accepts a state and a set of typed questions at `POST /v1/systemone` and
returns structured answers rather than free text.
The upstream Laya benchmarks reference `Jev 1.13.0` and cite an independently
measured p50 latency of 236 to 276 ms.

I want to be precise about the limits of my knowledge here, because this is the
part of the story where it is easiest to be unfair to a competitor.
I have not used Jev.
I have no API access to it, and neither did the Laya maintainers when they wrote
their comparison, which they disclose plainly: Jev figures are
"third-party published, never measured here", and "sample sizes and prompts
differ; treat them as indicative."

So nothing in this document is a measured Laya-versus-Jev comparison.
What Jev establishes for our purposes is simply that the category exists, that
there is a defined wire protocol for it, and that a hosted option is available
for teams who would rather not run infrastructure.

That last point matters. For many customers, a hosted API is the correct choice,
and this architecture is not an argument that it is not.

## Why Laya is worth the effort

Laya is an open-source implementation, Apache-2.0 licensed, that speaks the same
`POST /v1/systemone` wire protocol.
Three properties make it interesting for an AWS deployment.

**It is a drop-in protocol match.**
Because the path and request shape are the same, a client already written against
the hosted API can be repointed at your own endpoint by changing a base URL.
That is an unusually low migration cost, and it is the single most important
architectural fact in this repository.
It is also why the reference architecture puts a pass-through front door in front
of Laya rather than something that would rewrite the request path: the moment you
change the path or the auth scheme, you have thrown away the main advantage.
The live run confirmed this holds in practice, with `/v1/systemone` and the
`Authorization` header both arriving at the container unchanged.

**It is small enough to run on a cheap GPU.**
The whole thing fits comfortably on one NVIDIA T4, which is the least expensive
GPU in the g4dn family.
In this repository's live tests the model used 3,898 MiB of the T4's 15,360 MiB
after single-question inference, rising to 4,136 MiB after a sweep that included
50-question requests, so there is substantial headroom either way.
That is a very different infrastructure conversation from hosting a large
generative model.

**It returns calibrated probabilities, not prose.**
The response includes a probability per option and a confidence value, which is
what you actually want if you intend to route automatically above a threshold
and escalate to a human below it.
Upstream reports that temperature fitting moves expected calibration error from
0.466 to 0.081 on the English checkpoint, which is the difference between
confidence values you can threshold on and confidence values you cannot.

## Where Laya is weak, stated plainly

A reference architecture that only lists strengths is marketing, and it will
embarrass whoever deploys it. Three limitations are load-bearing.

**High-cardinality classification is a real loss, and it is structural.**
On banking77, a 77-label intent dataset, upstream measures Laya at 0.425 against
a published Jev figure of 0.870.
Upstream does not hide this. It calls banking77 "the one clear loss, and it is
architectural", and gives the mechanism: the options in a choice question share a
fixed token budget, so at 77 options each option description gets roughly four
tokens and the options stop being distinguishable.
The identical score across two different checkpoints supports that reading, since
it looks like a budget ceiling rather than a model capability gap.

Upstream's own guidance follows directly: keep choice questions under about
twenty options.
**If your use case is many-class intent detection over dozens of labels, this
architecture is the wrong tool and you should not deploy it for that.**
It is well suited to routing among a handful of teams, not to picking one of
seventy-seven intents.

This also connects to something observed in this repository's live run.
On startup, Laya emitted a warning that the checkpoint ships a temperature
outside the valid range for the `choice:11+` bucket, meaning choice questions
with eleven or more options, and clamped it.
Upstream confirms that `choice:11+` is the only bucket that clamp affects.
Both facts point the same direction: the high-option-count path is the least
mature part of the system.

**The flagship accuracy number carries a significant caveat.**
The headline 0.766 on typed-decisions, against a published Jev 0.727, comes from
a checkpoint fine-tuned on that benchmark's own training split.
Upstream discloses that the base checkpoints score below the majority-class
baseline on it.
Upstream also discloses training-set contamination for its spam and phishing
results, and reports weaker held-out numbers.
Read the benchmark page before repeating any single figure from it.
None of this is hidden, but none of it survives being compressed into a slide
either.

**Jev leads on some quality dimensions.**
On typed-decisions, the published Jev figures are better on soft accuracy and on
expected calibration error, and upstream reports Jev is more stable to option
ordering at twenty options.
Laya leads on top-line accuracy and score error on the same task.
The honest summary is that this is a mixed picture, not a sweep.

## Why deploy it on AWS

Given that a hosted option exists, self-hosting has to earn its place. Four
reasons it often does.

**Data residency and isolation.**
The decisions in scope are made over customer support tickets, user messages, and
internal workflow state.
That is frequently regulated or contractually restricted data.
Running inference inside the customer's own VPC, in a region they chose, with no
third-party egress, resolves a class of review that otherwise blocks the project
entirely.
For many regulated customers this is the whole reason the conversation happens.

**Predictable cost at volume.**
Per-request pricing is excellent at low volume and becomes the dominant cost at
high volume.
A dedicated T4 is $0.526 per hour on demand in us-west-2, which is roughly $380
per month if left running.
At the throughput upstream reports for batched requests, the crossover point
against per-request pricing arrives earlier than people expect.
The architecture in this repository defaults to zero GPU capacity precisely so
the customer can measure that crossover for their own volume before committing.

**Latency control.**
The measured warm latency in this repository is about 33 ms for a single question
from inside the instance.
Even after adding real network transit and a load balancer hop, keeping
inference inside the customer's own region and VPC removes a public internet
round trip that a hosted API cannot avoid.
For a workflow that chains ten decisions, that difference is structural rather
than incremental.

**No vendor dependency on the decision path.**
The model weights and the server are open source.
A customer can pin a version, audit the code, and keep running if the upstream
project changes direction.
For a component sitting on the critical path of every support ticket, that
matters to architecture review boards.

## Why this specific architecture

The design choices in this repository follow from the constraints above.

**Amazon ECS on EC2 GPU rather than a managed inference endpoint.**
A managed endpoint would bring autoscaling and a managed HTTPS front door, which
is genuinely attractive.
It was rejected because its invocation contract uses a different request path,
which would break the drop-in protocol compatibility that is Laya's main
advantage.
Preserving `POST /v1/systemone` end to end was judged worth the extra plumbing,
and the live run confirmed the path and the `Authorization` header both survive
the managed front door unchanged.

**An API Gateway HTTP API in front of an internal load balancer.**
This is the part of the design that changed most during the work.
An internet-facing load balancer with an ACM certificate was built first and then
abandoned, because a certificate authority will not issue a trusted certificate
for a hostname you do not control, which made a Route 53 hosted zone a hard
prerequisite for anyone cloning the repository.
API Gateway removes that prerequisite entirely: it serves HTTPS on a generated
`*.execute-api` hostname with a certificate that already chains to a public root.
The load balancer behind it is internal, so nothing in the data path is reachable
from the internet, and a custom domain becomes a purely optional upgrade to the
front door rather than a precondition for deploying at all.
The measured cost of those hops is a roughly fixed 30 ms.

**Zero GPU capacity by default.**
The stack synthesises with zero GPU instances and requires an explicit flag to
launch one.
This is a reference solution that strangers will clone, and a default that
quietly bills $380 a month is a bad default regardless of how clearly it is
documented.
The cost of this choice is a cold start of roughly three minutes.

**An opt-in public endpoint.**
The load balancer, certificate, DNS record, and web application firewall are only
created when the public endpoint is requested.
Without it the stack is reachable only through AWS Systems Manager, and it costs
essentially nothing while idle.
This split exists because a load balancer bills around $16 to $18 per month even
with the GPU scaled to zero, which would otherwise quietly become the dominant
idle cost of a "scale to zero" design.

**A Route 53 hosted zone is required for the public endpoint.**
There is no domain-free HTTPS option, and that is deliberate.
A certificate authority will not issue a trusted certificate for a hostname you
do not control, and the alternatives all end with a bearer token crossing the
public internet in plaintext.
Customers without a domain should use the Systems Manager tunnel path instead,
which is fully supported here.

**Rate limiting is the security control that matters most.**
Laya serialises HTTP inference through a single worker.
An unthrottled public endpoint in front of a single-worker server is trivial to
saturate, so a request rate limit is doing more real work here than any managed
rule set would.
This is enforced by API Gateway rather than AWS WAF, because WAF cannot be
associated with an HTTP API.

## What this gives an AWS account team

**A concrete, deployable artifact for a common customer problem.**
"Route support tickets faster and cheaper" is a conversation most account teams
are already having.
This turns it into something that runs in the customer's account in an afternoon
and produces numbers from their own data.

**A cost conversation grounded in measurement.**
The interesting question is not whether GPU inference is cheaper than a hosted
API in the abstract.
It is where the crossover sits for this customer's volume.
A stack that deploys at zero capacity, scales to one for a test, and tears itself
back down is a tool for answering that question honestly, including when the
answer is "keep using the hosted API."

**A credible technical position, including the caveats.**
Being the person who says "this is a poor fit for your seventy-label intent
model, here is the architectural reason, here is what it is good at instead" is
worth considerably more than presenting an unqualified win.
The banking77 result is in this document for exactly that reason.

**A pattern that generalises.**
Very little here is Laya-specific.
A GPU task on ECS, an opt-in HTTPS front door, secrets in AWS Secrets Manager,
scale to zero by default, and administrative access through Systems Manager is a
reusable shape for hosting any small open-source model in a customer account.

## What this gives the customer

A private inference endpoint in their own VPC and region, with no third-party
egress on the decision path.
An endpoint their existing client can reach by changing one base URL.
A cost model they can predict, and which they can evaluate before committing to,
because the default configuration costs nothing while idle.
The ability to pin, audit, and keep running a component on their critical path.
And a documented set of limitations, so the evaluation can fail fast if their use
case is one of the ones this does not suit.

## What was measured here, and what was not

Measured on one `g4dn.xlarge` with a Tesla T4, PyTorch 2.14.0+cu126, twenty
samples per cell after warm-up, on the host over loopback:

| Model | 1 question | 5 | 10 | 50 | Best ms/question | Peak questions/sec |
| --- | --- | --- | --- | --- | --- | --- |
| english | 32.73 ms | 42.27 ms | 71.27 ms | 285.84 ms | 5.72 | 174.9 |
| multilingual | 27.73 ms | 30.13 ms | 36.04 ms | 142.45 ms | 2.85 | 351.0 |

Also measured: the stack deploys and the task registers the GPU and reports
healthy; both checkpoints load and stay resident; a single-question English
request returns a correct, well-formed, Jev-shaped response; unauthenticated and
wrong-token requests are rejected with HTTP 401; the public endpoint works end to
end over HTTPS with no domain; cold start from task start to a serving process is
16 seconds, dominated by the image pull rather than checkpoint download; and
scaling to zero removes the instance and its volume, after which the endpoint
correctly returns HTTP 503.

The batched figures are the interesting result. They run 2.0 to 2.7 times faster
than upstream publishes at 10 and 50 questions per call, and peak throughput of
351 questions per second sits above the top of upstream's stated 103 to 332
range. The most likely cause is the Triton dispatch path that torch 2.14 enables,
which is consistent with single-question latency being unchanged while batched
latency improves sharply. That attribution is a hypothesis, not a measurement,
because both torch versions were not run through the same sweep.

One earlier open question is now closed. A 17 percent gap against upstream's
published 39.5 ms single-question English figure was initially suspected to come
from the PyTorch version. It does not: the same measurement is 32.62 ms on torch
2.14 and 32.95 ms on torch 2.11, which are statistically indistinguishable. The
gap is a difference in measurement methodology between the two harnesses. Treat
these as this repository's own numbers under stated conditions, not as a
reproduction of upstream's table.

There is a real operational cost worth knowing. On a GPU, Laya dispatches through
a Triton kernel that is JIT-compiled on first use, so the first authenticated
request after a container start took 2.98 seconds against 0.297 seconds warm.
That also means the container needs a C compiler present, without which the
server starts, loads both checkpoints, answers `/health`, and then fails every
single inference request. That is a genuinely misleading failure mode, and it is
the kind of thing a reference architecture exists to have already solved.

Not measured, and therefore not claimed:

No accuracy claim at all. Everything in the weakness section above is upstream's
measurement, not a reproduction here.
Multilingual *quality*, as distinct from multilingual latency, which was measured.
Any concurrent load. Every measurement is sequential, and Laya serialises
inference through one worker, so none of this describes behaviour under parallel
clients.
The optional custom domain path, which is template-asserted but never deployed.
Cold start remains a single observation.

## When not to use this

Choice questions with more than about twenty options.
Low request volume, where a hosted API will be cheaper and simpler.
Any decision that needs broad world knowledge or multi-step reasoning, which is
what the larger model you call less often is for.
Cases where you need a vendor support contract on the inference component, since
this is an independent open-source project maintained outside AWS.
Non-English production traffic, until you have measured it yourself, given the
severity of the multilingual failure cases upstream documents.

## Next steps for a reader

Deploy the private stack first and reach it through Systems Manager, because it
costs nothing while idle and proves the path.
Run the benchmark against your own questions and your own labels, since the
numbers that matter are the ones from your data.
Decide the hosted-versus-self-hosted question with your measured volume in hand.
Then, if it makes sense, enable the public endpoint.
