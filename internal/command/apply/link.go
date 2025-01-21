// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package apply

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"

	"github.com/anttikivi/reginald/internal/paths"
	"github.com/anttikivi/reginald/pkg/task"
	"github.com/mitchellh/mapstructure"
)

// link is the "link" task.
type link struct{}

// linkConfig contains the parsed settings for a link task.
//
// The config includes the base directory, but it must not be passed using the
// individual link configuration as it is overriden by the base directory for
// the run.
type linkConfig struct {
	BaseDirectory string   `mapstructure:"base-directory"` // the base directory of the run
	Create        bool     // whether to create missing parent directories for the links
	Force         bool     // whether to remove old file at the destination paths
	Platform      []string // platforms on which the link should be created
	Links         any      // links configuration
}

// linkFile is a single file for linking in the link configuration. It is merged
// from the upstream configs for the link task and the settings given for each
// link entry.
type linkFile struct {
	Src      string   // source path for the link
	Target   string   // the link destination
	Create   bool     // whether to create missing parent directories for the link
	Force    bool     // whether to remove old file at the destination path
	Platform []string // platforms on which the link should be created
	Contents bool     // if the source path is a directory, create links of its contents to the destination directory
	Exclude  []string // if using `contents`, exclude these files
}

// Errors returned from parsing the links configuration.
var (
	// errInvalidMapEntry is returned when the map config for links is used but
	// an entry is not a map.
	errInvalidMapEntry = errors.New("entry in the links map is not a map")

	// errMissingTarget is returned when a link entry in an array of maps does
	// not have a target value.
	errMissingTarget = errors.New("link entry does not have a target value")
)

func (l *link) Check(settings task.Settings) error {
	var linkCfg linkConfig

	decoderCfg := decoderConfig(&linkCfg)

	decoder, err := mapstructure.NewDecoder(decoderCfg)
	if err != nil {
		return fmt.Errorf("failed to check the config for %s: %w", l.Type(), err)
	}

	slog.Debug("decoding", "settings", settings)

	if err := decoder.Decode(settings); err != nil {
		slog.Error("failed to unmarshal link config", "settings", settings)

		return fmt.Errorf("%w", task.NewError(l, err))
	}

	slog.Debug("decoded link task config", "cfg", linkCfg)

	valid := false
	switch v := linkCfg.Links.(type) {
	case []any:
		_, valid = linkStrings(v, linkCfg)
	case map[string]any:
		_, err = linkMap(v, linkCfg)
		if err != nil {
			return task.NewError(l, err)
		}

		valid = true
	case []map[string]any:
		_, err = linkMapSlice(v, linkCfg)
		if err != nil {
			return task.NewError(l, err)
		}

		valid = true
	default:
		slog.Error("value in the config for link has invalid type", "type", reflect.TypeOf(v), "key", "links", "value", linkCfg.Links)

		return fmt.Errorf("%w", task.NewInvalidType(l, "links", v, "slice or map"))
	}

	if !valid {
		slog.Error("value in the config for link has invalid type", "type", reflect.TypeOf(linkCfg.Links), "key", "links", "value", linkCfg.Links)

		return fmt.Errorf("%w", task.NewInvalidType(l, "links", linkCfg.Links, "slice or map"))
	}

	return nil
}

func (l *link) CheckDefaults(settings task.Settings) error {
	for k, v := range settings {
		switch k {
		case "create", "force":
			if _, ok := v.(bool); !ok {
				slog.Info("value in the defaults for link has invalid type", "key", k, "value", v)

				return fmt.Errorf("%w", task.NewInvalidType(l, k, v, "boolean"))
			}
		default:
			slog.Info("invalid key in the defaults for link", "key", k, "value", v)

			return fmt.Errorf("%w", task.NewInvalidKey(l, k))
		}
	}

	return nil
}

func (l *link) Run(_ *task.Config) error {
	return nil
}

func (l *link) Type() string {
	return "link"
}

func decoderConfig(result any) *mapstructure.DecoderConfig {
	return &mapstructure.DecoderConfig{
		DecodeHook:       mapstructure.ComposeDecodeHookFunc(mapstructure.StringToSliceHookFunc(",")),
		ErrorUnused:      true,
		WeaklyTypedInput: true,
		Result:           result,
		MatchName: func(mapKey, fieldName string) bool {
			if strings.Contains(mapKey, "/") || strings.Contains(mapKey, "\\") || strings.Contains(mapKey, "$") || strings.Contains(mapKey, "%") {
				return mapKey == fieldName
			}

			return strings.EqualFold(mapKey, fieldName)
		},
	}
}

func platformEnabled(platform string) bool {
	return runtime.GOOS == platform
}

// linkStrings checks if the given "links" config option is a slice of strings and parses it into a slice of [linkFile]s. It returns the parsed slice and whether the operation was successful.
func linkStrings(links []any, cfg linkConfig) ([]linkFile, bool) {
	result := make([]linkFile, len(links))

	for i, l := range links {
		if s, ok := l.(string); ok {
			src, err := parseLinkSrc(s, cfg)
			if err != nil {
				slog.Error("failed to parse link src", "s", s, "err", err)

				return nil, false
			}

			target, err := paths.Abs(s)
			if err != nil {
				slog.Error("failed to parse link target", "path", s, "err", err)

				return nil, false
			}

			result[i] = linkFile{
				Src:      src,
				Target:   target,
				Create:   cfg.Create,
				Force:    cfg.Force,
				Platform: cfg.Platform,
				Contents: false,
				Exclude:  nil,
			}
		} else {
			return nil, false
		}
	}

	return result, true
}

