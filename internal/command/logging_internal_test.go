package command

import (
	"bytes"
	"strings"
	"testing"

	"github.com/anttikivi/reginald/internal/constants"
	"github.com/spf13/viper"
)

func Test_normalizeLogDestination(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		v       string
		want    string
		wantErr bool
	}{
		{name: "empty", v: "", want: "", wantErr: false},
		{name: "bad", v: "bad", want: "", wantErr: true},
		{name: "disable", v: "disable", want: "none", wantErr: false},
		{name: "disabled", v: "disabled", want: "none", wantErr: false},
		{name: "nil", v: "nil", want: "none", wantErr: false},
		{name: "null", v: "null", want: "none", wantErr: false},
		{name: "dev/null", v: "/dev/null", want: "none", wantErr: false},
		{name: "file", v: "file", want: "file", wantErr: false},
		{name: "stderr", v: "stderr", want: "stderr", wantErr: false},
		{name: "stdout", v: "stdout", want: "stdout", wantErr: false},
		{name: "none", v: "none", want: "none", wantErr: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got, gotErr := normalizeLogDestination(tt.v)
			if gotErr == nil && tt.wantErr {
				t.Fatal("normalizeLogDestination() succeeded unexpectedly")
			}

			if gotErr != nil && !tt.wantErr {
				t.Errorf("normalizeLogDestination() failed: %v", gotErr)
			}

			if got != tt.want {
				t.Errorf("normalizeLogDestination() = %v, want %v", got, tt.want)
			}
		})
	}
}

