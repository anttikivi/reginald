// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package logging_test

import (
	"io"
	"log/slog"
	"math/rand/v2"
	"testing"

	"github.com/anttikivi/reginald/internal/logging"
)

// Benchmark the null handler for disabling logs.
// These benchmarks are most meaningless but I wanted to add them for fun.
func BenchmarkNullHandler(b *testing.B) {
	logger := slog.New(logging.NullHandler{})
	for range b.N {
		logger.Info("Random integer message", "n", rand.Int()) //nolint:gosec // this is `math/rand`
	}
}

// Benchmark io.Discard with the JSON handler.
// These benchmarks are most meaningless but I wanted to add them for fun.
func BenchmarkDiscardJSONHandler(b *testing.B) {
	//nolint:exhaustruct // no need here
	logger := slog.New(slog.NewJSONHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelInfo}))
	for range b.N {
		//nolint:gosec // this is `math/rand`
		logger.Info("Random integer message", "n", rand.Int())
	}
}

// Benchmark io.Discard with the Text handler.
// These benchmarks are most meaningless but I wanted to add them for fun.
func BenchmarkDiscardTextHandler(b *testing.B) {
	//nolint:exhaustruct // no need here
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelInfo}))
	for range b.N {
		//nolint:gosec // this is `math/rand`
		logger.Info("Random integer message", "n", rand.Int())
	}
}
