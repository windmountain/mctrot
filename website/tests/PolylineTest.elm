module PolylineTest exposing (suite)

import Expect
import Polyline
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Polyline.decode"
        [ test "Google's documented example" <|
            \_ ->
                Polyline.decode "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
                    |> Expect.equal [ ( 38.5, -120.2 ), ( 40.7, -120.95 ), ( 43.252, -126.453 ) ]
        , test "empty" <|
            \_ -> Polyline.decode "" |> Expect.equal []
        ]
