package semver_test

import (
	"testing"

	"github.com/anttikivi/reginald/internal/semver"
)

var tests = []struct { //nolint:gochecknoglobals
	in  string
	out string
}{
	{"", ""},

	{"0.1.0-alpha.24+sha.19031c2.darwin.amd64", "0.1.0-alpha.24"},
	{"0.1.0-alpha.24+sha.19031c2-darwin-amd64", "0.1.0-alpha.24"},

	{"bad", ""},
	{"1-alpha.beta.gamma", ""},
	{"1-pre", ""},
	{"1+meta", ""},
	{"1-pre+meta", ""},
	{"1.2-pre", ""},
	{"1.2+meta", ""},
	{"1.2-pre+meta", ""},
	{"1.0.0-alpha", "1.0.0-alpha"},
	{"1.0.0-alpha.1", "1.0.0-alpha.1"},
	{"1.0.0-alpha.beta", "1.0.0-alpha.beta"},
	{"1.0.0-beta", "1.0.0-beta"},
	{"1.0.0-beta.2", "1.0.0-beta.2"},
	{"1.0.0-beta.11", "1.0.0-beta.11"},
	{"1.0.0-rc.1", "1.0.0-rc.1"},
	{"1", ""},
	{"1.0", ""},
	{"1.0.0", "1.0.0"},
	{"1.2", ""},
	{"1.2.0", "1.2.0"},
	{"1.2.3-456", "1.2.3-456"},
	{"1.2.3-456.789", "1.2.3-456.789"},
	{"1.2.3-456-789", "1.2.3-456-789"},
	{"1.2.3-456a", "1.2.3-456a"},
	{"1.2.3-pre", "1.2.3-pre"},
	{"1.2.3-pre+meta", "1.2.3-pre"},
	{"1.2.3-pre.1", "1.2.3-pre.1"},
	{"1.2.3-zzz", "1.2.3-zzz"},
	{"1.2.3", "1.2.3"},
	{"1.2.3+meta", "1.2.3"},
	{"1.2.3+meta-pre", "1.2.3"},
	{"1.2.3+meta-pre.sha.256a", "1.2.3"},

	{"vbad", ""},
	{"v1-alpha.beta.gamma", ""},
	{"v1-pre", ""},
	{"v1+meta", ""},
	{"v1-pre+meta", ""},
	{"v1.2-pre", ""},
	{"v1.2+meta", ""},
	{"v1.2-pre+meta", ""},
	{"v1.0.0-alpha", "1.0.0-alpha"},
	{"v1.0.0-alpha.1", "1.0.0-alpha.1"},
	{"v1.0.0-alpha.beta", "1.0.0-alpha.beta"},
	{"v1.0.0-beta", "1.0.0-beta"},
	{"v1.0.0-beta.2", "1.0.0-beta.2"},
	{"v1.0.0-beta.11", "1.0.0-beta.11"},
	{"v1.0.0-rc.1", "1.0.0-rc.1"},
	{"v1", ""},
	{"v1.0", ""},
	{"v1.0.0", "1.0.0"},
	{"v1.2", ""},
	{"v1.2.0", "1.2.0"},
	{"v1.2.3-456", "1.2.3-456"},
	{"v1.2.3-456.789", "1.2.3-456.789"},
	{"v1.2.3-456-789", "1.2.3-456-789"},
	{"v1.2.3-456a", "1.2.3-456a"},
	{"v1.2.3-pre", "1.2.3-pre"},
	{"v1.2.3-pre+meta", "1.2.3-pre"},
	{"v1.2.3-pre.1", "1.2.3-pre.1"},
	{"v1.2.3-zzz", "1.2.3-zzz"},
	{"v1.2.3", "1.2.3"},
	{"v1.2.3+meta", "1.2.3"},
	{"v1.2.3+meta-pre", "1.2.3"},
	{"v1.2.3+meta-pre.sha.256a", "1.2.3"},

	{"reginaldbad", ""},
	{"reginald1-alpha.beta.gamma", ""},
	{"reginald1-pre", ""},
	{"reginald1+meta", ""},
	{"reginald1-pre+meta", ""},
	{"reginald1.2-pre", ""},
	{"reginald1.2+meta", ""},
	{"reginald1.2-pre+meta", ""},
	{"reginald1.0.0-alpha", "1.0.0-alpha"},
	{"reginald1.0.0-alpha.1", "1.0.0-alpha.1"},
	{"reginald1.0.0-alpha.beta", "1.0.0-alpha.beta"},
	{"reginald1.0.0-beta", "1.0.0-beta"},
	{"reginald1.0.0-beta.2", "1.0.0-beta.2"},
	{"reginald1.0.0-beta.11", "1.0.0-beta.11"},
	{"reginald1.0.0-rc.1", "1.0.0-rc.1"},
	{"reginald1", ""},
	{"reginald1.0", ""},
	{"reginald1.0.0", "1.0.0"},
	{"reginald1.2", ""},
	{"reginald1.2.0", "1.2.0"},
	{"reginald1.2.3-456", "1.2.3-456"},
	{"reginald1.2.3-456.789", "1.2.3-456.789"},
	{"reginald1.2.3-456-789", "1.2.3-456-789"},
	{"reginald1.2.3-456a", "1.2.3-456a"},
	{"reginald1.2.3-pre", "1.2.3-pre"},
	{"reginald1.2.3-pre+meta", "1.2.3-pre"},
	{"reginald1.2.3-pre.1", "1.2.3-pre.1"},
	{"reginald1.2.3-zzz", "1.2.3-zzz"},
	{"reginald1.2.3", "1.2.3"},
	{"reginald1.2.3+meta", "1.2.3"},
	{"reginald1.2.3+meta-pre", "1.2.3"},
	{"reginald1.2.3+meta-pre.sha.256a", "1.2.3"},

	{"reggiebad", ""},
	{"reggie1-alpha.beta.gamma", ""},
	{"reggie1-pre", ""},
	{"reggie1+meta", ""},
	{"reggie1-pre+meta", ""},
	{"reggie1.2-pre", ""},
	{"reggie1.2+meta", ""},
	{"reggie1.2-pre+meta", ""},
	{"reggie1.0.0-alpha", "1.0.0-alpha"},
	{"reggie1.0.0-alpha.1", "1.0.0-alpha.1"},
	{"reggie1.0.0-alpha.beta", "1.0.0-alpha.beta"},
	{"reggie1.0.0-beta", "1.0.0-beta"},
	{"reggie1.0.0-beta.2", "1.0.0-beta.2"},
	{"reggie1.0.0-beta.11", "1.0.0-beta.11"},
	{"reggie1.0.0-rc.1", "1.0.0-rc.1"},
	{"reggie1", ""},
	{"reggie1.0", ""},
	{"reggie1.0.0", "1.0.0"},
	{"reggie1.2", ""},
	{"reggie1.2.0", "1.2.0"},
	{"reggie1.2.3-456", "1.2.3-456"},
	{"reggie1.2.3-456.789", "1.2.3-456.789"},
	{"reggie1.2.3-456-789", "1.2.3-456-789"},
	{"reggie1.2.3-456a", "1.2.3-456a"},
	{"reggie1.2.3-pre", "1.2.3-pre"},
	{"reggie1.2.3-pre+meta", "1.2.3-pre"},
	{"reggie1.2.3-pre.1", "1.2.3-pre.1"},
	{"reggie1.2.3-zzz", "1.2.3-zzz"},
	{"reggie1.2.3", "1.2.3"},
	{"reggie1.2.3+meta", "1.2.3"},
	{"reggie1.2.3+meta-pre", "1.2.3"},
	{"reggie1.2.3+meta-pre.sha.256a", "1.2.3"},
}

func TestIsValid(t *testing.T) {
	t.Parallel()

	for _, tt := range tests {
		ok := semver.IsValid(tt.in)
		if ok != (tt.out != "") {
			t.Errorf("IsValid(%q) = %v, want %v", tt.in, ok, !ok)
		}
	}
}

func TestVersionString(t *testing.T) {
	t.Parallel()

	for _, tt := range tests {
		// Don't test the cases where the versions don't parse.
		if tt.out != "" {
			v, _ := semver.Parse(tt.in)

			ok := v.String() == tt.out
			if !ok {
				t.Errorf("Version{%q}.String() = %v, want %v", tt.in, v, tt.out)
			}
		}
	}
}
