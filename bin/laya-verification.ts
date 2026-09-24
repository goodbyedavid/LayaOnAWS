#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { LayaVerificationStack } from "../lib/laya-verification-stack.js";

const app = new cdk.App();

const rawCapacity = app.node.tryGetContext("capacity") ?? "0";
const capacity = Number(rawCapacity);

if (!Number.isInteger(capacity) || capacity < 0 || capacity > 1) {
  throw new Error("CDK context capacity must be 0 or 1");
}

// The public HTTPS endpoint is opt-in. Without it the stack stays private and is
// reachable only through AWS Systems Manager, which is both the cheapest and the
// most restrictive posture. Enabling it adds an API Gateway HTTP API and an
// internal load balancer; the load balancer bills roughly 16 to 18 USD per month
// even while GPU capacity is zero.
const publicEndpoint = app.node.tryGetContext("publicEndpoint") === "true";

// Off by default. The host-side benchmark scripts need it; production does not.
const hostBenchmarkAccess =
  app.node.tryGetContext("hostBenchmarkAccess") === "true";

// A custom domain is entirely optional. API Gateway serves the endpoint on a
// generated `*.execute-api` hostname with a trusted certificate, so no domain or
// hosted zone is required to get working HTTPS.
const domainName = app.node.tryGetContext("domainName");
const hostedZoneId = app.node.tryGetContext("hostedZoneId");
const hostedZoneName = app.node.tryGetContext("hostedZoneName");

if (domainName && !(hostedZoneId && hostedZoneName)) {
  throw new Error(
    "domainName also requires hostedZoneId and hostedZoneName, because the " +
      "certificate is validated through DNS. Omit all three to use the " +
      "generated execute-api hostname, which needs no domain of your own."
  );
}

if ((hostedZoneId || hostedZoneName) && !domainName) {
  throw new Error("hostedZoneId and hostedZoneName are only used with domainName");
}

// Laya serialises inference through a single worker, so the defaults are
// deliberately close to what one worker can actually sustain.
const rateLimit = Number(app.node.tryGetContext("rateLimit") ?? "20");
const burstLimit = Number(app.node.tryGetContext("burstLimit") ?? "40");

for (const [name, value] of [
  ["rateLimit", rateLimit],
  ["burstLimit", burstLimit]
] as const) {
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`CDK context ${name} must be a positive number`);
  }
}

new LayaVerificationStack(app, "LayaVerificationStack", {
  capacity,
  publicEndpoint,
  hostBenchmarkAccess,
  domainName,
  hostedZoneId,
  hostedZoneName,
  rateLimit,
  burstLimit,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION ?? "us-west-2"
  },
  description:
    "Laya System One API on Amazon ECS with GPU capacity, optionally exposed " +
    "through an Amazon API Gateway HTTP API"
});
