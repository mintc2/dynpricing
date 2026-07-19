// Command loadtest exercises the locally Docker Compose-hosted pricing endpoint.
//
// Usage:
//
//	go run . <rps> <combinations>
//
// RPS may be a decimal between 0.01 and 100000. combinations is an integer
// between 1 and 36. Set PRICING_API_URL to target a different endpoint.
package main

import (
	"context"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	totalRequests  = 10_000
	requestTimeout = 1100 * time.Millisecond
	defaultAPIURL  = "http://localhost:3000/api/v1/pricing"
)

type combination struct {
	period string
	hotel  string
	room   string
}

type result struct {
	success  bool
	latency  time.Duration
	requests int64
}

type statistics struct {
	completed         atomic.Int64
	aborted           atomic.Int64
	firstTrySucceeded atomic.Int64

	mu        sync.Mutex
	latencies []time.Duration
	minimum   time.Duration
	maximum   time.Duration
}

func main() {
	rps, combinationCount, ok := parseArguments()
	if !ok {
		os.Exit(2)
	}

	endpoint := os.Getenv("PRICING_API_URL")
	if endpoint == "" {
		endpoint = defaultAPIURL
	}
	if _, err := url.ParseRequestURI(endpoint); err != nil {
		fmt.Fprintf(os.Stderr, "invalid PRICING_API_URL %q: %v\n", endpoint, err)
		os.Exit(2)
	}

	workers := int(math.Ceil(rps))
	combinations := allCombinations()[:combinationCount]
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	fmt.Printf("Starting %d requests at %.2f RPS with %d worker(s) across %d combination(s).\n", totalRequests, rps, workers, combinationCount)
	fmt.Printf("Target: %s\n", endpoint)

	client := &http.Client{Timeout: requestTimeout}
	jobs := make(chan int)
	results := make(chan result, workers)
	var workerGroup sync.WaitGroup
	workerGroup.Add(workers)
	for range workers {
		go func() {
			defer workerGroup.Done()
			for requestNumber := range jobs {
				results <- sendWithRetries(ctx, client, endpoint, combinations[requestNumber%len(combinations)])
			}
		}()
	}

	stats := &statistics{}
	startedAt := time.Now()
	progressDone := make(chan struct{})
	go printProgress(progressDone, stats, startedAt)

	go func() {
		defer close(jobs)
		interval := time.Duration(float64(time.Second) / rps)
		next := time.Now()
		for requestNumber := range totalRequests {
			if !waitUntil(ctx, next) {
				return
			}
			select {
			case jobs <- requestNumber:
			case <-ctx.Done():
				return
			}
			next = next.Add(interval)
		}
	}()

	go func() {
		workerGroup.Wait()
		close(results)
	}()

	for outcome := range results {
		stats.record(outcome)
	}
	close(progressDone)

	elapsed := time.Since(startedAt)
	printFinalStatistics(stats, elapsed)
}

func parseArguments() (float64, int, bool) {
	if len(os.Args) != 3 {
		fmt.Fprintf(os.Stderr, "usage: %s <rps: 0.01-100000> <combinations: 1-36>\n", os.Args[0])
		return 0, 0, false
	}

	rps, err := strconv.ParseFloat(os.Args[1], 64)
	if err != nil || math.IsNaN(rps) || math.IsInf(rps, 0) || rps < 0.01 || rps > 100000 {
		fmt.Fprintln(os.Stderr, "rps must be a number between 0.01 and 100000")
		return 0, 0, false
	}

	combinations, err := strconv.Atoi(os.Args[2])
	if err != nil || combinations < 1 || combinations > len(allCombinations()) {
		fmt.Fprintf(os.Stderr, "combinations must be an integer between 1 and %d\n", len(allCombinations()))
		return 0, 0, false
	}
	return rps, combinations, true
}

func sendWithRetries(ctx context.Context, client *http.Client, endpoint string, choice combination) result {
	startedAt := time.Now()
	result := result{}
	for {
		requestURL, err := requestURL(endpoint, choice)
		if err != nil {
			result.latency = time.Since(startedAt)
			return result
		}

		request, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL, nil)
		if err != nil {
			result.latency = time.Since(startedAt)
			return result
		}
		result.requests++
		response, err := client.Do(request)
		if err != nil {
			if ctx.Err() != nil {
				result.latency = time.Since(startedAt)
				return result
			}
			continue
		}

		io.Copy(io.Discard, response.Body)
		response.Body.Close()
		if response.StatusCode >= 200 && response.StatusCode < 300 {
			result.success = true
			result.latency = time.Since(startedAt)
			return result
		}
		if response.StatusCode >= 500 && response.StatusCode < 600 {
			continue
		}
		result.latency = time.Since(startedAt)
		return result // A 4xx (or other non-retryable response) is aborted.
	}
}

