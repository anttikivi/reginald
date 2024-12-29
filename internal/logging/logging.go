package logging

import (
	"context"
	"log/slog"
)

type NullHandler struct{}

func (h NullHandler) Enabled(_ context.Context, _ slog.Level) bool {
	return false
}

func (h NullHandler) Handle(_ context.Context, _ slog.Record) error {
	return nil
}

func (h NullHandler) WithAttrs(_ []slog.Attr) slog.Handler {
	return h
}

func (h NullHandler) WithGroup(_ string) slog.Handler {
	return h
}
