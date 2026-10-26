module SimulatedAnnealing exposing
    ( State, Config
    , init
    , step, stepN
    , isDone
    , current, currentEnergy, best, bestEnergy, temperature, iteration
    )

{-| A pure, steppable simulated annealing core.

This module never runs a loop itself. It exposes one pure function, `step`,
that advances the search by exactly one iteration. Your application decides
how to drive it: once per animation frame for a live view, in a batch for a
headless run, or one click at a time for a debugger-style walkthrough. Because
every intermediate `State` is an ordinary immutable value, it is always safe
to render, store, or compare.


# State and configuration

@docs State, Config


# Running

@docs init
@docs step, stepN
@docs isDone


# Reading the state

@docs current, currentEnergy, best, bestEnergy, temperature, iteration

-}

import Random


{-| The full state of a search in progress: the current solution and its
energy, the best solution seen so far, and enough bookkeeping (iteration
count, random seed) to take the next step deterministically.

Opaque on purpose — construct it with `init`, advance it with `step`, and
read it with the accessor functions below.

-}
type State solution
    = State
        { current : solution
        , currentEnergy : Float
        , best : solution
        , bestEnergy : Float
        , iteration : Int
        , seed : Random.Seed
        }


{-| Everything the algorithm needs to know about your problem:

  - `energy` — the cost function being minimized. Lower is better.
  - `neighbor` — given the current solution, randomly produce a nearby
    candidate to consider next.
  - `temperature` — a cooling schedule expressed as a pure function of the
    iteration count. See `SimulatedAnnealing.Schedule` for common ones.
  - `stoppingTemperature` — `isDone` reports `True` once the schedule drops
    to or below this value.

-}
type alias Config solution =
    { energy : solution -> Float
    , neighbor : solution -> Random.Generator solution
    , temperature : Int -> Float
    , stoppingTemperature : Float
    }


{-| Start a search from an initial solution and a random seed.
-}
init : Config solution -> Random.Seed -> solution -> State solution
init config seed initial =
    let
        e =
            config.energy initial
    in
    State
        { current = initial
        , currentEnergy = e
        , best = initial
        , bestEnergy = e
        , iteration = 0
        , seed = seed
        }


{-| Advance the search by one iteration: generate a neighbor, accept or
reject it according to the Metropolis criterion at the current temperature,
and update the running best.

Pure and deterministic given its inputs — the only thing that changes between
calls is the `State` you thread through.

-}
step : Config solution -> State solution -> State solution
step config (State s) =
    let
        temp =
            config.temperature s.iteration

        ( candidate, seedAfterNeighbor ) =
            Random.step (config.neighbor s.current) s.seed

        candidateEnergy =
            config.energy candidate

        delta =
            candidateEnergy - s.currentEnergy

        ( roll, seedAfterRoll ) =
            Random.step (Random.float 0 1) seedAfterNeighbor

        accepted =
            delta < 0 || roll < eulersNumber ^ (-delta / temp)

        ( newCurrent, newCurrentEnergy ) =
            if accepted then
                ( candidate, candidateEnergy )

            else
                ( s.current, s.currentEnergy )

        ( newBest, newBestEnergy ) =
            if candidateEnergy < s.bestEnergy then
                ( candidate, candidateEnergy )

            else
                ( s.best, s.bestEnergy )
    in
    State
        { current = newCurrent
        , currentEnergy = newCurrentEnergy
        , best = newBest
        , bestEnergy = newBestEnergy
        , iteration = s.iteration + 1
        , seed = seedAfterRoll
        }


{-| Euler's number, spelled out so `step` reads as the textbook
`exp(-delta / temperature)` acceptance rule without importing a whole math
module for one constant.
-}
eulersNumber : Float
eulersNumber =
    2.718281828459045


{-| Advance the search by `n` iterations in one pure pass. Useful for batching
several steps per rendered frame, or for a headless run where you only care
about the final `State`.
-}
stepN : Config solution -> Int -> State solution -> State solution
stepN config n state =
    if n <= 0 then
        state

    else
        stepN config (n - 1) (step config state)


{-| `True` once the cooling schedule has reached the configured stopping
temperature. Application code typically stops calling `step` (e.g. by
switching off a subscription) once this is `True`.
-}
isDone : Config solution -> State solution -> Bool
isDone config (State s) =
    config.temperature s.iteration <= config.stoppingTemperature


{-| The solution the search is currently sitting at (may be worse than
`best` — that's the point of annealing).
-}
current : State solution -> solution
current (State s) =
    s.current


{-| The energy of `current`.
-}
currentEnergy : State solution -> Float
currentEnergy (State s) =
    s.currentEnergy


{-| The best solution found across the whole run so far.
-}
best : State solution -> solution
best (State s) =
    s.best


{-| The energy of `best`.
-}
bestEnergy : State solution -> Float
bestEnergy (State s) =
    s.bestEnergy


{-| The temperature at the current iteration, as given by the config's
cooling schedule. Handy for rendering a "temperature" readout alongside the
solution.
-}
temperature : Config solution -> State solution -> Float
temperature config (State s) =
    config.temperature s.iteration


{-| How many `step` calls have been applied so far.
-}
iteration : State solution -> Int
iteration (State s) =
    s.iteration
