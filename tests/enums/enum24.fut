-- Matches on records 2.
-- ==
-- input { }
-- output { 2 }

type foobar = {foo : i32, bar: i32}

let main : i32 = match ({foo = 1, bar = 2} : foobar)
                  case {foo = 3, bar = 4} -> 9
                  case {foo = 5, bar = 6} -> 10
                  case {foo = 7, bar = 8} -> 11
                  case {foo = 1, bar = x} -> x