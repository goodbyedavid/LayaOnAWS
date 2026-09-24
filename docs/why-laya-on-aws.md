# Replacing Jev with Laya on AWS

## The decisions that fill production systems

Route this ticket to a team. Decide whether this refund is urgent. Judge whether
this message needs a human. Pick which of four steps an agent takes next.

These are small closed decisions: a short input, a fixed set of options, no prose
to produce. They are also everywhere, and they run constantly. A support pipeline
makes several per inbound message, and an agentic workflow makes one per step.

The usual implementation sends each one to a general-purpose language model and
parses the answer back out of generated text. That works, and it is right when a
decision genuinely needs world knowledge or multi-step reasoning. For a four-way
routing choice it is the wrong instrument three times over. You pay generation
latency, you pay generation prices, and you get free-form text where you wanted a
constrained choice, so you end up writing parsers and retries for something that
should never have been open-ended.

A "System One" model does this job directly, borrowing Kahneman's fast-and-slow
framing. It returns a typed decision with a probability per option, in tens of
milliseconds, and leaves the slow reasoning to the larger model you now call far
less often.

## Jev proved the category, and cannot always be used

Jev, from TypeSafe AI, is the model that established this category. It takes a
state and a set of typed questions at `POST /v1/systemone` and returns structured
answers. Two things keep teams from adopting it.

**It is closed and gated.** Jev is proprietary, and TypeSafe has not published
its weights, architecture, or a technical paper. It launched in limited early
access in September 2026, and TypeSafe's own announcement describes "bringing
developers off the waitlist as quickly as we can." Whether your team can start
this quarter is not your decision to make.

**Your data goes to them.** Every decision is made over content you transmit to a
third party, and that content is typically support tickets, user messages, or
internal workflow state. There is no documented self-hosted, VPC, or on-premises
option. TypeSafe's launch post also notes that this is "where our service is
currently based," referring to the US West Coast, which is a concrete residency
problem for a customer who cannot move that data across a border.

For plenty of teams neither of these matters, and Jev is the simpler choice.
This document is for the teams where one of them is decisive.

## Laya is the same interface, open

Laya is an open-source System One model and server, Apache-2.0 licensed, speaking
the same wire protocol. That last part carries the whole argument: the request
shape, the response shape, the `Authorization: Bearer` header, and the
`/v1/systemone` path are all identical. A client already written against the
hosted API moves by changing one value.

```diff
- baseUrl: "https://api.typesafe.ai/v1"
+ baseUrl: "https://abc123.execute-api.us-west-2.amazonaws.com"
```

On quality it is competitive. These are upstream Laya's published measurements,
and Jev's column there is third-party published rather than measured by anyone in
this chain.

| Dataset | Laya | Jev |
| --- | --- | --- |
| AG News, 4 labels | 0.950 | 0.910 |
| DAIR Emotion, 6 labels | 0.595 | 0.480 |
| typed-decisions | 0.766 | 0.727 |
| banking77, 77 labels | 0.425 | 0.870 |

Three of four favour Laya. The fourth is the boundary of the claim and deserves
stating plainly: **Laya does not replace Jev for many-label classification.**
Options in a question share a fixed token budget, so once there are dozens of
labels each gets too few tokens to stay distinct. Upstream's guidance is to keep
choice questions under about twenty options. Below that ceiling this is a
substitution. Above it, it is not, and no infrastructure choice changes that.

Treat the typed-decisions 0.766 as generous, since it comes from a checkpoint
fine-tuned on that benchmark's own training split. And validate non-English
traffic yourself, because upstream documents cases where accuracy collapses while
reported confidence stays high.

## What running it on AWS actually buys

**The data never leaves your account.** Weights sit on an encrypted volume in
your VPC, inference happens on your instance in the region you picked, and the
only outbound traffic is a one-time checkpoint download on first start. The
architecture ships with no inbound network access by default. This is the reason
most teams will do this, and it is the one Jev cannot answer.

**You start when you decide to.** No waitlist, no early-access list, no vendor
timeline. The stack deploys from this repository into an account you already have.

**Latency improves, modestly.** TypeSafe reports 70 to 500 ms end-to-end for Jev.
This deployment answers a single question in 64 ms at the public endpoint,
including TLS and both AWS hops, or 33 ms at the container, and one GPU reaches
351 questions per second batched. That beats the good end of Jev's range rather
than beating Jev categorically, and removing a public internet round trip is part
of why. Both checkpoints fit in 4.1 GiB of the T4's 15.4 GiB, so there is room to
grow into.

**Cost is a genuine calculation, not a slam dunk.** Jev charges $0.042 per
million input tokens with output tokens free, which is aggressive pricing and
well matched to classification, where output is empty. At that rate a 94-token
decision costs about $0.0000039. One `g4dn.xlarge` at $0.526 per hour therefore
breaks even at roughly **37 decisions per second sustained**, and this
deployment measured 30.6 per second at one question per call. Read that honestly:
at one question per request, a single T4 roughly ties or slightly loses to Jev on
price. Batching multiple questions into one request is what moves the economics,
because throughput rises several times over while the token count per decision
falls.

So the cost case depends on your traffic shape and your utilization, which is why
the stack ships at zero GPU capacity: measure your own crossover before
committing, including reaching the conclusion that the hosted API is cheaper for
you. Idle costs nothing, and coming back up costs a three minute cold start.

In fairness to TypeSafe, and against their own numbers: their speed and cost
comparisons are self-tested, and they write "We can't prove it isn't subsidized"
while expecting prices to fall. Either could move this calculation.

## Deciding

Deploy this if you are blocked on Jev access, or if inference over your
customers' data cannot leave your account or your region, or if you have the
volume and the batching pattern to make a dedicated GPU cheaper. Keep questions
under about twenty options, and validate against your own labels rather than
anyone's published benchmark.

Do not deploy it if you have low volume and no residency constraint, since the
hosted API will be cheaper and simpler. Do not deploy it for many-label
classification. And go in knowing this is an independent open-source project with
no vendor support contract behind it.

To deploy, see the [README](../README.md). For the design and its limits, see
[architecture.md](architecture.md). For measurement method and full results, see
[verification-notes.md](verification-notes.md).
