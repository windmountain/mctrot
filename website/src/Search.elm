module Search exposing (..)

{-| What a McTrot route search is: the problem (real walking distances and
opening hours, walked from a start time at a pace), a tour's score (total
minutes, waits included; see `simulate`), and the annealing that searches
for a good one. Shared by the simulator, which runs one search a frame at a
time, and the landscape page's workers (see `LandscapeWorker`), which run
many to completion. Both start a search with `start`, so the same settings
and seed find the same route on either page.
-}

import Array
import Calendar
import List.Extra
import McdData exposing (cities, distanceMeters)
import MctrotMapData
import Random
import SimulatedAnnealing exposing (Config, State)
import SimulatedAnnealing.Schedule as Schedule



-- ANNEALING
--
-- These change what the search finds (see `config`).


{-| Starting temperature of the cooling schedule, in the same units as the
energy (minutes of total route time).
-}
initialTemperature : Float
initialTemperature =
    400


{-| Per-step multiplier on the temperature. Closer to 1 cools more slowly,
so the search runs more steps before stopping.
-}
coolingRate : Float
coolingRate =
    0.99995


{-| `isDone` reports `True` once the temperature drops to or below this.
-}
stoppingTemperature : Float
stoppingTemperature =
    0.05




-- PROBLEM DEFINITION


metersPerMile : Float
metersPerMile =
    1609.344


{-| Parses the value of the pace `<input type="number">` (minutes per
mile). Falls back to a brisk-walk pace if the field is ever empty,
non-numeric, or non-positive.
-}
parseMinutesPerMile : String -> Float
parseMinutesPerMile raw =
    case String.toFloat raw of
        Just minutesPerMile ->
            if minutesPerMile > 0 then
                minutesPerMile

            else
                defaultMinutesPerMile

        Nothing ->
            defaultMinutesPerMile


defaultMinutesPerMile : Float
defaultMinutesPerMile =
    20


{-| Parses the value of the stop time `<input type="number">` (whole
minutes spent at each location). Falls back to the default if the field is
ever empty, non-numeric, or negative.
-}
parseStopMinutes : String -> Int
parseStopMinutes raw =
    case String.toInt raw of
        Just minutes ->
            if minutes >= 0 then
                minutes

            else
                defaultStopMinutes

        Nothing ->
            defaultStopMinutes


defaultStopMinutes : Int
defaultStopMinutes =
    5


metersPerMinuteFromPace : Float -> Float
metersPerMinuteFromPace minutesPerMile =
    metersPerMile / minutesPerMile


{-| `metersPerMinute` is derived from the pace picker (minutes/mile) rather
than passed as a speed directly, since "minutes per mile" is what the UI
asks for — this is the one place that conversion happens, everything else
just uses the resulting rate.
-}
travelTime : Float -> Int -> Int -> Int
travelTime metersPerMinute from to =
    distanceMeters
        |> Array.get from
        |> Maybe.andThen (Array.get to)
        |> Maybe.withDefault 0
        |> toFloat
        |> (\meters -> meters / metersPerMinute)
        |> round


{-| Every city index, north to south along the street grid
(`MctrotMapData.locationCoords` is already rotated so the grid runs
vertically, with y growing southward). Orders the start/end pickers and
gives their defaults: the northernmost start and the southernmost end.
-}
northToSouth : List Int
northToSouth =
    List.range 0 (Array.length cities - 1)
        |> List.sortBy (\i -> Array.get i MctrotMapData.locationCoords |> Maybe.map Tuple.second |> Maybe.withDefault 0)


{-| Parses the value of an `<input type="time">` ("HH:MM") into minutes
since midnight. Falls back to 6:00 AM if the field is ever empty or
malformed.
-}
parseStartMinutes : String -> Int
parseStartMinutes timeOfDay =
    case String.split ":" timeOfDay |> List.map String.toInt of
        [ Just hh, Just mm ] ->
            hh * 60 + mm

        _ ->
            6 * 60


{-| Parses the value of the seed text input into the `Int` `Random.initialSeed`
needs. Falls back to 0 if the field is ever empty or non-numeric.
-}
parseSeed : String -> Int
parseSeed raw =
    String.toInt raw |> Maybe.withDefault 0


