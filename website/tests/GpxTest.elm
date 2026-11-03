module GpxTest exposing (suite)

import Dict
import Expect
import Gpx
import Test exposing (Test, describe, test)


{-| Three stops, A (mcd 1) → B (mcd 3) → C (mcd 2). Leg "1-3" runs A→B as
stored; leg "2-3" runs C→B, so it's walked backwards. Both meet at B
(40.001, -73.9).
-}
route : Gpx.Route
route =
    { name = "McTrot route"
    , date = Just ( 2026, 11, 21 )
    , legs =
        Dict.fromList
            [ ( "1-3", "_ocsF~q`bMgE?" ) -- (40.000, -73.9) → (40.001, -73.9)
            , ( "2-3", "o{csF~q`bMfE?" ) -- (40.002, -73.9) → (40.001, -73.9)
            ]
    , stops =
        [ { mcdId = 1, name = "A", desc = "1 Main St", lat = 40.0, lon = -73.9, arrival = 120 }
        , { mcdId = 3, name = "B&H", desc = "2 Main St · arrive <late>", lat = 40.001, lon = -73.9, arrival = 130 }
        , { mcdId = 2, name = "C", desc = "3 Main St", lat = 40.002, lon = -73.9, arrival = 22 * 60 + 30 }
        ]
    }


gpx : String
gpx =
    Gpx.build route


suite : Test
suite =
    describe "Gpx.build"
        [ test "one waypoint per stop, in order" <|
            \_ ->
                String.indexes "<wpt " gpx
                    |> List.length
                    |> Expect.equal 3
        , test "waypoints are in visiting order" <|
            \_ ->
                List.map (\n -> String.indexes ("<name>" ++ n ++ "</name>") gpx) [ "A", "B&amp;H", "C" ]
                    |> List.concat
                    |> (\is -> Expect.equal (List.sort is) is)
        , test "track joins the legs, the second turned around, sharing B once" <|
            \_ ->
                String.indexes "<trkpt " gpx
                    |> List.map (\i -> String.slice (i + 12) (i + 20) gpx)
                    |> Expect.equal [ "40.00000", "40.00100", "40.00200" ]
        , test "text is escaped" <|
            \_ ->
                Expect.all
                    [ \g -> String.contains "<name>B&amp;H</name>" g |> Expect.equal True
                    , \g -> String.contains "arrive &lt;late&gt;" g |> Expect.equal True
                    ]
                    gpx
        , test "times are UTC instants, across midnight" <|
            \_ ->
                Expect.all
                    [ \g -> String.contains "<time>2026-11-21T07:00:00Z</time><name>A</name>" g |> Expect.equal True
                    , \g -> String.contains "<time>2026-11-22T03:30:00Z</time><name>C</name>" g |> Expect.equal True
                    ]
                    gpx
        , test "no times without a date" <|
            \_ ->
                Gpx.build { route | date = Nothing }
                    |> String.contains "<time>"
                    |> Expect.equal False
        , test "legKey puts the lower id first" <|
            \_ -> Gpx.legKey 17 3 |> Expect.equal "3-17"
        ]
