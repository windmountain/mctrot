module SnapToStreetsTest exposing (suite)

import Expect
import SnapToStreets
import Test exposing (Test, describe, test)


{-| Two blocks side by side: a street along y = 0 from x = 0 to 200, one
along y = 100 from 100 to 200, and cross streets at x = 100 and x = 200.
-}
blocks : SnapToStreets.Network
blocks =
    SnapToStreets.fromPath "M 0 0 l 100 0 l 100 0 M 100 0 l 0 100 M 200 0 l 0 100 M 100 100 l 100 0"


{-| Two long parallel streets 50 feet apart, joined only at their far end.
-}
parallel : SnapToStreets.Network
parallel =
    SnapToStreets.fromPath "M 0 0 l 1000 0 M 0 50 l 1000 0 M 1000 0 l 0 50"


suite : Test
suite =
    describe "SnapToStreets.snap"
        [ test "a fix near a street moves onto it" <|
            \_ ->
                SnapToStreets.snap blocks [ ( 50, 10 ) ]
                    |> Expect.equal [ ( 50, 0 ) ]
        , test "from one street to another, the line turns the corner" <|
            \_ ->
                SnapToStreets.snap blocks [ ( 50, 5 ), ( 105, 50 ) ]
                    |> Expect.equal [ ( 50, 0 ), ( 100, 0 ), ( 100, 50 ) ]
        , test "around the block, the shortest way" <|
            \_ ->
                SnapToStreets.snap blocks [ ( 150, -5 ), ( 150, 105 ) ]
                    |> Expect.equal [ ( 150, 0 ), ( 100, 0 ), ( 100, 100 ), ( 150, 100 ) ]
        , test "a fix far from any street stays where it is, joined straight" <|
            \_ ->
                SnapToStreets.snap blocks [ ( 50, 5 ), ( 50, 1000 ) ]
                    |> Expect.equal [ ( 50, 0 ), ( 50, 1000 ) ]
        , test "a way along the streets far longer than the gap is drawn straight" <|
            \_ ->
                SnapToStreets.snap parallel [ ( 0, 5 ), ( 0, 45 ) ]
                    |> Expect.equal [ ( 0, 0 ), ( 0, 50 ) ]
        , test "out to a side street and straight back: the spike is dropped" <|
            \_ ->
                SnapToStreets.snap blocks [ ( 50, 5 ), ( 103, 20 ), ( 150, -3 ) ]
                    |> Expect.equal [ ( 50, 0 ), ( 100, 0 ), ( 150, 0 ) ]
        , test "along one street, just the points" <|
            \_ ->
                SnapToStreets.snap parallel [ ( 10, 3 ), ( 500, -4 ), ( 900, 2 ) ]
                    |> Expect.equal [ ( 10, 0 ), ( 500, 0 ), ( 900, 0 ) ]
        ]