func linkMap(links map[string]any, cfg linkConfig) ([]linkFile, error) {
	result := make([]linkFile, 0, len(links))

	for target, v := range links {
		if m, ok := v.(map[string]any); ok {
			if _, ok := m["src"]; !ok {
				src, err := parseLinkSrc(target, cfg)
				if err != nil {
					slog.Error("failed to parse link src", "s", target, "err", err)

					return nil, fmt.Errorf("failed to parse link source: %w", err)
				}

				m["src"] = src
			}

			if _, ok := m["create"]; !ok {
				m["create"] = cfg.Create
			}

			if _, ok := m["force"]; !ok {
				m["force"] = cfg.Force
			}

			if _, ok := m["platform"]; !ok {
				m["platform"] = cfg.Platform
			}

			var entry struct {
				Src      string
				Create   bool
				Force    bool
				Platform []string
				Contents bool
				Exclude  []string
			}
			decoderCfg := decoderConfig(&entry)

			decoder, err := mapstructure.NewDecoder(decoderCfg)
			if err != nil {
				return nil, fmt.Errorf("failed to check a link entry for %s: %w", target, err)
			}

			if err := decoder.Decode(m); err != nil {
				slog.Error("failed to unmarshal a link entry", "entry", m)

				return nil, fmt.Errorf("%w", err)
			}

			slog.Debug("decoded link entry", "entry", entry)

			src, err := paths.Abs(entry.Src)
			if err != nil {
				slog.Error("failed to parse link src", "src", entry.Src, "err", err)

				return nil, fmt.Errorf("%w", err)
			}

			entry.Src = src

			target, err = paths.Abs(target)
			if err != nil {
				slog.Error("failed to parse link target", "err", err)

				return nil, fmt.Errorf("%w", err)
			}

			result = append(result, linkFile{
				Src:      entry.Src,
				Target:   target,
				Create:   entry.Create,
				Force:    entry.Force,
				Platform: entry.Platform,
				Contents: entry.Contents,
				Exclude:  entry.Exclude,
			})
		} else {
			return nil, fmt.Errorf("%w: %s", errInvalidMapEntry, target)
		}
	}

	return result, nil
}

func linkMapSlice(links []map[string]any, cfg linkConfig) ([]linkFile, error) {
	result := make([]linkFile, 0, len(links))

	for _, m := range links {
		if _, ok := m["target"]; !ok {
			return nil, fmt.Errorf("%w: %v", errMissingTarget, m)
		}

		if _, ok := m["create"]; !ok {
			m["create"] = cfg.Create
		}

		if _, ok := m["force"]; !ok {
			m["force"] = cfg.Force
		}

		if _, ok := m["platform"]; !ok {
			m["platform"] = cfg.Platform
		}

		var entry struct {
			Src      string
			Target   string
			Create   bool
			Force    bool
			Platform []string
			Contents bool
			Exclude  []string
		}
		decoderCfg := decoderConfig(&entry)

		decoder, err := mapstructure.NewDecoder(decoderCfg)
		if err != nil {
			return nil, fmt.Errorf("failed to check a link entry for %v: %w", m, err)
		}

		if err := decoder.Decode(m); err != nil {
			slog.Error("failed to unmarshal a link entry", "entry", m)

			return nil, fmt.Errorf("%w", err)
		}

		slog.Debug("decoded link entry", "entry", entry)

		if entry.Src == "" {
			src, err := parseLinkSrc(entry.Target, cfg)
			if err != nil {
				slog.Error("failed to parse link src", "m", m, "err", err)

				return nil, fmt.Errorf("failed to parse link source: %w", err)
			}

			entry.Src = src
		}

		src, err := paths.Abs(entry.Src)
		if err != nil {
			slog.Error("failed to parse link src", "src", entry.Src, "err", err)

			return nil, fmt.Errorf("%w", err)
		}

		entry.Src = src

		entry.Target, err = paths.Abs(entry.Target)
		if err != nil {
			slog.Error("failed to parse link target", "err", err)

			return nil, fmt.Errorf("%w", err)
		}

		result = append(result, linkFile{
			Src:      entry.Src,
			Target:   entry.Target,
			Create:   entry.Create,
			Force:    entry.Force,
			Platform: entry.Platform,
			Contents: entry.Contents,
			Exclude:  entry.Exclude,
		})
	}

	return result, nil
}

func parseLinkSrc(link string, cfg linkConfig) (string, error) {
	if strings.HasPrefix(link, "~/") {
		return filepath.Join(cfg.BaseDirectory, strings.TrimPrefix(link, "~/")), nil
	}

	path, err := paths.Abs(link)
	if err != nil {
		return "", fmt.Errorf("%w", err)
	}

	return path, nil
}
