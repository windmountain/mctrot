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
        , describe "newYorkUtcOffset"
            -- 2026: daylight time from Sun Mar 8 to Sun Nov 1, 2:00 AM.
            [ test "winter" <|
                \_ -> Calendar.newYorkUtcOffset ( 2026, 11, 21 ) 120 |> Expect.equal -300
            , test "summer" <|
                \_ -> Calendar.newYorkUtcOffset ( 2026, 7, 4 ) 720 |> Expect.equal -240
            , test "just before spring forward" <|
                \_ -> Calendar.newYorkUtcOffset ( 2026, 3, 8 ) 119 |> Expect.equal -300
            , test "at spring forward" <|
                \_ -> Calendar.newYorkUtcOffset ( 2026, 3, 8 ) 120 |> Expect.equal -240
            , test "just before fall back" <|
                \_ -> Calendar.newYorkUtcOffset ( 2026, 11, 1 ) 119 |> Expect.equal -240
            , test "at fall back" <|
                \_ -> Calendar.newYorkUtcOffset ( 2026, 11, 1 ) 120 |> Expect.equal -300
            , test "second Sunday when the 1st isn't a Sunday (2027: Mar 14)" <|
                \_ ->
                    ( Calendar.newYorkUtcOffset ( 2027, 3, 13 ) 720, Calendar.newYorkUtcOffset ( 2027, 3, 14 ) 720 )
                        |> Expect.equal ( -300, -240 )
            ]
        , describe "isoUtcFromNewYork"
            [ test "winter morning" <|
                \_ -> Calendar.isoUtcFromNewYork ( 2026, 11, 21 ) 120 |> Expect.equal "2026-11-21T07:00:00Z"
            , test "evening rolls into the next UTC day" <|
                \_ -> Calendar.isoUtcFromNewYork ( 2026, 11, 21 ) (22 * 60 + 30) |> Expect.equal "2026-11-22T03:30:00Z"
            , test "minutes past a day count from the start date" <|
                \_ -> Calendar.isoUtcFromNewYork ( 2026, 11, 21 ) (1440 + 60) |> Expect.equal "2026-11-22T06:00:00Z"
            , test "summer" <|
                \_ -> Calendar.isoUtcFromNewYork ( 2026, 7, 4 ) 0 |> Expect.equal "2026-07-04T04:00:00Z"
            , test "across a year end" <|
                \_ -> Calendar.isoUtcFromNewYork ( 2026, 12, 31 ) (23 * 60) |> Expect.equal "2027-01-01T04:00:00Z"
            ]
        ]
