package calc

import "testing"

func TestAdd(t *testing.T) {
	if Add(1, 2) != 3 {
		t.Fatalf("want 3")
	}
}

func TestSub(t *testing.T) {}
