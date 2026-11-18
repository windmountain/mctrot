module SolarTimeTest exposing (suite)

import Expect
import SolarTime
import Test exposing (Test, describe, test)


{-| Roughly the walk's day, November 21, as minutes since midnight. Only
the differences matter, so times are plain minutes here.
-}
day =
    { astronomicalDawn = Just (at 5 13)
    , nauticalDawn = Just (at 5 46)
    , civilDawn = Just (at 6 19)
    , sunrise = Just (at 6 49)
    , solarNoon = at 11 52
    , sunset = Just (at 16 31)
    , civilDusk = Just (at 17 1)
    , nauticalDusk = Just (at 17 34)
    , astronomicalDusk = Just (at 18 6)
    }


at : Int -> Int -> Int
at hour minute =
    (hour * 60 + minute) * 60000


says : Int -> Int -> String -> Test
says hour minute expected =
    test (String.fromInt hour ++ ":" ++ String.padLeft 2 '0' (String.fromInt minute) ++ " is " ++ expected) <|
        \_ -> SolarTime.describe (at hour minute) day |> Expect.equal expected


suite : Test
suite =
    describe "SolarTime.describe, through November 21"
        [ says 2 0 "Night"
        , says 5 13 "Astronomical twilight"
        , says 5 50 "Nautical twilight"
        , says 6 18 "Nautical twilight"
        , says 6 19 "Civil twilight. 30 minutes before sunrise"
        , says 6 48 "Civil twilight. 1 minute before sunrise"
        , says 6 49 "Sunrise"
        , says 6 50 "1 minute after sunrise"
        , says 7 49 "60 minutes after sunrise"
        , says 7 50 "4 hours before solar noon"
        , says 10 22 "2 hours before solar noon"
        , says 10 53 "59 minutes before solar noon"
        , says 11 49 "3 minutes before solar noon"
        , says 11 50 "Solar noon"
        , says 11 52 "Solar noon"
        , says 11 54 "Solar noon"
        , says 11 55 "3 minutes after solar noon"
        , says 12 7 "15 minutes after solar noon"
        , says 12 52 "1 hour after solar noon"
        , says 15 30 "4 hours after solar noon"
        , says 15 31 "60 minutes before sunset"
        , says 16 30 "1 minute before sunset"
        , says 16 31 "Sunset"
        , says 16 32 "Civil twilight. 1 minute after sunset"
        , says 17 0 "Civil twilight. 29 minutes after sunset"
        , says 17 1 "Nautical twilight"
        , says 17 20 "Nautical twilight"
        , says 18 0 "Astronomical twilight"
        , says 18 6 "Night"
        , test "a day without sunrise or sunset is just twilight bands" <|
            \_ ->
                SolarTime.describe (at 12 0) { day | sunrise = Nothing, sunset = Nothing, civilDawn = Nothing, civilDusk = Nothing, nauticalDawn = Nothing, nauticalDusk = Nothing, astronomicalDawn = Nothing, astronomicalDusk = Nothing }
                    |> Expect.equal "Night"
        ]
