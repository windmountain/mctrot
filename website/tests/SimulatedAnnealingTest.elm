module SimulatedAnnealingTest exposing (suite)

import Expect
import Fuzz exposing (Fuzzer)
import Random
import SimulatedAnnealing exposing (Config, State)
import SimulatedAnnealing.Schedule as Schedule
import Test exposing (Test, describe, fuzz, test)


{-| A minimal test problem: solutions are floats, energy is distance from
zero, and a neighbor is a random nudge. Good enough to exercise the
algorithm's bookkeeping without pulling in a whole TSP setup.
-}
config : Config Float
config =
    { energy = abs
    , neighbor = \x -> Random.map (\delta -> x + delta) (Random.float -1 1)
    , temperature = Schedule.exponential { initial = 50, alpha = 0.99 }
    , stoppingTemperature = 0.01
    }


seedFuzzer : Fuzzer Random.Seed
seedFuzzer =
    Fuzz.map Random.initialSeed (Fuzz.intRange 0 1000000)


suite : Test
suite =
    describe "SimulatedAnnealing"
        [ fuzz seedFuzzer "is deterministic given the same seed" <|
            \seed ->
                let
                    run () =
                        SimulatedAnnealing.stepN config 200 (SimulatedAnnealing.init config seed 10.0)

                    a =
                        run ()

                    b =
                        run ()
                in
                Expect.all
                    [ \_ -> Expect.within (Expect.Absolute 0.000001) (SimulatedAnnealing.current a) (SimulatedAnnealing.current b)
                    , \_ -> Expect.within (Expect.Absolute 0.000001) (SimulatedAnnealing.best a) (SimulatedAnnealing.best b)
                    , \_ -> Expect.equal (SimulatedAnnealing.iteration a) (SimulatedAnnealing.iteration b)
                    ]
                    ()
        , fuzz seedFuzzer "stepN n is equivalent to n calls to step" <|
            \seed ->
                let
                    initial =
                        SimulatedAnnealing.init config seed 10.0

                    viaStepN =
                        SimulatedAnnealing.stepN config 30 initial

                    viaStep =
                        List.foldl (\_ s -> SimulatedAnnealing.step config s) initial (List.range 1 30)
                in
                Expect.within (Expect.Absolute 0.000001) (SimulatedAnnealing.current viaStepN) (SimulatedAnnealing.current viaStep)
        , fuzz seedFuzzer "iteration count advances by exactly one per step" <|
            \seed ->
                let
                    initial =
                        SimulatedAnnealing.init config seed 10.0

                    after =
                        SimulatedAnnealing.step config initial
                in
                Expect.equal (SimulatedAnnealing.iteration after) (SimulatedAnnealing.iteration initial + 1)
        , fuzz seedFuzzer "best energy never increases across a run" <|
            \seed ->
                let
                    states =
                        List.range 0 100
                            |> List.foldl
                                (\_ acc -> SimulatedAnnealing.step config (List.head acc |> Maybe.withDefault (SimulatedAnnealing.init config seed 10.0)) :: acc)
                                [ SimulatedAnnealing.init config seed 10.0 ]
                            |> List.reverse

                    bestEnergies =
                        List.map SimulatedAnnealing.bestEnergy states
                in
                bestEnergies
                    |> List.foldl
                        (\energy ( ok, previous ) -> ( ok && energy <= previous, energy ))
                        ( True, 1 / 0 )
                    |> Tuple.first
                    |> Expect.equal True
        , fuzz seedFuzzer "best is never worse than the energy it reports" <|
            \seed ->
                let
                    finalState =
                        SimulatedAnnealing.stepN config 50 (SimulatedAnnealing.init config seed 10.0)
                in
                Expect.within (Expect.Absolute 0.000001)
                    (config.energy (SimulatedAnnealing.best finalState))
                    (SimulatedAnnealing.bestEnergy finalState)
        , test "isDone reflects the configured stopping temperature" <|
            \_ ->
                let
                    seed =
                        Random.initialSeed 42

                    farFromDone =
                        SimulatedAnnealing.init config seed 10.0

                    wellCooled =
                        SimulatedAnnealing.stepN config 5000 farFromDone
                in
                Expect.all
                    [ \_ -> Expect.equal (SimulatedAnnealing.isDone config farFromDone) False
                    , \_ -> Expect.equal (SimulatedAnnealing.isDone config wellCooled) True
                    ]
                    ()
        ]
