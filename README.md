# Use of AI

I use AI in my day-to-day work, so I will utilize it here as well.

In the same vein, I have the following philosophy toward AI: "You can outsource a lot of things, but not your understanding."
Meaning, even when I use AI, I still want to fully understand my codebase to such a degree that I won't have trouble debugging
or adding new features, even if AI disappeared tomorrow. As such, I will split the work between me and the AI like this.

What is done by me:

- Understanding of the task at hand, constraints, and limitations.
- Planning and formulation of the solution.
- Splitting the solution into bite-sized chunks to be implemented.
- Testing plan and test cases.
- Review of the written code; stylistic improvements and simplification recommendations.

What I will leave to the AI/consult the AI on:

- Enumeration of the existing directory structure.
- Ruby syntax and library recommendations.
- Rails conventions.
- The grunt work of writing the code, according to plan points.
- Additional adversarial code review by a different model to catch things my Ruby-untrained eye can't yet.

Also, this whole file is fully written by me. I know nobody likes reading AI slop essays.
But if you wish, you can check things AI produced and I fed into it in the ./ai-data dir.

# Legend

I will use this naming throughout this doc for consistency.

- dProxy -> This dynamic proxy-pricing caching proxy service.
- RateAPI -> The underlying hotel's rate-calculating API.

# Constraints

Solution constraints:

- The solution needs to be "production" quality. At the very least, with logs and errors propagated to the client. Additionally, tracing and metrics can be added.
- The solution needs to employ defense-in-depth, be resilient, and be able to handle any error gracefully.
- The solution, with its constraints, benefits, and alternatives, needs to be outlined in a file.
- dProxy API must handle 10,000 req/day. That's around 7 req/min spread uniformly.
- RateAPI has one token provided. The limit is 1,000 req/day, ~0.69 req/min spread uniformly, much lower than dProxy's desired limit.
- The task description says that RateAPI responses can be cached for 5 minutes (per combination period, hotel, room). The number of periods, hotels, and rooms is bounded.
- Anything inside this repo can be modified or re-arranged.
- The solution needs to be tested, ideally using automated testing.

# Unknowns that need to be investigated/dealt with

Q: Is the incoming traffic spread uniformly throughout the day, is it concentrated during the "day," or is it coming in one burst?
A: Not specified. Ideally, it must be able to handle any distribution. But judging from the language used, the excess load can be 503-ed,
as long as it can be processed later within the same day.

Q: Who are the users of dProxy? Background workers or are requests coming from users in real time? What's the caller latency tolerance limit?
A: We can't know. We have to assume it's a real user, with some realistic-ish tolerance limit.

Q: Can a single Ruby instance handle 10,000 concurrent requests if RateAPI work is batched into a single request?
A: No. Apparently, with the default scheduler, each request takes an OS thread. So with 5 threads and 1 Puma process, the total concurrent maximum is 5 RPS.

Q: Any default timeouts set for the HTTP client/server?
A: No. Only Puma worker timeout and the SQLite timeouts are set.

Q: Are the period, hotel, and room always provided, or are some of the fields optional?
A: The existing validator requires all arguments to be present.

Q: The caching will be done by a key combining K(period, hotel, room). What's the max number of combinations?
A: 4*3*3 = 36 combinations. Won't take much space when caching.

Q: Is dProxy deployed in a single instance or multiple?
A: Configured as a single application instance. It can process multiple requests in parallel, though (RAILS_MAX_THREADS * WEB_CONCURRENCY).

Q: RateAPI supports batched requests. Does dProxy's surface expose batching to the outside world?
A: No, it accepts them one by one.

Q: RateAPI supports batched requests and the docs don't specify a max limit. 
Is there a max limit of batch items it can accept at once? Is it lower than the number of possible `(period, hotel, room)` combinations?
A: It can handle 36 unique combinations all at once.

Q: RateAPI response time?
A: Based on the results of `06_out_test_api_batch_reliability.sh`:
```
Results
-------
Batch size (items):   36
Attempts:             1000
Successful (HTTP 200): 849
Errors (non-200):     79
Client timeouts:      72
Error rate:           7.90% (79/1000)
Timeout rate:         7.20% (72/1000)
# Combined error rate ~15%

Latency of successful batch responses
-------------------------------------
Samples:              849
Average total time:   2.20 ms
Minimum total time:   0.94 ms
p50 total time:       2.14 ms
p95 total time:       3.20 ms
p99 total time:       3.72 ms
Maximum total time:   11.06 ms
```

