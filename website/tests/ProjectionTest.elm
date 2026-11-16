module ProjectionTest exposing (suite)

import Array
import Expect
import McdData
import MctrotMapData
import Projection
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Projection.toMap"
        [ test "places every McDonald's on its dot in the map (within 1 ft)" <|
            \_ ->
                let
                    misses =
                        List.map2
                            (\city ( x, y ) ->
                                let
                                    ( px, py ) =
                                        Projection.toMap { lat = city.lat, lon = city.lon }
                                in
                                ( city.name, sqrt ((px - x) ^ 2 + (py - y) ^ 2) )
                            )
                            (Array.toList McdData.cities)
                            (Array.toList MctrotMapData.locationCoords)
                            |> List.filter (\( _, feet ) -> feet > 1)
                in
                Expect.equal [] misses
        , test "compares all 46 locations" <|
            \_ ->
                Expect.equal 46 (Array.length McdData.cities)
        ]
