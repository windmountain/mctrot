module NewYorkTimeTest exposing (suite)

import Expect
import NewYorkTime
import Test exposing (Test, describe, test)


{-| ms since the epoch of a UTC time.
-}
utc : Int -> Int -> Int -> Int -> Int -> Int
utc year month day hour minute =
    let
        y =
            if month <= 2 then
                year - 1

            else
                year

        era =
            y // 400

        yoe =
            y - era * 400

        mp =
            modBy 12 (month + 9)

        doy =
            (153 * mp + 2) // 5 + day - 1

        days =
            era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
    in
    ((days * 24 + hour) * 60 + minute) * 60000


suite : Test
suite =
    describe "NewYorkTime"
        [ test "the McTrot start: November 21, 2026 is standard time" <|
            \_ ->
                NewYorkTime.format (utc 2026 11 21 10 34)
                    |> Expect.equal "November 21, 5:34 AM EST"
        , test "summer is daylight time" <|
            \_ ->
                NewYorkTime.format (utc 2026 7 4 16 5)
                    |> Expect.equal "July 4, 12:05 PM EDT"
        , test "midnight is 12 AM, and the date is New York's, not UTC's" <|
            \_ ->
                NewYorkTime.format (utc 2026 1 2 5 0)
                    |> Expect.equal "January 2, 12:00 AM EST"
        , test "just before midnight in New York is still the day before" <|
            \_ ->
                NewYorkTime.format (utc 2026 1 2 4 59)
                    |> Expect.equal "January 1, 11:59 PM EST"
        , test "2026: daylight time starts at 2 AM on March 8 (second Sunday)" <|
            \_ ->
                ( NewYorkTime.format (utc 2026 3 8 6 59), NewYorkTime.format (utc 2026 3 8 7 0) )
                    |> Expect.equal ( "March 8, 1:59 AM EST", "March 8, 3:00 AM EDT" )
        , test "2026: daylight time ends at 2 AM on November 1 (first Sunday)" <|
            \_ ->
                ( NewYorkTime.format (utc 2026 11 1 5 59), NewYorkTime.format (utc 2026 11 1 6 0) )
                    |> Expect.equal ( "November 1, 1:59 AM EDT", "November 1, 1:00 AM EST" )
        , test "2027: March 14 and November 7" <|
            \_ ->
                ( NewYorkTime.isDaylight (utc 2027 3 14 7 0), NewYorkTime.isDaylight (utc 2027 11 7 6 0) )
                    |> Expect.equal ( True, False )
        ]