{-| Turns the value of an `<input type="date">` ("YYYY-MM-DD") into a
Monday-indexed 0..6 weekday — matching the order each
city's weekly hours are listed in (Mon..Sun) — for feeding into
`weekMinute`. Falls back to Monday if the date is invalid.
-}
mondayIndexedWeekday : String -> Int
mondayIndexedWeekday isoDate =
    Calendar.parseDate isoDate
        |> Maybe.map (\( year, month, day ) -> modBy 7 (Calendar.sakamotoWeekday year month day + 6))
        |> Maybe.withDefault 0


dayLength : Int
dayLength =
    24 * 60


weekLength : Int
weekLength =
    7 * dayLength


{-| The conditions a run is pinned to: which day of the week it begins on
(Monday-indexed, 0..6) and the calendar date that is (`Nothing` if the
date input is invalid; only the printout uses it), what time of day, how fast travel between stops
is, how long is spent at each stop, and which locations (if any) the
route must start and end at (`Nothing` = flexible). Bundled together because they're
all snapshotted at the same moment — when a search (re)starts — so the
energy function stays fixed for the life of that search.
-}
type alias StartTime =
    { weekday : Int
    , date : Maybe Calendar.Date
    , minutes : Int
    , metersPerMinute : Float
    , stopMinutes : Int
    , startCity : Maybe Int
    , endCity : Maybe Int
    }


{-| Parses a start/end `<select>` value: a city index, or "" for flexible.
-}
parseCity : String -> Maybe Int
parseCity raw =
    String.toInt raw


{-| `arrival` is minutes elapsed since the tour began; this converts that
into "minutes since Monday 00:00" in the repeating weekly cycle each city's
`openWindows`/`closedWindows` are expressed in.
-}
weekMinute : StartTime -> Int -> Int
weekMinute startTime arrival =
    modBy weekLength (startTime.weekday * dayLength + startTime.minutes + arrival)


{-| Minutes to wait if you arrive at a city with the given open windows
(minutes-since-Monday-00:00) at `arrival` minutes into the tour. 0 if
already open. A city with no closed windows (open 24/7) is always open.
-}
waitForCity : List ( Int, Int ) -> StartTime -> Int -> Int
waitForCity openWindows startTime arrival =
    let
        wm =
            weekMinute startTime arrival

        isOpenNow =
            List.any (\( s, e ) -> wm >= s && wm < e) openWindows
    in
    if isOpenNow then
        0

    else
        openWindows
            |> List.map (\( s, _ ) -> modBy weekLength (s - wm))
            |> List.minimum
            |> Maybe.withDefault 0



-- SOLUTION: a tour is a permutation of every city index that isn't a fixed
-- start or end, visited in order; `stops` puts the fixed ones (if any)
-- around it.


type alias Tour =
    List Int


{-| `departure` is `arrival + wait + stopMinutes`: the stop starts once the
restaurant is open.
-}
type alias Visit =
    { cityIndex : Int
    , arrival : Int
    , wait : Int
    , departure : Int
    }


{-| The full visiting order: the fixed start (if any), the tour, then the
fixed end (if any). If start and end are the same location, it's a round
trip and that location appears at both ends.
-}
stops : StartTime -> Tour -> List Int
stops startTime tour =
    List.filterMap identity [ startTime.startCity ] ++ tour ++ List.filterMap identity [ startTime.endCity ]


{-| Walk the `stops` in order starting at `startTime`, carrying the clock
forward leg by leg. This is why the energy function can't just sum edge
weights: whether (and how long) you wait at a city depends on the
accumulated time — and now the day of the week — when you get there, not
on the edge alone. Every stop, including the first and the finish, adds
`startTime.stopMinutes`.
-}
simulate : StartTime -> Tour -> List Visit
simulate startTime tour =
    case stops startTime tour of
        [] ->
            []

        first :: rest ->
            let
                firstWait =
                    waitForCity (openWindowsFor first) startTime 0

                firstVisit =
                    { cityIndex = first, arrival = startTime.minutes, wait = firstWait, departure = startTime.minutes + firstWait + startTime.stopMinutes }

                visitCity ( prevCity, clock, visits ) cityIndex =
                    let
                        arrival =
                            clock + travelTime startTime.metersPerMinute prevCity cityIndex

                        wait =
                            waitForCity (openWindowsFor cityIndex) startTime (arrival - startTime.minutes)

                        departure =
                            arrival + wait + startTime.stopMinutes
                    in
                    ( cityIndex, departure, { cityIndex = cityIndex, arrival = arrival, wait = wait, departure = departure } :: visits )

                ( _, _, reversedVisits ) =
                    List.foldl (\c acc -> visitCity acc c) ( first, firstVisit.departure, [] ) rest
            in
            firstVisit :: List.reverse reversedVisits


