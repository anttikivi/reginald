// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

//nolint:dupword // Not really duplicates.
package logging

import (
	"context"
	"log/slog"
	"strconv"

	"github.com/hashicorp/go-hclog"
)

// HCLogHandler is an [slog.Handler] that redirects logs from from slog to hclog
// to stream them to the plugin host during a Reginald run.
//
// TODO: Implement a custom format for the logs so that the client can parse the
// attributes correctly. Now they are included in the message when the client
// outputs the logs.
type HCLogHandler struct {
	logger hclog.Logger
	prefix string
}

var levels = map[slog.Level]hclog.Level{ //nolint:gochecknoglobals // Used like a constant.
	slog.LevelDebug - 4: hclog.Trace,
	slog.LevelDebug:     hclog.Debug,
	slog.LevelInfo:      hclog.Info,
	slog.LevelWarn:      hclog.Warn,
	slog.LevelError:     hclog.Error,
}

func NewHCLogAdapter(logger hclog.Logger) *HCLogHandler {
	return &HCLogHandler{logger: logger, prefix: logger.Name()}
}

func (h *HCLogHandler) Enabled(_ context.Context, l slog.Level) bool {
	switch {
	case l < slog.LevelDebug:
		return h.logger.IsTrace()
	case l < slog.LevelInfo:
		return h.logger.IsDebug()
	case l < slog.LevelWarn:
		return h.logger.IsInfo()
	case l < slog.LevelError:
		return h.logger.IsWarn()
	default:
		return h.logger.IsError()
	}
}

func (h *HCLogHandler) Handle(_ context.Context, r slog.Record) error { //nolint:gocritic // Implements interface.
	attrs := make([]any, 0, r.NumAttrs()*2) //nolint:mnd // Double the capacity.

	var i int

	r.Attrs(func(attr slog.Attr) bool {
		attrs = append(attrs, h.processAttribute(i, h.prefix, attr)...)
		i++

		return true
	})

	h.logger.Log(h.toHCLogLevel(r.Level), r.Message, attrs...)

	return nil
}

func (h *HCLogHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	newAttrs := make([]any, 0, len(attrs))

	for i, attr := range attrs {
		newAttrs = append(newAttrs, h.processAttribute(i, h.prefix, attr)...)
	}

	return &HCLogHandler{
		logger: h.logger.With(newAttrs...),
		prefix: h.prefix,
	}
}

func (h *HCLogHandler) WithGroup(name string) slog.Handler {
	prefix := h.prefix

	if name != "" {
		prefix = h.prefix + name + "."
	}

	return &HCLogHandler{
		logger: h.logger,
		prefix: prefix,
	}
}

func (h *HCLogHandler) processAttribute(pos int, prefix string, attr slog.Attr) []any {
	val := attr.Value.Resolve()

	var attrs []any
	if val.Kind() == slog.KindGroup {
		attrs = append(attrs, h.processGroup(prefix, attr)...)
	} else {
		key := attr.Key
		if key == "" {
			if attr.Value.Equal(slog.Value{}) {
				return nil
			}

			// If the key is empty but there is a value, then make the key
			// the position of the attributes in the record.
			key = strconv.Itoa(pos)
		}

		attrs = append(attrs, prefix+key, val.Any())
	}

	return attrs
}

func (h *HCLogHandler) processGroup(prefix string, attr slog.Attr) []any {
	var attrs []any

	if attr.Key == "" {
		for _, subAttr := range attr.Value.Group() {
			if subAttr.Value.Kind() != slog.KindGroup {
				attrs = append(attrs, prefix+subAttr.Key, subAttr.Value.Any())
			}
		}

		return attrs
	}

	prefix = prefix + attr.Key + "."

	for i, subAttr := range attr.Value.Group() {
		attrs = append(attrs, h.processAttribute(i, prefix, subAttr)...)
	}

	return attrs
}

func (h *HCLogHandler) toHCLogLevel(l slog.Level) hclog.Level {
	if tl, ok := levels[l]; ok {
		return tl
	}

	switch {
	case l < slog.LevelDebug:
		return hclog.Trace
	case l < slog.LevelInfo:
		return hclog.Debug
	case l < slog.LevelWarn:
		return hclog.Info
	case l < slog.LevelError:
		return hclog.Warn
	default:
		return hclog.Error
	}
}
