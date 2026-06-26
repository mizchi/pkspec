pub fn add(a : Int, b : Int) -> Int {
  a + b
}

test "adds one" {
  if add(1, 2) != 3 {
    fail("nope")
  }
}

test "adds two" {
  assert_eq(add(2, 2), 4)
}
