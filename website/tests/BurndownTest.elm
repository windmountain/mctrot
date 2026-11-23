module BurndownTest exposing (suite)

import Burndown
import Expect
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Burndown"
        [ describe "steps"
            [ test "a staircase: all left, one fewer at each time, held to the end" <|
                \_ ->
                    Burndown.steps 3 0 100 [ 50, 20 ]
                        |> Expect.equal [ ( 0, 3 ), ( 20, 3 ), ( 20, 2 ), ( 50, 2 ), ( 50, 1 ), ( 100, 1 ) ]
            , test "times before the start are already done; times after the end don't count" <|
                \_ ->
                    Burndown.steps 5 10 100 [ 5, 50, 200 ]
                        |> Expect.equal [ ( 10, 4 ), ( 50, 4 ), ( 50, 3 ), ( 100, 3 ) ]
            , test "nothing done: flat" <|
                \_ ->
                    Burndown.steps 46 0 100 []
                        |> Expect.equal [ ( 0, 46 ), ( 100, 46 ) ]
            ]
        , describe "window"
            [ test "the plan's first arrival to its last departure" <|
                \_ ->
                    Burndown.window { plan = [ 300, 100, 200 ], planEnd = 400, visits = [], total = 3, now = 0, until = Nothing }
                        |> Expect.equal (Just ( 100, 400 ))
            , test "on to now when the walk runs over" <|
                \_ ->
                    Burndown.window { plan = [ 100 ], planEnd = 400, visits = [], total = 1, now = 500, until = Nothing }
                        |> Expect.equal (Just ( 100, 500 ))
            , test "but not to a now days later" <|
                \_ ->
                    Burndown.window { plan = [ 100 ], planEnd = 400, visits = [], total = 1, now = 100 + 2 * 86400000, until = Nothing }
                        |> Expect.equal (Just ( 100, 400 ))
            , test "no plan, no chart" <|
                \_ ->
                    Burndown.window { plan = [], planEnd = 0, visits = [], total = 0, now = 0, until = Nothing }
                        |> Expect.equal Nothing
            ]
        ]
