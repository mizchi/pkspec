package executor

import "testing"

func TestIterationSeedUint32AcceptsUint32Range(t *testing.T) {
	cases := []struct {
		name string
		in   int
		want uint32
	}{
		{"zero", 0, 0},
		{"max", 4294967295, 4294967295},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := iterationSeedUint32(c.in)
			if err != nil {
				t.Fatalf("iterationSeedUint32(%d) returned error: %v", c.in, err)
			}
			if got != c.want {
				t.Fatalf("iterationSeedUint32(%d) = %d, want %d", c.in, got, c.want)
			}
		})
	}
}

func TestIterationSeedUint32RejectsOutOfRange(t *testing.T) {
	cases := []int{-1, 4294967296}
	for _, c := range cases {
		if _, err := iterationSeedUint32(c); err == nil {
			t.Fatalf("iterationSeedUint32(%d) returned nil error", c)
		}
	}
}
