package executor

import "testing"

// TestXorshift32MatchesPkl pins the seed sequence the Go executor
// generates against the values pkl/QuickCheck.pkl's `seedAt`
// produces. Pkl test fixtures already assert these exact values
// (experiments/12-quickcheck/QuickCheck.test.pkl:11-13), so a Go-
// side change to the algorithm now shows up as a diff against
// canonical Pkl facts too.
func TestXorshift32MatchesPkl(t *testing.T) {
	cases := []struct {
		seed  uint32
		index int
		want  uint32
	}{
		{12345, 0, 12345},
		{12345, 1, 3336926330},
		{12345, 2, 1697253807},
	}
	for _, c := range cases {
		got := c.seed
		for i := 0; i < c.index; i++ {
			got = xorshift32Step(got)
		}
		if got != c.want {
			t.Errorf("seedAt(%d, %d) = %d, want %d", c.seed, c.index, got, c.want)
		}
	}
}
