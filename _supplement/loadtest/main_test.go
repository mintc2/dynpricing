package main

import (
	"testing"
	"time"
)

func TestMedianMilliseconds(t *testing.T) {
	tests := []struct {
		name      string
		latencies []time.Duration
		want      float64
	}{
		{
			name:      "odd number of values",
			latencies: []time.Duration{9 * time.Millisecond, 1 * time.Millisecond, 5 * time.Millisecond},
			want:      5,
		},
		{
			name:      "even number of values",
			latencies: []time.Duration{8 * time.Millisecond, 2 * time.Millisecond, 4 * time.Millisecond, 6 * time.Millisecond},
			want:      5,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := medianMilliseconds(tt.latencies); got != tt.want {
				t.Fatalf("medianMilliseconds() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestPercentage(t *testing.T) {
	if got := percentage(1, 4); got != 25 {
		t.Fatalf("percentage(1, 4) = %v, want 25", got)
	}
	if got := percentage(1, 0); got != 0 {
		t.Fatalf("percentage(1, 0) = %v, want 0", got)
	}
}
