port module Simulator exposing (main)

{-| The interactive route simulator on simulator.html, mounted with
`Elm.Simulator.init({ node, flags: defaultStartDate })` (see `init`).

  - The energy function isn't a simple sum of edge weights — it has to walk
    the tour in order, carrying an accumulated clock forward, because
    whether you wait at a restaurant depends on when you arrive (see
    `simulate`).
  - The search's starting seed comes from a user-editable text field (see
    `SetSeedInput`, `parseSeed`), converted to a `Random.Seed` via
    `Random.initialSeed` — deterministic, so the whole search starts
    synchronously in `init`/`startSearch`, with no `Cmd`-driven randomness.

Every McDonald's location in Manhattan (as of the last scrape), named by their real nicknames and
real per-weekday hours, connected by real walking distances in meters — all
generated into `McdData` from the database by
scripts/export_simulator_data.py. This is an open path: the start and
end locations are each either picked in the UI or left "Flexible" for the
search to choose (by default it runs from the northernmost location to the
southernmost; see `stops`). Some locations are open 24 hours; the rest have real weekly
schedules — including days that are fully open, days that close at midnight,
and one or two nights that run past midnight into the next calendar day —
and arriving while closed means waiting for the next opening, which the UI's
start date picker determines (see `mondayIndexedWeekday`). Travel time between stops
is the raw distance converted at a pace the UI also asks for, in
minutes/mile (see `travelTime`).
-}

import Array exposing (Array)
import Browser
import Browser.Dom
import Browser.Events
import Calendar
import Dict exposing (Dict)
import Gpx
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Events
import Html.Lazy
import Http
import Json.Decode as Decode
import List.Extra
import McdData exposing (City, cities, distanceMeters)
import MctrotMapData
import Random
import SimulatedAnnealing exposing (Config, State)
import SimulatedAnnealing.Schedule as Schedule
import Svg exposing (Svg)
import Svg.Attributes as SvgAttr
import Task
import Time



-- TUNING
--
-- The annealing constants change what the search finds (see `config`); the
-- scheduling constants change only how fast it runs (see `runChunk`).


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


{-| How many milliseconds of each animation frame go to the search, measured
from when the frame's `Frame` message arrives. The rest of a 60 Hz frame
(~16.7 ms) is left for `view`, layout, and paint.
-}
frameBudgetMillis : Int
frameBudgetMillis =
    10


{-| Steps per chunk: the granularity at which `runChunk` checks the clock,
and so roughly how far a frame can overshoot `frameBudgetMillis`.
-}
stepsPerChunk : Int
stepsPerChunk =
    100



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
    24


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



-- MODEL


type alias Model =
    { saState : State Tour
    , running : Bool
    , startDate : String
    , startTimeOfDay : String
    , speedInput : String
    , stopInput : String
    , seedInput : String
    , startCityInput : String
    , endCityInput : String
    , activeStart : StartTime
    , tab : Tab
    , mapFit : MapFit
    , settingsOpen : Bool
    , legs : Legs
    }


{-| The walking legs for the GPX export (see `Gpx.legKey`), fetched from
geo/route-legs.json when a search starts, so it never weighs on page load.
`thenDownload` remembers a GPX request made while the fetch is in flight.
-}
type Legs
    = NotLoaded
    | Loading { thenDownload : Bool }
    | Loaded (Dict String String)
    | Failed


type Tab
    = ScheduleTab
    | MapTab


{-| How the map fills its box: `Normal` keeps its true proportions, and
`Stretch` stretches just the locations and route paths to within
`stretchPadding` of each
side (see `viewMapStatic`).
-}
type MapFit
    = Normal
    | Stretch


mapFits : List ( MapFit, String, String )
mapFits =
    [ ( Normal, "normal", "Normal" )
    , ( Stretch, "stretch", "Stretch" )
    ]


type Msg
    = Frame Time.Posix
    | ChunkDone Time.Posix Time.Posix
    | Start
    | SetStartDate String
    | SetStartTimeOfDay String
    | SetSpeedInput String
    | SetStopInput String
    | SetSeedInput String
    | SetStartCityInput String
    | SetEndCityInput String
    | SelectTab Tab
    | SetMapFit String
    | Print
    | OpenSettings
    | CloseSettings
    | NoOp
    | ExportGpx
    | GotLegs (Result Http.Error (Dict String String))


{-| (Re)starts the search from `initialTour`, snapshotting `activeStart` (see
`viewRunSettings`) and deriving the seed from `seedInput` via
`Random.initialSeed` — deterministic, so no `Cmd` round trip is needed the
way a truly random seed would require.
-}
startSearch : Model -> Model
startSearch model =
    let
        activeStart =
            { weekday = mondayIndexedWeekday model.startDate
            , date = Calendar.parseDate model.startDate
            , minutes = parseStartMinutes model.startTimeOfDay
            , metersPerMinute = metersPerMinuteFromPace (parseMinutesPerMile model.speedInput)
            , stopMinutes = parseStopMinutes model.stopInput
            , startCity = parseCity model.startCityInput
            , endCity = parseCity model.endCityInput
            }
    in
    { model
        | saState = SimulatedAnnealing.init (config activeStart) (Random.initialSeed (parseSeed model.seedInput)) (initialTour activeStart)
        , running = True
        , activeStart = activeStart
    }


