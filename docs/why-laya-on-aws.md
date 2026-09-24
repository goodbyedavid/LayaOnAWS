# Replacing Jev with Laya on AWS

Jev is a hosted API for fast typed decisions: give it a state and a set of
questions with fixed options, and it returns a structured answer with a
probability per option instead of prose. It is a good fit for the work that fills
production systems, like routing a ticket to a team, judging whether a refund is
urgent, or deciding which of four steps an agent takes next.

Two things stop teams from using it.

Access is gated. Jev is a closed model behind an API, currently with a waiting
list, so adoption is not a decision your team gets to make on its own schedule.

Data leaves your domain. Every decision is made over content you send to a third
party, and that content is usually support tickets, user messages, or internal
workflow state. For a regulated customer this alone ends the conversation.

Laya is an open-source implementation of the same thing, Apache-2.0, that speaks
the same wire protocol. This repository runs it on AWS in your own account for
about 53 cents an hour while it is up, and nothing while it is not.

## The same API

Laya serves `POST /v1/systemone` with the same request and response shape as the
hosted API. This repository preserves that path end to end, so an existing client
moves by changing one value:

```diff
- baseUrl: "https://api.typesafe.example/v1"
+ baseUrl: "https://abc123.execute-api.us-west-2.amazonaws.com"
```

The `Authorization: Bearer` header works the same way, against a token generated
in AWS Secrets Manager instead of issued to you. Nothing else in your client
changes: not the request body, not the response parsing, not the auth scheme.

That is the whole migration, and it is why the architecture here uses a
pass-through front door rather than anything that rewrites the request path.

## Is it actually an equal swap

On quality, mostly yes. These are upstream's measurements, not ours, and Jev's
column is third-party published rather than measured by anyone in this chain.

| Dataset | Laya | Jev |
| --- | --- | --- |
| AG News, 4 labels | 0.950 | 0.910 |
| DAIR Emotion, 6 labels | 0.595 | 0.480 |
| typed-decisions | 0.766 | 0.727 |
| banking77, 77 labels | 0.425 | 0.870 |

Three of those favour Laya. The fourth is the boundary of the claim, and it is
worth stating plainly rather than burying: **Laya is not a replacement for
many-label classification.** Options in a question share a fixed token budget, so
once you have dozens of labels each one gets too few tokens to stay distinct.
Upstream's own guidance is to keep choice questions under about twenty options.
Under that ceiling this is a swap. Above it, it is not, and no amount of
infrastructure changes that.

Two smaller cautions. The typed-decisions 0.766 comes from a checkpoint
fine-tuned on that benchmark's own training split, so treat it as generous.
And test non-English traffic yourself before trusting it, because upstream
reports cases where accuracy collapses while confidence stays high.

On speed, Laya is faster, though not by the margin a naive comparison suggests.
Jev is independently reported at a p50 of 236 to 276 ms. A single question
against this deployment answers in 64 ms measured at the endpoint, including TLS
and both AWS hops, or 33 ms measured at the container. Batched, it reaches 351
questions per second on one GPU.

Those are our numbers under our conditions and not a reproduction of anyone's
benchmark. Full method and caveats are in
[verification-notes.md](verification-notes.md).

## What it costs

One `g4dn.xlarge` with an NVIDIA T4 runs Laya with room to spare, at $0.526 per
hour in us-west-2. Both model checkpoints occupy 4.1 GiB of the card's 15.4 GiB.

The interesting number is not the hourly rate, it is where self-hosting crosses
under per-request pricing for your volume. A dedicated GPU is poor value at low
volume and becomes the cheaper option as volume grows, and where that line sits
depends entirely on your traffic.

So the stack ships at zero GPU capacity. Launching one is always explicit, and
returning to zero costs nothing but a three minute cold start next time. You can
measure your own crossover before committing to anything, including reaching the
conclusion that the hosted API is the better deal.

Adding the public HTTPS endpoint costs a further $16 to $18 a month for the load
balancer behind it, billed even while the GPU is at zero, which is why that is
opt-in too.

## Running it

```bash
npm install
npm run build
npm run deploy:gpu     # one g4dn.xlarge, private
```

That gives you a working Laya reachable through AWS Systems Manager, with no
inbound network access at all and no public endpoint. It is the right place to
start, because it costs nothing while idle and proves the path.

When you want an endpoint your application can call:

```bash
CDK_DOCKER=finch npx cdk deploy LayaVerificationStack \
  -c capacity=1 -c publicEndpoint=true --require-approval never
```

API Gateway supplies HTTPS on a generated hostname with a certificate that
already chains to a public root, so **no domain or DNS setup is required**. The
load balancer behind it is internal and nothing in the data path is reachable
from the internet. If you do own a domain you can add it later as an optional
front door.

Requests never leave your account. The model weights sit on an encrypted volume
in your VPC, inference happens on your instance in your chosen region, and the
only outbound traffic is a one-time checkpoint download on first start.

See [architecture.md](architecture.md) for the design and its limits.

## Deciding

Replace Jev with this if you are blocked on access, or if inference over your
customers' data cannot leave your account, or if per-request pricing is becoming
your dominant line item. Keep your questions under about twenty options,
validate against your own labels rather than anyone's published benchmark, and be
clear that you are taking on an independent open-source project with no vendor
support contract behind it.

If you have low volume, no data residency constraint, and Jev access already,
the hosted API is simpler and you should keep using it.
