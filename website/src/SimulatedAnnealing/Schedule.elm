module SimulatedAnnealing.Schedule exposing (exponential, linear, logarithmic)

{-| Common cooling schedules, ready to plug into `Config.temperature`.

Each one is just an `Int -> Float`, so writing your own is a one-liner if
these don't fit — there's nothing more to the interface than that.

@docs exponential, linear, logarithmic

-}


{-| The most common schedule: temperature decays by a constant multiplicative
factor `alpha` (typically 0.90-0.999) every iteration. Slower decay (alpha
closer to 1) explores more before settling.

    exponential { initial = 100, alpha = 0.995 } 0 == 100
    exponential { initial = 100, alpha = 0.995 } 100 == 100 * 0.995 ^ 100

-}
exponential : { initial : Float, alpha : Float } -> Int -> Float
exponential { initial, alpha } iteration =
    initial * alpha ^ toFloat iteration


{-| Temperature decreases by a fixed amount each iteration until it would go
negative, at which point it holds at 0. Simple, but tends to spend too little
time at low temperatures compared to exponential decay.
-}
linear : { initial : Float, step : Float } -> Int -> Float
linear { initial, step } iteration =
    max 0 (initial - step * toFloat iteration)


{-| Decays proportionally to `1 / log(iteration)`. Theoretically guarantees
convergence to a global optimum given infinite time, but is far slower in
practice than `exponential` — mostly useful as a baseline for comparison.
-}
logarithmic : { initial : Float } -> Int -> Float
logarithmic { initial } iteration =
    initial / logBase 2 (toFloat iteration + 2)