{-| `defaultStartDate` is the next Nov 21 (today or later) in the visitor's
local time, as `YYYY-MM-DD`, passed in as a flag by simulator.html — the
year depends on the visitor's clock, which Elm can't read synchronously.
-}
init : String -> ( Model, Cmd Msg )
init defaultStartDate =
    let
        speedInput =
            String.fromFloat defaultMinutesPerMile

        stopInput =
            String.fromInt defaultStopMinutes

        seedInput =
            "1"

        startDate =
            defaultStartDate

        startTimeOfDay =
            "02:00"

        startCityInput =
            List.head northToSouth |> Maybe.map String.fromInt |> Maybe.withDefault ""

        endCityInput =
            List.Extra.last northToSouth |> Maybe.map String.fromInt |> Maybe.withDefault ""

        activeStart =
            { weekday = mondayIndexedWeekday startDate
            , date = Calendar.parseDate startDate
            , minutes = parseStartMinutes startTimeOfDay
            , metersPerMinute = metersPerMinuteFromPace (parseMinutesPerMile speedInput)
            , stopMinutes = parseStopMinutes stopInput
            , startCity = parseCity startCityInput
            , endCity = parseCity endCityInput
            }
    in
    ( { saState = SimulatedAnnealing.init (config activeStart) (Random.initialSeed (parseSeed seedInput)) (initialTour activeStart)
      , running = False
      , startDate = startDate
      , startTimeOfDay = startTimeOfDay
      , speedInput = speedInput
      , stopInput = stopInput
      , seedInput = seedInput
      , startCityInput = startCityInput
      , endCityInput = endCityInput
      , activeStart = activeStart
      , tab = MapTab
      , mapFit = Stretch
      , settingsOpen = False
      , legs = NotLoaded
      }
    , Cmd.none
    )



-- UPDATE


{-| Opens the browser's print dialog (see simulator.html), which prints
`viewPrintSheet` instead of the page.
-}
port print : () -> Cmd msg


{-| Hands a GPX file to simulator.html, which opens the share sheet on
touch devices that can share files (so the visitor can send it straight to
a map app) and downloads it everywhere else.
-}
port saveGpx : { filename : String, gpx : String } -> Cmd msg


searching : Model -> Bool
searching model =
    model.running && not (SimulatedAnnealing.isDone (config model.activeStart) model.saState)