openWindowsFor : Int -> List ( Int, Int )
openWindowsFor cityIndex =
    Array.get cityIndex cities |> Maybe.map .openWindows |> Maybe.withDefault [ ( 0, weekLength ) ]


totalMinutes : StartTime -> Tour -> Int
totalMinutes startTime tour =
    simulate startTime tour
        |> List.Extra.last
        |> Maybe.map (\v -> v.departure - startTime.minutes)
        |> Maybe.withDefault 0


{-| Road distance for the full route (see `stops`), in meters — unlike
`totalMinutes`, this doesn't depend on pace or waiting.
-}
totalDistanceMeters : StartTime -> Tour -> Int
totalDistanceMeters startTime tour =
    let
        route =
            stops startTime tour
    in
    List.map2 distanceBetween route (List.drop 1 route) |> List.sum


{-| Reverse a random contiguous segment of the visiting order — a 2-opt move
over the stops between any fixed start and end.
-}
twoOptNeighbor : Tour -> Random.Generator Tour
twoOptNeighbor tour =
    let
        n =
            List.length tour
    in
    Random.pair (Random.int 0 (n - 1)) (Random.int 0 (n - 1))
        |> Random.map
            (\( i, j ) ->
                let
                    lo =
                        min i j

                    hi =
                        max i j
                in
                if lo == hi then
                    tour

                else
                    let
                        ( before, rest ) =
                            List.Extra.splitAt lo tour

                        ( middle, after ) =
                            List.Extra.splitAt (hi - lo + 1) rest
                    in
                    before ++ List.reverse middle ++ after
            )


config : StartTime -> Config Tour
config startTime =
    { energy = toFloat << totalMinutes startTime
    , neighbor = twoOptNeighbor
    , temperature = Schedule.exponential { initial = initialTemperature, alpha = coolingRate }
    , stoppingTemperature = stoppingTemperature
    }


initialTour : StartTime -> Tour
initialTour startTime =
    List.range 0 (Array.length cities - 1)
        |> List.filter (\i -> Just i /= startTime.startCity && Just i /= startTime.endCity)



distanceBetween : Int -> Int -> Int
distanceBetween from to =
    distanceMeters
        |> Array.get from
        |> Maybe.andThen (Array.get to)
        |> Maybe.withDefault 0


formatDuration : Int -> String
formatDuration minutes =
    String.fromInt (minutes // 60) ++ "h " ++ String.fromInt (modBy 60 minutes) ++ "m"


formatMiles : Int -> String
formatMiles meters =
    let
        tenths =
            round (toFloat meters / metersPerMile * 10)
    in
    String.fromInt (tenths // 10) ++ "." ++ String.fromInt (modBy 10 tenths) ++ " mi"


{-| A fresh search for `startTime`, from `seed`.
-}
start : StartTime -> Int -> State Tour
start startTime seed =
    SimulatedAnnealing.init (config startTime) (Random.initialSeed seed) (initialTour startTime)


{-| Steps per chunk: a search only checks whether it's done (and the
simulator, the clock) between chunks, so a search always ends on a whole
chunk, slightly past `stoppingTemperature`. Changing this changes which
route a given seed finds.
-}
stepsPerChunk : Int
stepsPerChunk =
    100


{-| Runs a search to the end, a chunk at a time, exactly as the simulator
does across frames.
-}
finish : StartTime -> State Tour -> State Tour
finish startTime state =
    if SimulatedAnnealing.isDone (config startTime) state then
        state

    else
        finish startTime (SimulatedAnnealing.stepN (config startTime) stepsPerChunk state)


{-| Minutes since some midnight as a 12-hour time of day: "2:05 AM".
-}
formatClock : Int -> String
formatClock minutes =
    let
        minuteOfDay =
            modBy dayLength minutes

        hour =
            minuteOfDay // 60
    in
    String.fromInt (modBy 12 (hour + 11) + 1)
        ++ ":"
        ++ String.padLeft 2 '0' (String.fromInt (modBy 60 minuteOfDay))
        ++ (if hour < 12 then
                " AM"

            else
                " PM"
           )