func requestURL(endpoint string, choice combination) (string, error) {
	parsed, err := url.Parse(endpoint)
	if err != nil {
		return "", err
	}
	query := parsed.Query()
	query.Set("period", choice.period)
	query.Set("hotel", choice.hotel)
	query.Set("room", choice.room)
	parsed.RawQuery = query.Encode()
	return parsed.String(), nil
}

func waitUntil(ctx context.Context, target time.Time) bool {
	delay := time.Until(target)
	if delay <= 0 {
		return true
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-ctx.Done():
		return false
	}
}

func (s *statistics) record(outcome result) {
	s.completed.Add(1)
	if outcome.success {
		if outcome.requests == 1 {
			s.firstTrySucceeded.Add(1)
		}
	} else {
		s.aborted.Add(1)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.latencies = append(s.latencies, outcome.latency)
	if len(s.latencies) == 1 || outcome.latency < s.minimum {
		s.minimum = outcome.latency
	}
	if outcome.latency > s.maximum {
		s.maximum = outcome.latency
	}
}

func printProgress(done <-chan struct{}, stats *statistics, startedAt time.Time) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			fmt.Printf("Progress: %d/%d completed, %d aborted, elapsed %s\n", stats.completed.Load(), totalRequests, stats.aborted.Load(), time.Since(startedAt).Round(time.Millisecond))
		case <-done:
			return
		}
	}
}

func printFinalStatistics(stats *statistics, elapsed time.Duration) {
	completed := stats.completed.Load()
	failed := stats.aborted.Load()
	firstTrySucceeded := stats.firstTrySucceeded.Load()

	stats.mu.Lock()
	defer stats.mu.Unlock()
	var minimum, median, maximum float64
	if len(stats.latencies) > 0 {
		minimum = float64(stats.minimum) / float64(time.Millisecond)
		median = medianMilliseconds(stats.latencies)
		maximum = float64(stats.maximum) / float64(time.Millisecond)
	}

	failedPercentage := percentage(failed, completed)
	firstTryPercentage := percentage(firstTrySucceeded, completed)
	retriedPercentage := 100 - failedPercentage - firstTryPercentage

	fmt.Println("\nFinal results")
	fmt.Println("-------------")
	fmt.Printf("Run time:                    %s\n", elapsed.Round(time.Millisecond))
	fmt.Printf("Total requests:              %d\n", completed)
	fmt.Printf("Failed/aborted:              %.2f%%\n", failedPercentage)
	fmt.Printf("Succeeded on first try:      %.2f%%\n", firstTryPercentage)
	fmt.Printf("Succeeded after retry:       %.2f%%\n", retriedPercentage)
	fmt.Printf("Response time min:           %.2f ms\n", minimum)
	fmt.Printf("Response time median:        %.2f ms\n", median)
	fmt.Printf("Response time max:           %.2f ms\n", maximum)
}

func percentage(part, total int64) float64 {
	if total == 0 {
		return 0
	}
	return float64(part) * 100 / float64(total)
}

func medianMilliseconds(latencies []time.Duration) float64 {
	sorted := append([]time.Duration(nil), latencies...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })

	middle := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return float64(sorted[middle]) / float64(time.Millisecond)
	}
	return float64(sorted[middle-1]+sorted[middle]) / 2 / float64(time.Millisecond)
}

func allCombinations() []combination {
	periods := []string{"Summer", "Autumn", "Winter", "Spring"}
	hotels := []string{"FloatingPointResort", "GitawayHotel", "RecursionRetreat"}
	rooms := []string{"SingletonRoom", "BooleanTwin", "RestfulKing"}

	combinations := make([]combination, 0, len(periods)*len(hotels)*len(rooms))
	for _, period := range periods {
		for _, hotel := range hotels {
			for _, room := range rooms {
				combinations = append(combinations, combination{period: period, hotel: hotel, room: room})
			}
		}
	}
	return combinations
}
