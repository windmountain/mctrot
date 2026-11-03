module LinkTest exposing (suite)

import Expect
import Link
import Test exposing (Test, describe, test)


defaults : Link.Settings
defaults =
    { date = "2026-11-21"
    , minutes = 5 * 60
    , pace = 20
    , stop = 5
    , seed = 1
    , from = Just 0
    , to = Just 2
    }


suite : Test
suite =
    describe "Link"
        [ test "writes every parameter, cities as location ids" <|
            \_ ->
                Link.toQuery defaults
                    |> Expect.equal "?date=2026-11-21&start=05:00&pace=20&stop=5&seed=1&from=1&to=4"
        , test "writes flexible cities as any, fractional paces as decimals" <|
            \_ ->
                Link.toQuery { defaults | from = Nothing, to = Nothing, pace = 17.5 }
                    |> Expect.equal "?date=2026-11-21&start=05:00&pace=17.5&stop=5&seed=1&from=any&to=any"
        , test "round-trips" <|
            \_ ->
                let
                    settings =
                        { date = "2027-01-02", minutes = 23 * 60 + 59, pace = 12.5, stop = 0, seed = -7, from = Nothing, to = Just 2 }
                in
                Link.fromQuery defaults
                    [ ( "date", "2027-01-02" ), ( "start", "23:59" ), ( "pace", "12.5" ), ( "stop", "0" ), ( "seed", "-7" ), ( "from", "any" ), ( "to", "4" ) ]
                    |> Expect.equal (Just settings)
        , test "is Nothing without any of its parameters" <|
            \_ -> Link.fromQuery defaults [ ( "utm_source", "x" ) ] |> Expect.equal Nothing
        , test "fills missing parameters from the defaults" <|
            \_ -> Link.fromQuery defaults [ ( "seed", "42" ) ] |> Expect.equal (Just { defaults | seed = 42 })
        , test "falls back to the defaults for invalid values" <|
            \_ ->
                Link.fromQuery defaults
                    [ ( "date", "2026-02-30" ), ( "start", "25:00" ), ( "pace", "0" ), ( "stop", "-1" ), ( "seed", "x" ), ( "from", "3" ), ( "to", "" ) ]
                    |> Expect.equal (Just defaults)
        ]
