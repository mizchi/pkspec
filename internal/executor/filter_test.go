package executor

import "testing"

func TestMatchesAny(t *testing.T) {
	cases := []struct {
		name     string
		input    string
		patterns []string
		want     bool
	}{
		{"empty patterns matches everything", "foo", nil, true},
		{"empty patterns slice matches everything", "foo", []string{}, true},
		{"single substring hits", "login_redirect", []string{"login"}, true},
		{"single substring misses", "logout_flow", []string{"login"}, false},
		{"any of multiple hits", "logout_flow", []string{"login", "logout"}, true},
		{"none of multiple hits", "ping", []string{"login", "logout"}, false},
		{"case sensitive", "Login", []string{"login"}, false},
		{"empty name with non-empty pattern", "", []string{"x"}, false},
		{"substring at start", "abcdef", []string{"abc"}, true},
		{"substring at end", "abcdef", []string{"def"}, true},
		{"substring in middle", "abcdef", []string{"cd"}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := matchesAny(c.input, c.patterns)
			if got != c.want {
				t.Fatalf("matchesAny(%q, %v) = %v, want %v", c.input, c.patterns, got, c.want)
			}
		})
	}
}
