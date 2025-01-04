package command

import (
	"bytes"
	"strings"
	"testing"

	"github.com/anttikivi/reginald/internal/constants"
	"github.com/spf13/viper"
)

func Test_normalizeLogOutput(t *testing.T) {
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

			got, gotErr := normalizeLogOutput(tt.v)
			if gotErr == nil && tt.wantErr {
				t.Fatal("normalizeLogOutput() succeeded unexpectedly")
			}

			if gotErr != nil && !tt.wantErr {
				t.Errorf("normalizeLogOutput() failed: %v", gotErr)
			}

			if got != tt.want {
				t.Errorf("normalizeLogOutput() = %v, want %v", got, tt.want)
			}
		})
	}
}

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
			configFile: `no-logs = true
disable-logs = true
`,
			env:          nil,
			wantOut:      "",
			wantFilename: "",
			wantErr:      true,
		},
		"tomlConfigNoDuplicateDisableEnv": {
			configType: "toml",
			configFile: `no-logs = true
`,
			env:          map[string]string{"REGINALD_DISABLE_LOGS": "true"},
			wantOut:      "",
			wantFilename: "",
			wantErr:      true,
		},
		"tomlConfigInvalidOut": {
			configType: "toml",
			configFile: `log-output = "invalid"
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
			configFile: `log-output = "invalid"
`,
			env:          map[string]string{"REGINALD_LOG_OUTPUT": "invalid"},
			wantOut:      "",
			wantFilename: "",
			wantErr:      true,
		},
		"tomlConfigImplicitFileOut": {
			configType: "toml",
			configFile: `log-output = "./file"
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
			configFile: `log-output = "./file-first"
`,
			env:          map[string]string{"REGINALD_LOG_OUTPUT": "./file-second"},
			wantOut:      "file",
			wantFilename: "./file-second",
			wantErr:      false,
		},
		"tomlConfigStderr": {
			configType: "toml",
			configFile: `log-stderr = true
`,
			env:          nil,
			wantOut:      "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStderrOverrides": {
			configType: "toml",
			configFile: `log-output = "file"
log-stderr = true
`,
			env:          nil,
			wantOut:      "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStderrEnvOverride": {
			configType: "toml",
			configFile: `log-stderr = false
`,
			env:          map[string]string{"REGINALD_LOG_STDERR": "true"},
			wantOut:      "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStderrEnvOverridesImplicit": {
			configType: "toml",
			configFile: `log-output = "./file"
`,
			env:          map[string]string{"REGINALD_LOG_STDERR": "true"},
			wantOut:      "stderr",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigStderrNoFalse": {
			configType: "toml",
			configFile: `log-stderr = false
`,
			env:          map[string]string{"REGINALD_LOG_STDERR": "false"},
			wantOut:      "",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStderrFalseDoesNotOverride": {
			configType: "toml",
			configFile: `log-output = "stderr"
log-stderr = false
`,
			env:          map[string]string{"REGINALD_LOG_STDERR": "false"},
			wantOut:      "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdout": {
			configType: "toml",
			configFile: `log-stdout = true
`,
			env:          nil,
			wantOut:      "stdout",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutOverrides": {
			configType: "toml",
			configFile: `log-output = "file"
log-stdout = true
`,
			env:          nil,
			wantOut:      "stdout",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutEnvOverride": {
			configType: "toml",
			configFile: `log-stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "true"},
			wantOut:      "stdout",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutEnvOverridesImplicit": {
			configType: "toml",
			configFile: `log-output = "./file"
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "true"},
			wantOut:      "stdout",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigStdoutNoFalse": {
			configType: "toml",
			configFile: `log-stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "false"},
			wantOut:      "",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutFalseDoesNotOverride": {
			configType: "toml",
			configFile: `log-output = "stdout"
log-stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "false"},
			wantOut:      "stdout",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutFalseDoesNotOverrideStderr": {
			configType: "toml",
			configFile: `log-output = "stderr"
log-stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "false"},
			wantOut:      "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigStdoutFalseDoesNotOverrideStderrBool": {
			configType: "toml",
			configFile: `log-output = "stdout"
log-stderr = true
log-stdout = false
`,
			env:          map[string]string{"REGINALD_LOG_STDOUT": "false"},
			wantOut:      "stderr",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigDisable": {
			configType: "toml",
			configFile: `log-null = true
`,
			env:          nil,
			wantOut:      "none",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigDisableOverrides": {
			configType: "toml",
			configFile: `log-output = "file"
log-null = true
`,
			env:          nil,
			wantOut:      "none",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigDisableEnvOverride": {
			configType: "toml",
			configFile: `log-stdout = false
log-file = "./file"
`,
			env:          map[string]string{"REGINALD_LOG_NULL": "true"},
			wantOut:      "none",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigDisableEnvOverridesImplicit": {
			configType: "toml",
			configFile: `log-output = "./file"
`,
			env:          map[string]string{"REGINALD_LOG_NONE": "true"},
			wantOut:      "none",
			wantFilename: "./file",
			wantErr:      false,
		},
		"tomlConfigDisableNoFalse": {
			configType: "toml",
			configFile: `log-null = false
`,
			env:          map[string]string{"REGINALD_LOG_NULL": "false"},
			wantOut:      "",
			wantFilename: "",
			wantErr:      false,
		},
		"tomlConfigDisableFalseDoesNotOverride": {
			configType: "toml",
			configFile: `log-output = "stdout"
log-null = false
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

			gotOut, gotFilename, gotErr := logOutFromConfigs(cfg)
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