Q: Is RateAPI's daily limit consumed in cases where it returns 500 or times out?
A: Every request consumes the quota, even the ones that fail/time out.

Q: Does dProxy have any way of identifying a user who's sending the request?
A: No. The API dProxy exposes is unauthenticated.

# Assumptions

I will make the following assumptions based on what I know so far:

- RateAPI's performance can't be immediately improved and has to be worked around.
- RateAPI's performance, response times, and error rate will stay in line with my simulated "load test."
- The users of dProxy are individual people/customers, not a background worker. The assumed max response latency tolerance is 1 s.
- The client retries on retryable HTTP codes, such as 503.
- Latency tolerance of dProxy's gateway is slightly larger than 1 s.
- The infrastructure is reliable. Things like redis have industry standard uptime of 99.999%.
- The traffic distribution is unknown (uniform throughout the day vs. single burst vs. spread during waking hours). 
  The solution can begin by handling the stated 10k req/day in a way that satisfies that requirement in the loosest way possible,
  but it should be designed to be easily adjustable to handle the extreme case where all of the daily traffic is 
  compressed into a single minute or second.

# Solution

![Solution diagram](solution_diagram.excalidraw.png)

This solution is simple, meets the minimum requirements, and can be extended to handle severe cases where all of the daily traffic is concentrated in a short burst.

Important implementation details:

- On a fresh deploy, until the first refresh completes, every request is a cache miss -> 503 (Unavailable).
- If dProxy gets a cache miss, it will return 503, expecting that the client has its own retries on 5XX codes set.
- The cache refresh job will run once every 2 minutes, so one unsuccessful refresh cycle is tolerable because the previous cycle's values will still be in the cache. Two consecutive refresh cycle misses is highly unlikely (see the point below), but if it happens it will produce a 1 minute window where the dProxy will respond with 503.
- The likelihood of the cache background job not being able to refresh the cache for two cycles in a row, each making three retry attempts, is negligible. ((0.15)^3)^2 * 100% = 0.0011390625%
- In an unlikely case Redis is down, the API will start returning 500 (Internal) errors, until the redis is up.
- The cache refresh job will internally retry if the Rate API times out or returns 5XX-class errors. The retry limit will be set to 3, with no exponential backoff (no backoff is acceptable because the job is off the request path and low frequency).
- The cache refresh job will set the client timeout to 50 ms because RateAPI seems to answer within 10 ms or hang for >30 s.
- The cache refresh job will precompute all 36 possible combinations and request them in a single batch.
- The cache expiration TTL will be set to 5 minutes. Strict; it doesn't get refreshed when accessed.
- With this simple implementation, producing INFO/ERROR logs with structured fields for each request would make the service sufficiently observable. The users of dProxy will receive generic error text, with no internal service details for security reasons. The job will also log the result of it's refresh.

Additional technologies used for the implementation:

- Sidekiq will be used as the background job/cron scheduler.
- Caching will be done in Redis (unauthenticated, not port forwarded; in real prod AUTH/TLS would need to be there). It's fast, and Sidekiq has it as a dependency.

Constraint satisfaction check:

- [x] Can dProxy handle 10,000 req/day? - Yes, if the traffic is sufficiently spread. If it's concentrated, the solution can be extended to scale horizontally.
- [x] Does dProxy make fewer than 1,000 req/day to RateAPI? - Yes. With the refresh rate of the cache set to every 2m, the maximum number of calls to the RateAPI will be 720 + ~108 (retries with ~15% API failure rate) = 828. Worst case (every cycle exhausts 3 retries) is 2,160 calls/day, which would breach quota; at a 15% batch-failure rate this is highly unlikely to happen.
- [x] Does dProxy avoid serving cached entries older than > 5 min? - Yes. The cached entries are refreshed every 2 minutes and automatically evicted by Redis after 5 minutes if not updated. 
- [x] Is it production quality? - Yes. The internal errors are hidden from the caller. It handles errors gracefully, has meaningful logs, and doesn't contain hard-coded access tokens in the repo code.