{-| Advances the search one chunk, then asks for the time so `ChunkDone` can
decide whether this frame has budget for another. Elm only calls `view` once
per animation frame, so the chunks between frames don't each re-render — the
search runs at whatever rate the budget allows, independent of how expensive
the current tab is to draw.
-}
runChunk : Time.Posix -> Model -> ( Model, Cmd Msg )
runChunk frameStart model =
    ( { model | saState = SimulatedAnnealing.stepN (config model.activeStart) stepsPerChunk model.saState }
    , Task.perform (ChunkDone frameStart) Time.now
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Frame frameStart ->
            runChunk frameStart model

        ChunkDone frameStart now ->
            if searching model && Time.posixToMillis now - Time.posixToMillis frameStart < frameBudgetMillis then
                runChunk frameStart model

            else
                ( model, Cmd.none )

        Start ->
            case model.legs of
                Loaded _ ->
                    ( startSearch { model | settingsOpen = False }, Cmd.none )

                Loading _ ->
                    ( startSearch { model | settingsOpen = False }, Cmd.none )

                _ ->
                    ( startSearch { model | settingsOpen = False, legs = Loading { thenDownload = False } }, fetchLegs )

        SetStartDate date ->
            ( { model | startDate = date }, Cmd.none )

        SetStartTimeOfDay timeOfDay ->
            ( { model | startTimeOfDay = timeOfDay }, Cmd.none )

        SetSpeedInput speed ->
            ( { model | speedInput = speed }, Cmd.none )

        SetStopInput stop ->
            ( { model | stopInput = stop }, Cmd.none )

        SetSeedInput seed ->
            ( { model | seedInput = seed }, Cmd.none )

        SetStartCityInput city ->
            ( { model | startCityInput = city }, Cmd.none )

        SetEndCityInput city ->
            ( { model | endCityInput = city }, Cmd.none )

        SelectTab tab ->
            ( { model | tab = tab }, Cmd.none )

        SetMapFit value ->
            ( { model
                | mapFit =
                    List.Extra.find (\( _, v, _ ) -> v == value) mapFits
                        |> Maybe.map (\( fit, _, _ ) -> fit)
                        |> Maybe.withDefault model.mapFit
              }
            , Cmd.none
            )

        Print ->
            ( model, print () )

        OpenSettings ->
            ( { model | settingsOpen = True }, focus settingsCloseId )

        CloseSettings ->
            ( { model | settingsOpen = False }, focus settingsOpenerId )

        NoOp ->
            ( model, Cmd.none )

        ExportGpx ->
            case model.legs of
                Loaded legs ->
                    ( model, downloadGpx model legs )

                Loading _ ->
                    ( { model | legs = Loading { thenDownload = True } }, Cmd.none )

                _ ->
                    ( { model | legs = Loading { thenDownload = True } }, fetchLegs )

        GotLegs (Ok legs) ->
            ( { model | legs = Loaded legs }
            , if model.legs == Loading { thenDownload = True } then
                downloadGpx model legs

              else
                Cmd.none
            )

        GotLegs (Err _) ->
            ( { model | legs = Failed }, Cmd.none )


fetchLegs : Cmd Msg
fetchLegs =
    Http.get
        { url = "geo/route-legs.json"
        , expect = Http.expectJson GotLegs (Decode.dict Decode.string)
        }


{-| Shares or saves the best route as `mctrot-YYYY-MM-DD.gpx` (see
`Gpx.build`, `saveGpx`). Safari only shares in direct response to a tap,
which is why the legs are fetched ahead of time, when the search starts.
-}
downloadGpx : Model -> Dict String String -> Cmd msg
downloadGpx model legs =
    let
        startTime =
            model.activeStart

        dateText =
            Maybe.map Calendar.formatIso startTime.date |> Maybe.withDefault "route"

        toStop visit =
            Array.get visit.cityIndex cities
                |> Maybe.map
                    (\city ->
                        { mcdId = Array.get visit.cityIndex MctrotMapData.mcdIds |> Maybe.withDefault 0
                        , name = city.name
                        , desc = city.address ++ " · arrive " ++ arrivalText startTime visit
                        , lat = city.lat
                        , lon = city.lon
                        , arrival = visit.arrival
                        }
                    )
    in
    saveGpx
        { filename = "mctrot-" ++ dateText ++ ".gpx"
        , gpx =
            Gpx.build
                { name = "McTrot route" ++ (Maybe.map (\d -> ", " ++ Calendar.formatLong d) startTime.date |> Maybe.withDefault "")
                , date = startTime.date
                , legs = legs
                , stops = List.filterMap toStop (simulate startTime (SimulatedAnnealing.best model.saState))
                }
        }


focus : String -> Cmd Msg
focus id =
    Task.attempt (\_ -> NoOp) (Browser.Dom.focus id)



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    if searching model then
        Browser.Events.onAnimationFrame Frame

    else
        Sub.none



-- VIEW


{-| Roughly how wide the schedule's timeline column renders: the page is
one column at most 30rem wide, less the location names. It actually
stretches to fill whatever the location-name column leaves (see
`viewSchedule`), so this only decides how densely `viewTimeAxis` labels
hours.
-}
nominalTimelineWidth : Float
nominalTimelineWidth =
    220


rowHeight : Float
rowHeight =
    34


view : Model -> Html Msg
view model =
    let
        tour =
            SimulatedAnnealing.current model.saState

        visits =
            simulate model.activeStart tour

        viewMax =
            max 600 (((totalMinutes model.activeStart tour // 60) + 1) * 60)
    in
    Html.div []
        [ viewScreen model tour visits viewMax
        , Html.Lazy.lazy3 viewPrintSheet model.mapFit model.activeStart (SimulatedAnnealing.best model.saState)
        ]


{-| The whole page, mobile first (styled in css/style.css under "simulator
app"): a link home, then either the START button over a summary of the
settings (before the first run), or the screen — readouts over the map or
schedule — above a bar of keys and RESTART. The settings open in a sheet
over everything; the export keys appear only once the search is done.
-}
viewScreen : Model -> Tour -> List Visit -> Int -> Html Msg
viewScreen model tour visits viewMax =
    let
        done =
            model.running && SimulatedAnnealing.isDone (config model.activeStart) model.saState
    in
    Html.div [ Attr.class "simulator-screen sim" ]
        (List.concat
            [ [ Html.h1 [ Attr.class "sr-only" ] [ Html.text "McTrot Simulator" ]
              , viewTopBar model.running done
              ]
            , if model.running then
                [ viewDisplay model tour visits viewMax done
                , viewControls model.tab model.legs done
                ]

              else
                [ viewIdle model ]
            , if model.settingsOpen then
                viewSettingsSheet model

              else
                []
            ]
        )


viewTopBar : Bool -> Bool -> Html msg
viewTopBar running done =
    Html.div [ Attr.class "sim-top" ]
        [ Html.a [ Attr.class "sim-home", Attr.href "/" ] [ Html.text "← McTrot" ]
        , Html.p [ Attr.class "sim-status", Attr.attribute "aria-live" "polite" ]
            [ Html.text
                (if not running then
                    ""

                 else if done then
                    "Done"

                 else
                    "Searching…"
                )
            ]
        ]


{-| Before the first run: START in the thumb zone, over a summary of the
settings that opens the settings sheet.
-}
viewIdle : Model -> Html Msg
viewIdle model =
    Html.div [ Attr.class "sim-idle" ]
        [ viewStartButton "start-big" "Start"
        , Html.button
            [ Attr.class "summary"
            , Attr.id settingsOpenerId
            , Attr.attribute "aria-haspopup" "dialog"
            , Events.onClick OpenSettings
            ]
            (List.map (\line -> Html.span [ Attr.class "summary-line" ] [ Html.text line ]) (settingsSummary model)
                ++ [ Html.span [ Attr.class "summary-edit" ] [ Html.text "Change settings" ] ]
            )
        ]


{-| The settings as the next Start will read them (see `startSearch`).
-}
settingsSummary : Model -> List String
settingsSummary model =
    let
        dateText =
            Calendar.parseDate model.startDate |> Maybe.map Calendar.formatShort |> Maybe.withDefault model.startDate

        cityName raw =
            parseCity raw |> Maybe.andThen (\i -> Array.get i cities) |> Maybe.map .name |> Maybe.withDefault "Flexible"
    in
    [ dateText ++ " · " ++ formatClock (parseStartMinutes model.startTimeOfDay)
    , String.fromFloat (parseMinutesPerMile model.speedInput) ++ " min/mi · " ++ String.fromInt (parseStopMinutes model.stopInput) ++ " min stops"
    , cityName model.startCityInput ++ " → " ++ cityName model.endCityInput ++ " · seed " ++ String.fromInt (parseSeed model.seedInput)
    ]


{-| The screen: readouts, then the selected tab's panel, which scrolls on
its own while the page stays put.
-}
viewDisplay : Model -> Tour -> List Visit -> Int -> Bool -> Html Msg
viewDisplay model tour visits viewMax done =
    let
        iterations =
            formatCount (SimulatedAnnealing.iteration model.saState)

        hudRow label time meters =
            Html.div [ Attr.class "hud-row" ]
                [ Html.span [ Attr.class "hud-label" ] [ Html.text label ]
                , Html.span [ Attr.class "hud-value" ] [ Html.text (formatDuration time) ]
                , Html.span [ Attr.class "hud-value" ] [ Html.text (formatMiles meters) ]
                ]
    in
    Html.section [ Attr.class "bezel", Attr.attribute "aria-label" "Search" ]
        [ Html.div [ Attr.class "hud" ]
            (hudRow "Best" (round (SimulatedAnnealing.bestEnergy model.saState)) (totalDistanceMeters model.activeStart (SimulatedAnnealing.best model.saState))
                :: (if done then
                        [ Html.p [ Attr.class "hud-meta" ] [ Html.text (iterations ++ " iterations") ] ]

                    else
                        [ hudRow "Now" (round (SimulatedAnnealing.currentEnergy model.saState)) (totalDistanceMeters model.activeStart tour)
                        , Html.p [ Attr.class "hud-meta" ]
                            [ Html.text ("iter " ++ iterations ++ " · temp " ++ String.fromInt (round (SimulatedAnnealing.temperature (config model.activeStart) model.saState))) ]
                        ]
                   )
            )
        , Html.div
            [ Attr.attribute "role" "tabpanel"
            , Attr.id "simulator-tabpanel"
            , Attr.attribute "aria-labelledby" (tabId model.tab)
            , Attr.class "tabpanel"
            ]
            [ case model.tab of
                MapTab ->
                    viewMap model.mapFit (stops model.activeStart tour)

                ScheduleTab ->
                    Html.div []
                        [ Html.ul [ Attr.class "sched-key" ]
                            [ keyItem "swatch-closed" "Closed"
                            , keyItem "swatch-visit" "At stop"
                            , keyItem "swatch-wait" "Waited to open"
                            ]
                        , viewSchedule model.activeStart viewMax visits
                        ]
            ]
        ]


{-| 179800 → "179,800"
-}
formatCount : Int -> String
formatCount n =
    String.fromInt n
        |> String.reverse
        |> String.toList
        |> List.Extra.greedyGroupsOf 3
        |> List.map String.fromList
        |> String.join ","
        |> String.reverse


keyItem : String -> String -> Html msg
keyItem swatchClass label =
    Html.li [] [ Html.span [ Attr.class ("swatch " ++ swatchClass) ] [], Html.text label ]


{-| The bar under the screen: view keys, the settings key, the export keys
once the search is done, and RESTART.
-}
viewControls : Tab -> Legs -> Bool -> Html Msg
viewControls tab legs done =
    Html.div [ Attr.class "sim-controls" ]
        [ Html.div [ Attr.class "sim-keys" ]
            [ viewTabList tab
            , Html.button
                [ Attr.class "key key-icon"
                , Attr.id settingsOpenerId
                , Attr.attribute "aria-haspopup" "dialog"
                , Attr.attribute "aria-label" "Settings"
                , Events.onClick OpenSettings
                ]
                [ Html.text "⚙\u{FE0E}" ]
            , if done then
                viewExport legs

              else
                Html.text ""
            ]
        , viewStartButton "start-small" "Restart"
        ]


{-| `size` is "start-big", "start-small", or "start-sheet" (see css).
-}
viewStartButton : String -> String -> Html Msg
viewStartButton size label =
    Html.div [ Attr.class ("start-well " ++ size) ]
        [ Html.button [ Attr.class "start-button", Events.onClick Start ] [ Html.text label ] ]


viewExport : Legs -> Html Msg
viewExport legs =
    Html.div [ Attr.class "export" ]
        [ Html.button [ Attr.class "key", Events.onClick Print ] [ Html.text "Print" ]
        , Html.button [ Attr.class "key", Events.onClick ExportGpx ]
            [ Html.text
                (case legs of
                    Loading { thenDownload } ->
                        if thenDownload then
                            "GPX…"

                        else
                            "GPX"

                    Failed ->
                        "Retry GPX"

                    _ ->
                        "GPX"
                )
            ]
        , Html.details [ Attr.class "distance-matrix" ]
            [ Html.summary [] [ Html.text "Distance matrix (meters)" ]
            , viewCostMatrix
            ]
        ]


{-| Only one opener is on the page at a time (the summary before the first
run, the settings key after), so they share an id for returning focus.
-}
settingsOpenerId : String
settingsOpenerId =
    "settings-open"


settingsCloseId : String
settingsCloseId =
    "settings-close"


{-| A modal sheet from the bottom: a backdrop that closes it, and the
settings with their own START, so changing them and starting is one step.
Escape closes it too.
-}
viewSettingsSheet : Model -> List (Html Msg)
viewSettingsSheet model =
    let
        closeOnEscape =
            Decode.field "key" Decode.string
                |> Decode.andThen
                    (\key ->
                        if key == "Escape" then
                            Decode.succeed CloseSettings

                        else
                            Decode.fail "not Escape"
                    )
    in
    [ Html.div [ Attr.class "sheet-backdrop", Events.onClick CloseSettings ] []
    , Html.div
        [ Attr.class "sheet"
        , Attr.attribute "role" "dialog"
        , Attr.attribute "aria-modal" "true"
        , Attr.attribute "aria-labelledby" "settings-title"
        , Events.on "keydown" closeOnEscape
        ]
        [ Html.div [ Attr.class "sheet-head" ]
            [ Html.h2 [ Attr.id "settings-title" ] [ Html.text "Settings" ]
            , Html.button
                [ Attr.class "key key-icon"
                , Attr.id settingsCloseId
                , Attr.attribute "aria-label" "Close settings"
                , Events.onClick CloseSettings
                ]
                [ Html.text "✕\u{FE0E}" ]
            ]
        , viewRunSettings model
        , viewStartButton "start-sheet"
            (if model.running then
                "Restart"

             else
                "Start"
            )
        ]
    ]


tabLabel : Tab -> String
tabLabel tab =
    case tab of
        MapTab ->
            "Map"

        ScheduleTab ->
            "Schedule"


tabId : Tab -> String
tabId tab =
    "simulator-tab-" ++ String.toLower (tabLabel tab)


{-| The Map/Schedule keys. Only the selected tab's panel is rendered (see
`viewDisplay`), so the hidden one costs nothing per frame.
-}
viewTabList : Tab -> Html Msg
viewTabList selected =
    let
        viewTab tab =
            Html.button
                [ Attr.attribute "role" "tab"
                , Attr.id (tabId tab)
                , Attr.attribute "aria-selected"
                    (if tab == selected then
                        "true"

                     else
                        "false"
                    )
                , Attr.attribute "aria-controls" "simulator-tabpanel"
                , Attr.class "key"
                , Events.onClick (SelectTab tab)
                ]
                [ Html.text (tabLabel tab) ]
    in
    Html.div [ Attr.attribute "role" "tablist", Attr.attribute "aria-label" "View", Attr.class "tabs" ]
        (List.map viewTab [ MapTab, ScheduleTab ])



mapDisplayWidth : Float
mapDisplayWidth =
    300


mapDisplayHeight : Float
mapDisplayHeight =
    -- Matches data/mctrot_map.svg's viewBox aspect ratio (~1 : 3.64) at mapDisplayWidth.
    1093


{-| One space-separated `lX-lY` token per leg of the route (see `stops`), where X and Y are real `mcd_id`s
(see `MctrotMapData.mcdIds`) in ascending order — matching the class-token
convention already baked into `MctrotMapData.routeEdges`. Setting this as an
ancestor `data-active` attribute is what lets `css/mctrot-map.css` highlight
exactly the streets the current tour uses, without Elm ever touching the
(lazy, otherwise-static) SVG subtree itself.
-}
tourEdgeTokens : List Int -> String
tourEdgeTokens route =
    List.map2 pairToken route (List.drop 1 route)
        |> String.join " "


pairToken : Int -> Int -> String
pairToken cityIndexA cityIndexB =
    let
        mcdIdFor cityIndex =
            Array.get cityIndex MctrotMapData.mcdIds |> Maybe.withDefault 0

        a =
            mcdIdFor cityIndexA

        b =
            mcdIdFor cityIndexB
    in
    "l" ++ String.fromInt (min a b) ++ "-l" ++ String.fromInt (max a b)


stretchPadding : String
stretchPadding =
    "10px"


{-| The viewBox the map's layers share for each `MapFit`: `Stretch`
narrows it to `MctrotMapData.routeViewBox` and lets the borough spill into
the padding, clipped at the box's edge.
-}
mapViewBoxFor : MapFit -> String
mapViewBoxFor fit =
    if fit == Stretch then
        MctrotMapData.routeViewBox

    else
        MctrotMapData.mapViewBox


{-| One of the map's stacked layers: an SVG filling the map frame (see
`viewMapFrame`) with the viewBox for `fit`. `Stretch` fills
the frame horizontally (`preserveAspectRatio "none"`);
css/mctrot-map.css keeps line widths and the round dots from stretching with
it.
-}
mapLayer : MapFit -> List (Svg msg) -> Html msg
mapLayer fit =
    Svg.svg
        [ SvgAttr.viewBox (mapViewBoxFor fit)
        , SvgAttr.width "100%"
        , SvgAttr.height "100%"
        , SvgAttr.preserveAspectRatio
            (if fit == Normal then
                "xMidYMid meet"

             else
                "none"
            )
        , Attr.style "position" "absolute"
        , Attr.style "inset" "0"
        , Attr.style "overflow" "visible"
        ]


{-| The box the layers stack in, `height` tall: `mapDisplayWidth` wide and
centered for `Normal`, the full width otherwise (less `stretchPadding`
on each side).
-}
viewMapFrame : MapFit -> String -> List (Html msg) -> Html msg
viewMapFrame fit height layers =
    Html.div
        [ Attr.style "padding"
            (if fit == Stretch then
                "0 " ++ stretchPadding

             else
                "0"
            )
        , Attr.style "overflow" "hidden"
        ]
        [ Html.div
            [ Attr.style "position" "relative"
            , Attr.style "height" height
            , Attr.style "width"
                (if fit == Normal then
                    String.fromFloat mapDisplayWidth ++ "px"

                 else
                    "auto"
                )
            , Attr.style "margin" "0 auto"
            ]
            layers
        ]


{-| The borough silhouette — built once per `MapFit` and never touched
again. `viewMap` wraps this and the other static layers in `Html.Lazy.lazy` so
Elm's virtual DOM skips diffing them on every animation frame.
-}
viewBoroughLayer : MapFit -> Html msg
viewBoroughLayer fit =
    mapLayer fit [ Svg.path [ SvgAttr.class "borough", SvgAttr.d MctrotMapData.boroughPath ] [] ]


{-| All real-street route segments — built once per `MapFit`; only the
wrapping `data-active` attribute changes per tick (see `tourEdgeTokens`).
-}
viewRouteLayer : MapFit -> Html msg
viewRouteLayer fit =
    mapLayer fit
        (MctrotMapData.routeEdges
            |> List.map (\edge -> Svg.path [ SvgAttr.class edge.classes, SvgAttr.d edge.d ] [])
        )


{-| What a location's marker shows: where the route starts, where it
finishes, or an ordinary stop.
-}
type LocationKind
    = StartLocation
    | FinishLocation
    | StopLocation


{-| For a round trip the finish covers the start.
-}
locationKind : Maybe Int -> Maybe Int -> Int -> LocationKind
locationKind start finish cityIndex =
    if Just cityIndex == finish then
        FinishLocation

    else if Just cityIndex == start then
        StartLocation

    else
        StopLocation


locationKindClass : LocationKind -> String
locationKindClass kind =
    case kind of
        StartLocation ->
            "location location-start"

        FinishLocation ->
            "location location-finish"

        StopLocation ->
            "location location-stop"


{-| A marker at every location, on top of everything else: a green diamond
where the route starts at `start`, a checkered one where it finishes at
`finish`, and a dot everywhere else (styled in css/mctrot-map.css). They're
HTML, positioned by percentage within the map frame, so they keep their
shape however the map is stretched. Lazy in `viewMapLayers`, so it only
rebuilds when the fit or the route's ends change.
-}
viewLocationLayer : MapFit -> Maybe Int -> Maybe Int -> Html msg
viewLocationLayer fit start finish =
    let
        viewBox =
            case String.split " " (mapViewBoxFor fit) |> List.filterMap String.toFloat of
                [ x, y, w, h ] ->
                    Just { x = x, y = y, w = w, h = h }

                _ ->
                    Nothing

        marker vb ( cityIndex, ( x, y ) ) =
            Html.div
                [ Attr.class (locationKindClass (locationKind start finish cityIndex))
                , Attr.style "left" (String.fromFloat ((x - vb.x) / vb.w * 100) ++ "%")
                , Attr.style "top" (String.fromFloat ((y - vb.y) / vb.h * 100) ++ "%")
                ]
                []
    in
    Html.div [ Attr.style "position" "absolute", Attr.style "inset" "0", Attr.style "pointer-events" "none" ]
        (case viewBox of
            Just vb ->
                MctrotMapData.locationCoords
                    |> Array.toIndexedList
                    |> List.map (marker vb)

            Nothing ->
                []
        )


{-| The map's stacked layers, `height` tall (any CSS length), with `route`'s
streets highlighted and its ends marked.
-}
viewMapLayers : MapFit -> String -> List Int -> Html msg
viewMapLayers fit height route =
    Html.div [ Attr.attribute "data-active" (tourEdgeTokens route) ]
        [ viewMapFrame fit
            height
            [ Html.Lazy.lazy viewBoroughLayer fit
            , Html.Lazy.lazy viewRouteLayer fit
            , Html.Lazy.lazy3 viewLocationLayer fit (List.head route) (List.Extra.last route)
            ]
        ]


{-| What prints instead of the page (see css/style.css): a US letter sheet
with the best route's map stretched by `fit` over all of page one, in front of
the header, and its schedule on page two. Each page is headed with the start
date. Lazy in `view`, so it
only rebuilds when the best route or run settings change.
-}
viewPrintSheet : MapFit -> StartTime -> Tour -> Html msg
viewPrintSheet fit startTime best =
    let
        printHead =
            Html.div [ Attr.class "print-head" ]
                [ Html.span [ Attr.class "print-wordmark" ] [ Html.text "McTrot" ]
                , Html.span [] [ Html.text (Maybe.map Calendar.formatLong startTime.date |> Maybe.withDefault "") ]
                ]
    in
    Html.div [ Attr.class "print-sheet" ]
        [ Html.div [ Attr.class "print-page" ]
            [ printHead
            , Html.div [ Attr.class "print-map" ] [ viewMapLayers fit "9in" (stops startTime best) ]
            ]
        , Html.div [ Attr.class "print-page" ]
            [ printHead
            , viewPrintSchedule startTime (simulate startTime best)
            ]
        ]


{-| One row per visit. Arrival times are on a 12-hour clock; the first
arrival on each later calendar day also gets that day's date, since the page
header only names the start date.
-}
viewPrintSchedule : StartTime -> List Visit -> Html msg
viewPrintSchedule startTime visits =
    let
        dayOf visit =
            visit.arrival // dayLength

        arrivalCell previousDay visit =
            let
                dateText =
                    case ( startTime.date, dayOf visit /= previousDay ) of
                        ( Just date, True ) ->
                            Calendar.formatShort (Calendar.addDays (dayOf visit) date) ++ ", "

                        _ ->
                            ""
            in
            dateText ++ clockWithWait visit

        row i previousDay visit =
            let
                city =
                    Array.get visit.cityIndex cities
            in
            Html.tr []
                [ Html.td [ Attr.class "print-num" ] [ Html.text (String.fromInt (i + 1)) ]
                , Html.td [] [ Html.text (Maybe.map .name city |> Maybe.withDefault "") ]
                , Html.td [] [ Html.text (Maybe.map .address city |> Maybe.withDefault "") ]
                , Html.td [] [ Html.text (arrivalCell previousDay visit) ]
                ]

        previousDays =
            0 :: List.map dayOf visits
    in
    Html.table [ Attr.class "print-schedule" ]
        [ Html.thead []
            [ Html.tr []
                [ Html.th [ Attr.class "print-num" ] [ Html.text "#" ]
                , Html.th [] [ Html.text "Code name" ]
                , Html.th [] [ Html.text "Address" ]
                , Html.th [] [ Html.text "Expected arrival" ]
                ]
            ]
        , Html.tbody [] (List.map3 row (List.range 0 (List.length visits - 1)) previousDays visits)
        ]


{-| "2:05 AM", plus " (opens 6:00 AM)" if the visit waited.
-}
clockWithWait : Visit -> String
clockWithWait visit =
    formatClock visit.arrival
        ++ (if visit.wait > 0 then
                " (opens " ++ formatClock (visit.arrival + visit.wait) ++ ")"

            else
                ""
           )


{-| A visit's arrival with its date ("Sun Nov 22, 2:05 AM"), for the GPX
waypoints, which (unlike the printout) have no page header to name the day.
-}
arrivalText : StartTime -> Visit -> String
arrivalText startTime visit =
    (case startTime.date of
        Just date ->
            Calendar.formatShort (Calendar.addDays (visit.arrival // dayLength) date) ++ ", "

        Nothing ->
            ""
    )
        ++ clockWithWait visit


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


{-| The map with a `MapFit` dropdown pinned to its top right corner.
-}
viewMap : MapFit -> List Int -> Html Msg
viewMap fit route =
    Html.div [ Attr.style "position" "relative" ]
        [ viewMapLayers fit (String.fromFloat mapDisplayHeight ++ "px") route
        , Html.select
            [ Attr.class "map-fit"
            , Attr.attribute "aria-label" "Map fit"
            , Events.onInput SetMapFit
            ]
            (List.map
                (\( f, value, label ) -> Html.option [ Attr.value value, Attr.selected (f == fit) ] [ Html.text label ])
                mapFits
            )
        ]


{-| Lets you pick the conditions the next run starts under: which day of
the week (that matters now, since about a fifth of the cities have real
hours that vary by weekday), what time, and how fast travel between stops
is (as a pace in minutes/mile — the units delivery routing usually gets
quoted in — converted to meters/minute for `travelTime`), and how many
minutes are spent at each stop (see `simulate`), and where the route
starts and ends (see `stops`). Editing these
fields only takes effect the next time the search (re)starts —
`activeStart` is snapshotted at that point, so nudging any of them mid-run
can't shift the energy landscape out from under an in-progress search.
-}
viewRunSettings : Model -> Html Msg
viewRunSettings model =
    Html.div [ Attr.class "settings" ]
        [ field ""
            "Start date"
            (Html.input [ Attr.type_ "date", Attr.value model.startDate, Events.onInput SetStartDate ] [])
        , field ""
            "Start time"
            (Html.input [ Attr.type_ "time", Attr.value model.startTimeOfDay, Events.onInput SetStartTimeOfDay ] [])
        , field ""
            "Pace (min/mile)"
            (Html.input [ Attr.type_ "number", Attr.step "0.5", Attr.min "0.5", Attr.value model.speedInput, Events.onInput SetSpeedInput ] [])
        , field ""
            "Stop time (min)"
            (Html.input [ Attr.type_ "number", Attr.step "1", Attr.min "0", Attr.value model.stopInput, Events.onInput SetStopInput ] [])
        , viewCitySelect "Start location" model.startCityInput SetStartCityInput
        , viewCitySelect "End location" model.endCityInput SetEndCityInput
        , field ""
            "Seed"
            (Html.input [ Attr.type_ "text", Attr.attribute "inputmode" "numeric", Attr.value model.seedInput, Events.onInput SetSeedInput ] [])
        ]


{-| One labeled control in the settings tray; `extraClass` widens it
("field-wide") or is "".
-}
field : String -> String -> Html msg -> Html msg
field extraClass label control =
    Html.label [ Attr.class (String.trim ("field " ++ extraClass)) ]
        [ Html.span [ Attr.class "field-label" ] [ Html.text label ], control ]


{-| A start/end location picker: "Flexible" (value "") first, then every
location as "NICKNAME (address)", north to south (see `northToSouth`).
Option values are city indices (see `parseCity`).
-}
viewCitySelect : String -> String -> (String -> Msg) -> Html Msg
viewCitySelect label selectedValue toMsg =
    let
        option value text =
            Html.option [ Attr.value value, Attr.selected (value == selectedValue) ] [ Html.text text ]
    in
    field "field-wide"
        label
        (Html.select [ Events.onInput toMsg ]
            (option "" "Flexible"
                :: (northToSouth
                        |> List.filterMap (\i -> Array.get i cities |> Maybe.map (\city -> option (String.fromInt i) (city.name ++ " (" ++ city.address ++ ")")))
                   )
            )
        )


readout : String -> String -> Html msg
readout label value =
    Html.div [ Attr.class "readout" ]
        [ Html.div [ Attr.class "readout-label" ] [ Html.text label ]
        , Html.div [ Attr.class "readout-value" ] [ Html.text value ]
        ]


{-| An elapsed time as an SVG x coordinate or width: a percentage of the
timeline, which spans `viewMax` minutes across however wide it renders.
-}
xScale : Int -> Float -> String
xScale viewMax elapsedMinutes =
    String.fromFloat (elapsedMinutes / toFloat viewMax * 100) ++ "%"


{-| A two-column grid: location names down the left (as wide as the longest
one), and the time axis and one timeline row per visit filling the rest.
-}
viewSchedule : StartTime -> Int -> List Visit -> Html msg
viewSchedule startTime viewMax visits =
    Html.div
        [ Attr.style "display" "grid"
        , Attr.style "grid-template-columns" "max-content 1fr"
        , Attr.style "column-gap" "0.5rem"
        , Attr.style "align-items" "center"
        ]
        (Html.div [] []
            :: viewTimeAxis startTime viewMax
            :: List.concatMap (viewRow startTime viewMax) visits
        )


timeAxisHeight : Float
timeAxisHeight =
    26


{-| The schedule's x-axis, drawn as its own row above the visits on the
same `xScale`: a tick every 15 minutes of clock time, taller ticks on the
hour, and hour labels ("8 PM") spaced out to every 2, 3, ... hours when a
long route squeezes them closer than `minLabelSpacing` pixels. Labels too
close to either end to fit are left off.
-}
viewTimeAxis : StartTime -> Int -> Html msg
viewTimeAxis startTime viewMax =
    let
        minLabelSpacing =
            44

        pixelsPerHour =
            60 * nominalTimelineWidth / toFloat viewMax

        labelEveryHours =
            [ 1, 2, 3, 4, 6, 12, 24 ]
                |> List.filter (\hours -> toFloat hours * pixelsPerHour >= minLabelSpacing)
                |> List.head
                |> Maybe.withDefault 24

        baseline =
            timeAxisHeight - 2

        firstQuarter =
            modBy 15 (15 - modBy 15 startTime.minutes)

        tick elapsed =
            let
                clock =
                    modBy dayLength (startTime.minutes + elapsed)

                isHour =
                    modBy 60 clock == 0

                x =
                    toFloat elapsed * nominalTimelineWidth / toFloat viewMax

                tickLine =
                    Svg.line
                        [ SvgAttr.x1 (xScale viewMax (toFloat elapsed))
                        , SvgAttr.x2 (xScale viewMax (toFloat elapsed))
                        , SvgAttr.y1 (String.fromFloat baseline)
                        , SvgAttr.y2
                            (String.fromFloat
                                (if isHour then
                                    baseline - 8

                                 else
                                    baseline - 4
                                )
                            )
                        , SvgAttr.class "sched-axis"
                        ]
                        []

                fitsLabel =
                    x >= 16 && x <= nominalTimelineWidth - 16
            in
            if isHour && modBy labelEveryHours (clock // 60) == 0 && fitsLabel then
                [ tickLine
                , Svg.text_
                    [ SvgAttr.x (xScale viewMax (toFloat elapsed))
                    , SvgAttr.y (String.fromFloat (baseline - 11))
                    , SvgAttr.textAnchor "middle"
                    , SvgAttr.class "sched-axis-label"
                    ]
                    [ Svg.text (formatHour (clock // 60)) ]
                ]

            else
                [ tickLine ]
    in
    Svg.svg
        [ SvgAttr.width "100%"
        , SvgAttr.height (String.fromFloat timeAxisHeight)
        , Attr.style "display" "block"
        ]
        (Svg.line
            [ SvgAttr.x1 "0"
            , SvgAttr.x2 "100%"
            , SvgAttr.y1 (String.fromFloat baseline)
            , SvgAttr.y2 (String.fromFloat baseline)
            , SvgAttr.class "sched-axis"
            ]
            []
            :: (List.range 0 ((viewMax - firstQuarter) // 15)
                    |> List.concatMap (\i -> tick (firstQuarter + i * 15))
               )
        )


{-| An hour of the day (0-23) on a 12-hour clock: "12 AM", "8 PM".
-}
formatHour : Int -> String
formatHour hour =
    let
        twelveHour =
            if modBy 12 hour == 0 then
                12

            else
                modBy 12 hour
    in
    String.fromInt twelveHour
        ++ (if hour < 12 then
                " AM"

            else
                " PM"
           )


{-| One visit's two grid cells (see `viewSchedule`): its location name, and
its timeline — closed hours in pink, then the time spent there (orange if
it included waiting for it to open).
-}
viewRow : StartTime -> Int -> Visit -> List (Html msg)
viewRow startTime viewMax visit =
    let
        city =
            Array.get visit.cityIndex cities |> Maybe.withDefault (City "?" "" 0 0 [ ( 0, weekLength ) ] [])

        arrivalElapsed =
            toFloat (visit.arrival - startTime.minutes)

        departureElapsed =
            toFloat (visit.departure - startTime.minutes)

        label =
            city.name
                ++ (if visit.wait > 0 then
                        " (waited " ++ formatDuration visit.wait ++ ")"

                    else
                        ""
                   )

        barHeight =
            rowHeight - 4

        visitClass =
            if visit.wait > 0 then
                "sched-wait"

            else
                "sched-visit"
    in
    [ Html.div [ Attr.class "sched-label" ]
        [ Html.text label ]
    , Svg.svg
        [ SvgAttr.width "100%"
        , SvgAttr.height (String.fromFloat rowHeight)
        , Attr.style "display" "block"
        ]
        (Svg.rect
            [ SvgAttr.x "0"
            , SvgAttr.y "0"
            , SvgAttr.width "100%"
            , SvgAttr.height (String.fromFloat barHeight)
            , SvgAttr.class "sched-track"
            ]
            []
            :: (closedBandsElapsed city.closedWindows startTime viewMax
                    |> List.map
                        (\( s, e ) ->
                            Svg.rect
                                [ SvgAttr.x (xScale viewMax (toFloat s))
                                , SvgAttr.y "0"
                                , SvgAttr.width (xScale viewMax (toFloat (e - s)))
                                , SvgAttr.height (String.fromFloat barHeight)
                                , SvgAttr.class "sched-closed"
                                ]
                                []
                        )
               )
            ++ [ Svg.rect
                    [ SvgAttr.x (xScale viewMax arrivalElapsed)
                    , SvgAttr.y "6"
                    , SvgAttr.width (xScale viewMax (departureElapsed - arrivalElapsed))
                    , SvgAttr.height (String.fromFloat (rowHeight - 16))
                    -- css/style.css gives it a same-colored 1px outline, which
                    -- keeps a very short visit at least 2px wide.
                    , SvgAttr.class visitClass
                    ]
                    []
               ]
        )
    ]


{-| A city's `closedWindows` (minutes-since-Monday-00:00, one repeating
week) converted to minutes-elapsed-since-the-tour-started, tiled across as
many weeks as the visible timeline (`viewMax`) spans, and clipped to
`[0, viewMax]`.
-}
closedBandsElapsed : List ( Int, Int ) -> StartTime -> Int -> List ( Int, Int )
closedBandsElapsed closedInWeek startTime viewMax =
    let
        weekOffset =
            startTime.weekday * dayLength + startTime.minutes

        maxK =
            (viewMax // weekLength) + 2
    in
    List.range 0 maxK
        |> List.concatMap
            (\k ->
                closedInWeek
                    |> List.map (\( s, e ) -> ( s - weekOffset + k * weekLength, e - weekOffset + k * weekLength ))
            )
        |> List.filterMap
            (\( s, e ) ->
                if e < 0 || s > viewMax then
                    Nothing

                else
                    Just ( max 0 s, min viewMax e )
            )


matrixCell : List (Html.Attribute msg)
matrixCell =
    [ Attr.style "border" "1px solid #ddd"
    , Attr.style "padding" "2px 6px"
    , Attr.style "text-align" "center"
    ]


distanceBetween : Int -> Int -> Int
distanceBetween from to =
    distanceMeters
        |> Array.get from
        |> Maybe.andThen (Array.get to)
        |> Maybe.withDefault 0


viewCostMatrix : Html msg
viewCostMatrix =
    let
        cityList =
            Array.toList cities

        headerRow =
            Html.tr []
                (Html.th matrixCell [] :: List.map (\c -> Html.th matrixCell [ Html.text c.name ]) cityList)

        bodyRow i city =
            Html.tr []
                (Html.th matrixCell [ Html.text city.name ]
                    :: List.indexedMap
                        (\j _ ->
                            Html.td matrixCell
                                [ Html.text
                                    (if i == j then
                                        "—"

                                     else
                                        String.fromInt (distanceBetween i j)
                                    )
                                ]
                        )
                        cityList
                )
    in
    Html.table
        [ Attr.style "border-collapse" "collapse"
        , Attr.style "margin-top" "0.5rem"
        , Attr.style "font-size" "0.8rem"
        , Attr.style "font-variant-numeric" "tabular-nums"
        ]
        (headerRow :: List.indexedMap bodyRow cityList)


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


main : Program String Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        }
