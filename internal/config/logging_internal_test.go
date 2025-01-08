// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package config

import (
	"bytes"
	"strings"
	"testing"

	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/logging"
	"github.com/spf13/viper"
)

func Test_logOutFromConfigs(t *testing.T) { //nolint:gocognit,maintidx // no need to worry about this in this test
	tests := map[string]struct {
		configType   string
		configFile   string
		env          map[string]string
		wantOut      string
		wantFilename string
		wantErr      bool
	}{
		"empty": {configType: "", configFile: "", env: nil, wantOut: "", wantFilename: "", wantErr: false},
		"tomlConfigNoDuplicateDisable": {
			configType: "toml",
			configFile: `[log]
null = true
disable = true
`,
			env:          nil,
			wantOut:      "",
			wantFilename: "",
			wantErr:      true,
		},
		"tomlConfigNoDuplicateDisableEnv": {
			configType: "toml",
			configFile: `[log]
none = true
`,
			env:          map[string]string{"REGINALD_LOG_DISABLE": "true"},
			wantOut:      "",
			wantFilename: "",
			wantErr:      true,
		},
		"tomlConfigInvalidOut": {
			configType: "toml",
			configFile: `[log]
output = "invalid"
`,
			env:          nil,
			wantOut:      "",
			wantFilename: "",
			wantErr:      true,
		},
		"invalidOutEnv": {
			configType:   "toml",
			configFile:   "",
			env:          map[string]string{"REGINALD_LOG_OUTPUT": "invalid"},
			wantOut:      "",
			wantFilename: "",
			wantErr:      true,
		},
		"tomlConfigInvalidOutEnv": {
			configType: "toml",
			configFile: `[log]
output = "invalid"
`,
			env:          map[string]string{"REGINALD_LOG_OUTPUT": "invalid"},
			wantOut:      "",
			wantFilename: "",
			wantErr:      true,
		},
		"tomlConfigImplicitFileOut": {
			configType: "toml",
			configFile: `[log]
output = "./file"
`,
			env:          nil,
			wantOut:      "file",
			wantFilename: "./file",
			wantErr:      false,
		},
		"implicitFileOutEnv": {
			configType:   "toml",
			configFile:   "",
			env:          map[string]string{"REGINALD_LOG_OUTPUT": "./file"},
			wantOut:      "file",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigImplicitFileOutEnv": {
			configType: "toml",
			configFile: `[log]
output = "./file-first"
`,
			env:          map[string]string{"REGINALD_LOG_OUTPUT": "./file-second"},
			wantOut:      "file",
			wantFilename: "./file-second",
			wantErr:      false,
		},
		"tomlConfigStderr": {
			configType: "toml",
			configFile: `[log]
stderr = true
`,
			env:          nil,
			wantOut:      "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStderrOverrides": {
			configType: "toml",
			configFile: `[log]
output = "file"
stderr = true
`,
			env:          nil,
			wantOut:      "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStderrEnvOverride": {
			configType: "toml",
			configFile: `[log]
stderr = false
`,
			env:          map[string]string{"REGINALD_LOG_STDERR": "true"},
			wantOut:      "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStderrEnvOverridesImplicit": {
			configType: "toml",
			configFile: `[log]
output = "./file"
`,
			env:          map[string]string{"REGINALD_LOG_STDERR": "true"},
			wantOut:      "stderr",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigStderrNoFalse": {
			configType: "toml",
			configFile: `[log]
stderr = false
`,
			env:          map[string]string{"REGINALD_LOG_STDERR": "false"},
			wantOut:      "",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStderrFalseDoesNotOverride": {
			configType: "toml",
			configFile: `[log]
output = "stderr"
stderr = false
`,
			env:          map[string]string{"REGINALD_LOG_STDERR": "false"},
			wantOut:      "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdout": {
			configType: "toml",
			configFile: `[log]
stdout = true
`,
			env:          nil,
			wantOut:      "stdout",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutOverrides": {
			configType: "toml",
			configFile: `[log]
output = "file"
stdout = true
`,
			env:          nil,
			wantOut:      "stdout",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutEnvOverride": {
			configType: "toml",
			configFile: `[log]
stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "true"},
			wantOut:      "stdout",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutEnvOverridesImplicit": {
			configType: "toml",
			configFile: `[log]
output = "./file"
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "true"},
			wantOut:      "stdout",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigStdoutNoFalse": {
			configType: "toml",
			configFile: `[log]
stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "false"},
			wantOut:      "",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutFalseDoesNotOverride": {
			configType: "toml",
			configFile: `[log]
output = "stdout"
stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "false"},
			wantOut:      "stdout",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutFalseDoesNotOverrideStderr": {
			configType: "toml",
			configFile: `[log]
output = "stderr"
stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "false"},
			wantOut:      "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutFalseDoesNotOverrideStderrBool": {
			configType: "toml",
			configFile: `[log]
output = "stdout"
stderr = true
stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "false"},
			wantOut:      "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigDisable": {
			configType: "toml",
			configFile: `[log]
null = true
`,
			env:          nil,
			wantOut:      "null",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigDisableOverrides": {
			configType: "toml",
			configFile: `[log]
output = "file"
null = true
`,
			env:          nil,
			wantOut:      "null",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigDisableEnvOverride": {
			configType: "toml",
			configFile: `[log]
stdout = false
file = "./file"
`,
			env:          map[string]string{"REGINALD_LOG_NULL": "true"},
			wantOut:      "null",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigDisableEnvOverridesImplicit": {
			configType: "toml",
			configFile: `[log]
output = "./file"
`,
			env:          map[string]string{"REGINALD_LOG_NONE": "true"},
			wantOut:      "none",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigDisableNoFalse": {
			configType: "toml",
			configFile: `[log]
null = false
`,
			env:          map[string]string{"REGINALD_LOG_NULL": "false"},
			wantOut:      "",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigDisableFalseDoesNotOverride": {
			configType: "toml",
			configFile: `[log]
output = "stdout"
null = false
`,
			env:          map[string]string{"REGINALD_LOG_NULL": "false"},
			wantOut:      "stdout",
			wantFilename: "",
			wantErr:      false,
		},
	}
	for name, tt := range tests { //nolint:varnamelen // tt is clear in tests
		t.Run(name, func(t *testing.T) {
			if tt.env != nil {
				for k, v := range tt.env {
					t.Setenv(k, v)
				}
			}

			// Do the setup steps that would have been done before calling the
			// function.

			vpr := viper.New()

			vpr.SetEnvPrefix(strings.ToLower(constants.Name))
			vpr.SetEnvKeyReplacer(strings.NewReplacer("-", "_", ".", "_"))
			vpr.AutomaticEnv()

			if tt.configFile != "" {
				vpr.SetConfigType(tt.configType)

				if err := vpr.ReadConfig(bytes.NewBufferString(tt.configFile)); err != nil {
					t.Fatalf("unexpectedly failed to read the test config file: %v", err)
				}

				t.Logf("Config read, all values now: %v", vpr.AllSettings())
			}

			for _, alias := range logging.AllOutputKeys {
				if err := vpr.BindEnv(alias); err != nil {
					t.Fatalf("unexpectedly failed to bind the environment variable \"REGINALD_%s\": %v",
						strings.ReplaceAll(strings.ToUpper(alias), "-", "_"),
						err,
					)
				}
			}

			gotOut, gotFilename, gotErr := logOutFromConfigs(vpr)
			if gotErr == nil && tt.wantErr {
				t.Fatal("logOutFromConfigs() succeeded unexpectedly")
			}

			if gotErr != nil && !tt.wantErr {
				t.Errorf("logOutFromConfigs() failed: %v", gotErr)
			}

			if gotOut != tt.wantOut {
				t.Errorf("logOutFromConfigs() = %v, want %v", gotOut, tt.wantOut)
			}

			if gotFilename != tt.wantFilename {
				t.Errorf("logOutFromConfigs() = %v, want %v", gotFilename, tt.wantFilename)
			}
		})
	}
}
