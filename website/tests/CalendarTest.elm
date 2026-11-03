module CalendarTest exposing (suite)

import Calendar
import Expect
import Fuzz
import Test exposing (Test, describe, fuzz, test)


suite : Test
suite =
    describe "Calendar"
        [ describe "addDays"
            [ test "within a month" <|
                \_ -> Calendar.addDays 1 ( 2026, 11, 21 ) |> Expect.equal ( 2026, 11, 22 )
            , test "across a month end" <|
                \_ -> Calendar.addDays 1 ( 2026, 11, 30 ) |> Expect.equal ( 2026, 12, 1 )
            , test "across a year end" <|
                \_ -> Calendar.addDays 1 ( 2026, 12, 31 ) |> Expect.equal ( 2027, 1, 1 )
            , test "into a leap day" <|
                \_ -> Calendar.addDays 1 ( 2028, 2, 28 ) |> Expect.equal ( 2028, 2, 29 )
            , test "past a non-leap February" <|
                \_ -> Calendar.addDays 1 ( 2100, 2, 28 ) |> Expect.equal ( 2100, 3, 1 )
            , fuzz (Fuzz.intRange -2000 2000) "there and back again" <|
                \n -> Calendar.addDays n ( 2026, 11, 21 ) |> Calendar.addDays -n |> Expect.equal ( 2026, 11, 21 )
            ]
        , test "formatLong" <|
            \_ -> Calendar.formatLong ( 2026, 11, 21 ) |> Expect.equal "Saturday, November 21, 2026"
        , test "formatShort" <|
            \_ -> Calendar.formatShort ( 2026, 11, 22 ) |> Expect.equal "Sun Nov 22"
        ]