func Test_logDestFromConfigs(t *testing.T) { //nolint:gocognit // no need to worry about this in this test
	tests := map[string]struct {
		configType   string
		configFile   string
		env          map[string]string
		wantDest     string
		wantFilename string
		wantErr      bool
	}{
		"empty": {configType: "", configFile: "", env: nil, wantDest: "", wantFilename: "", wantErr: false},
		"tomlConfigNoDuplicateDisable": {
			configType: "toml",
			configFile: `no-logs = true
disable-logs = true
`,
			env:          nil,
			wantDest:     "",
			wantFilename: "",
			wantErr:      true,
		},
		"tomlConfigNoDuplicateDisableEnv": {
			configType: "toml",
			configFile: `no-logs = true
`,
			env:          map[string]string{"REGINALD_DISABLE_LOGS": "true"},
			wantDest:     "",
			wantFilename: "",
			wantErr:      true,
		},
		"tomlConfigInvalidDest": {
			configType: "toml",
			configFile: `log-destination = "invalid"
`,
			env:          nil,
			wantDest:     "",
			wantFilename: "",
			wantErr:      true,
		},
		"invalidDestEnv": {
			configType:   "toml",
			configFile:   "",
			env:          map[string]string{"REGINALD_LOG_DESTINATION": "invalid"},
			wantDest:     "",
			wantFilename: "",
			wantErr:      true,
		},
		"tomlConfigInvalidDestEnv": {
			configType: "toml",
			configFile: `log-destination = "invalid"
`,
			env:          map[string]string{"REGINALD_LOG_DESTINATION": "invalid"},
			wantDest:     "",
			wantFilename: "",
			wantErr:      true,
		},
		"tomlConfigImplicitFileDest": {
			configType: "toml",
			configFile: `log-destination = "./file"
`,
			env:          nil,
			wantDest:     "file",
			wantFilename: "./file",
			wantErr:      false,
		},
		"implicitFileDestEnv": {
			configType:   "toml",
			configFile:   "",
			env:          map[string]string{"REGINALD_LOG_DESTINATION": "./file"},
			wantDest:     "file",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigImplicitFileDestEnv": {
			configType: "toml",
			configFile: `log-destination = "./file-first"
`,
			env:          map[string]string{"REGINALD_LOG_DESTINATION": "./file-second"},
			wantDest:     "file",
			wantFilename: "./file-second",
			wantErr:      false,
		},
		"tomlConfigStderr": {
			configType: "toml",
			configFile: `log-stderr = true
`,
			env:          nil,
			wantDest:     "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStderrOverrides": {
			configType: "toml",
			configFile: `log-destination = "file"
log-stderr = true
`,
			env:          nil,
			wantDest:     "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStderrEnvOverride": {
			configType: "toml",
			configFile: `log-stderr = false
`,
			env:          map[string]string{"REGINALD_LOG_STDERR": "true"},
			wantDest:     "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStderrEnvOverridesImplicit": {
			configType: "toml",
			configFile: `log-destination = "./file"
`,
			env:          map[string]string{"REGINALD_LOG_STDERR": "true"},
			wantDest:     "stderr",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigStderrNoFalse": {
			configType: "toml",
			configFile: `log-stderr = false
`,
			env:          map[string]string{"REGINALD_LOG_STDERR": "false"},
			wantDest:     "",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStderrFalseDoesNotOverride": {
			configType: "toml",
			configFile: `log-destination = "stderr"
log-stderr = false
`,
			env:          map[string]string{"REGINALD_LOG_STDERR": "false"},
			wantDest:     "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdout": {
			configType: "toml",
			configFile: `log-stdout = true
`,
			env:          nil,
			wantDest:     "stdout",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutOverrides": {
			configType: "toml",
			configFile: `log-destination = "file"
log-stdout = true
`,
			env:          nil,
			wantDest:     "stdout",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutEnvOverride": {
			configType: "toml",
			configFile: `log-stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "true"},
			wantDest:     "stdout",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutEnvOverridesImplicit": {
			configType: "toml",
			configFile: `log-destination = "./file"
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "true"},
			wantDest:     "stdout",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigStdoutNoFalse": {
			configType: "toml",
			configFile: `log-stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "false"},
			wantDest:     "",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutFalseDoesNotOverride": {
			configType: "toml",
			configFile: `log-destination = "stdout"
log-stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "false"},
			wantDest:     "stdout",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutFalseDoesNotOverrideStderr": {
			configType: "toml",
			configFile: `log-destination = "stderr"
log-stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "false"},
			wantDest:     "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutFalseDoesNotOverrideStderrBool": {
			configType: "toml",
			configFile: `log-destination = "stdout"
log-stderr = true
log-stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "false"},
			wantDest:     "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigDisable": {
			configType: "toml",
			configFile: `log-null = true
`,
			env:          nil,
			wantDest:     "none",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigDisableOverrides": {
			configType: "toml",
			configFile: `log-destination = "file"
log-null = true
`,
			env:          nil,
			wantDest:     "none",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigDisableEnvOverride": {
			configType: "toml",
			configFile: `log-stdout = false
log-file = "./file"
`,
			env:          map[string]string{"REGINALD_LOG_NULL": "true"},
			wantDest:     "none",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigDisableEnvOverridesImplicit": {
			configType: "toml",
			configFile: `log-destination = "./file"
`,
			env:          map[string]string{"REGINALD_LOG_NONE": "true"},
			wantDest:     "none",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigDisableNoFalse": {
			configType: "toml",
			configFile: `log-null = false
`,
			env:          map[string]string{"REGINALD_LOG_NULL": "false"},
			wantDest:     "",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigDisableFalseDoesNotOverride": {
			configType: "toml",
			configFile: `log-destination = "stdout"
log-null = false
`,
			env:          map[string]string{"REGINALD_LOG_NULL": "false"},
			wantDest:     "stdout",
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

			cfg := viper.New()

			cfg.SetEnvPrefix(strings.ToLower(constants.Name))
			cfg.SetEnvKeyReplacer(strings.NewReplacer("-", "_"))
			cfg.AutomaticEnv()

			if tt.configFile != "" {
				cfg.SetConfigType(tt.configType)

				if err := cfg.ReadConfig(bytes.NewBufferString(tt.configFile)); err != nil {
					t.Fatalf("unexpectedly failed to read the test config file: %v", err)
				}

				t.Logf("Config read, all values now: %v", cfg.AllSettings())
			}

			for _, alias := range allLogConfigNames {
				if err := cfg.BindEnv(alias); err != nil {
					t.Fatalf("unexpectedly failed to bind the environment variable \"REGINALD_%s\": %v",
						strings.ReplaceAll(strings.ToUpper(alias), "-", "_"),
						err,
					)
				}
			}

			gotDest, gotFilename, gotErr := logDestFromConfigs(cfg)
			if gotErr == nil && tt.wantErr {
				t.Fatal("logDestFromConfigs() succeeded unexpectedly")
			}

			if gotErr != nil && !tt.wantErr {
				t.Errorf("logDestFromConfigs() failed: %v", gotErr)
			}

			if gotDest != tt.wantDest {
				t.Errorf("logDestFromConfigs() = %v, want %v", gotDest, tt.wantDest)
			}

			if gotFilename != tt.wantFilename {
				t.Errorf("logDestFromConfigs() = %v, want %v", gotFilename, tt.wantFilename)
			}
		})
	}
}
