---
title: "Build a durable agent service"
description: "A practical starting point for a service people and agents can keep using."
date: "2026-09-11"
author: "Regents Labs"
author_x: "https://x.com/regents_sh"
image: "/images/blog/autolaunch.svg"
image_alt: "Autolaunch chart mark"
draft: false
---

Start with one useful service and a customer who would use it again. A revshare token is a way to organize a service's revenue; it does not create demand or guarantee future revenue.

## Make the service usable

Publish a stable HTTPS endpoint, its input and output schemas, one working example, and clear error responses. Tell callers what the service costs, how long a request may take, and how to retrieve a result after a timeout.

Keep the website, CLI and agent tools consistent. They should describe the same operation, charge the same published price, and return the same underlying result. Documentation should distinguish features that work now from planned features.

## Make payment and delivery recoverable

For an x402 endpoint, start with the [official seller guide](https://docs.x402.org/getting-started/quickstart-for-sellers). Configure the exact network, token, recipient and price. Verify payment evidence through the supported server integration; never trust a browser's claim that payment succeeded.

Give each logical request a durable identifier. Keep payment status, work status and the delivered result separately so a dropped connection does not leave the customer guessing. The [x402 payment-identifier extension](https://docs.x402.org/extensions/payment-identifier) supports identifying retries. Your service must also bind a stored result to the authorized caller and original request; an identifier alone is not permission to read someone else's result.

Reconcile uncertain payment outcomes before charging again. Publish what happens when payment succeeds but delivery fails, including a support path and any refund terms. Keep signing credentials out of page content, logs and agent prompts.

## Keep it running

Measure successful deliveries, failures, latency and the cost of providing each result. Account for hosting, model or data-provider charges, payment costs and support. Revenue and operating profit are different numbers.

Use durable storage for accepted work, bound retries, and preserve enough records to recover after a restart. Verify a restore from backup. Name an operator, publish a status/contact link, and describe how customers retrieve completed work if the service closes.

Before launching, have another person or agent discover the endpoint, complete a representative request and recover from an interrupted response. Publish the service's actual readiness and revenue destination. [Return to Create](/create/revstake) when those details are clear.
